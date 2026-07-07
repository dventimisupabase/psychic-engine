#!/usr/bin/env bash
#
# bucardo_migrate.sh -- one-command Bucardo CDC setup for a whole-database
# migration (e.g. AlloyDB source -> Supabase target).
#
# It auto-enumerates EVERY replicatable table (and sequence) on the source and
# wires up a single Bucardo sync (onetimecopy=0, i.e. change-capture only), so
# the operator never has to touch Bucardo directly or list tables by hand.
#
# Scope / assumptions:
#   * The initial data load is ALREADY done (e.g. by `pgcopydb clone`) and the
#     target schema + rows exist. This script sets up ongoing CDC only.
#   * Run it ON the Bucardo host VM, as a user with sudo to the `bucardo` user.
#   * Bucardo is installed and its control DB is set up (RUNBOOK Part 6a).
#   * psql (v17) is on PATH.
#
# Re-running is safe: it tears down any prior sync of the same name (and its
# source triggers) and rebuilds from scratch.
#
# ---------------------------------------------------------------------------
# Configure via environment variables:
#
#   SRC_HOST   source host           (default 127.0.0.1  -- AlloyDB auth proxy)
#   SRC_PORT   source port           (default 5433)
#   SRC_USER   source user           (default postgres)
#   SRC_DB     source database       (REQUIRED)
#   SRC_PASS   source password       (REQUIRED)
#   SRC_SSLMODE                       (default disable)
#
#   TGT_HOST   target host           (REQUIRED -- e.g. aws-0-<region>.pooler.supabase.com)
#   TGT_PORT   target port           (default 5432)
#   TGT_USER   target user           (REQUIRED -- e.g. postgres.<ref>)
#   TGT_DB     target database       (default postgres)
#   TGT_PASS   target password       (REQUIRED)
#   TGT_SSLMODE                       (default require)
#
#   SCHEMAS             space/comma list to replicate (default: all user schemas)
#   EXCLUDE_SCHEMAS     schemas to skip   (default: "bucardo ai google_ml")
#   SYNC                Bucardo sync name (default: migsync)
#   ONETIMECOPY         0=CDC only (default), 2=let Bucardo also copy (not advised)
#   REPLICATE_SEQUENCES 1=also sync sequences (default 1)
#   STRICT              1=abort if any table lacks a PK/unique index (default 0=skip+warn)
#
# Flags:
#   --dry-run   enumerate and print the plan; make NO changes
#   --verify    after setup (or standalone), show sync status + row-count parity
#   --help
#
# Example:
#   SRC_DB=appdb SRC_PASS=... \
#   TGT_HOST=aws-0-us-east-1.pooler.supabase.com TGT_USER=postgres.abcdef TGT_PASS=... \
#   ./bucardo_migrate.sh
# ---------------------------------------------------------------------------
set -euo pipefail

DRY_RUN=0; DO_VERIFY=0; VERIFY_ONLY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --verify)  DO_VERIFY=1 ;;
    --verify-only) DO_VERIFY=1; VERIFY_ONLY=1 ;;
    --help|-h) sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

# ---- config with defaults ----
SRC_HOST="${SRC_HOST:-127.0.0.1}"; SRC_PORT="${SRC_PORT:-5433}"
SRC_USER="${SRC_USER:-postgres}";  SRC_SSLMODE="${SRC_SSLMODE:-disable}"
SRC_DB="${SRC_DB:?set SRC_DB}";    SRC_PASS="${SRC_PASS:?set SRC_PASS}"
TGT_HOST="${TGT_HOST:?set TGT_HOST}"; TGT_PORT="${TGT_PORT:-5432}"
TGT_USER="${TGT_USER:?set TGT_USER}"; TGT_DB="${TGT_DB:-postgres}"
TGT_PASS="${TGT_PASS:?set TGT_PASS}"; TGT_SSLMODE="${TGT_SSLMODE:-require}"
SCHEMAS="${SCHEMAS:-}"; EXCLUDE_SCHEMAS="${EXCLUDE_SCHEMAS:-bucardo ai google_ml}"
SYNC="${SYNC:-migsync}"; ONETIMECOPY="${ONETIMECOPY:-0}"
REPLICATE_SEQUENCES="${REPLICATE_SEQUENCES:-1}"; STRICT="${STRICT:-0}"
RELGROUP="${SYNC}_rg"; SRC_LBL="src_${SYNC}"; TGT_LBL="tgt_${SYNC}"

log(){ printf '[bucardo_migrate] %s\n' "$*"; }
die(){ printf '[bucardo_migrate] ERROR: %s\n' "$*" >&2; exit 1; }

SRC_URI="host=$SRC_HOST port=$SRC_PORT user=$SRC_USER dbname=$SRC_DB sslmode=$SRC_SSLMODE connect_timeout=15"
TGT_URI="host=$TGT_HOST port=$TGT_PORT user=$TGT_USER dbname=$TGT_DB sslmode=$TGT_SSLMODE connect_timeout=20"
psrc(){ PGPASSWORD="$SRC_PASS" psql "$SRC_URI" -X -qtA "$@"; }
ptgt(){ PGPASSWORD="$TGT_PASS" psql "$TGT_URI" -X -qtA "$@"; }
buc(){ sudo -u bucardo bucardo "$@"; }

# ---- schema predicate (on alias n.nspname) ----
schema_pred(){
  local arr s out=""
  if [[ -n "$SCHEMAS" ]]; then
    IFS=', ' read -r -a arr <<< "$SCHEMAS"
    for s in "${arr[@]}"; do [[ -n "$s" ]] && out+="'${s//\'/\'\'}',"; done
    printf "n.nspname IN (%s)" "${out%,}"
  else
    IFS=', ' read -r -a arr <<< "$EXCLUDE_SCHEMAS"
    for s in "${arr[@]}"; do [[ -n "$s" ]] && out+="'${s//\'/\'\'}',"; done
    if [[ -n "$out" ]]; then
      printf "n.nspname !~ '^pg_' AND n.nspname <> 'information_schema' AND n.nspname NOT IN (%s)" "${out%,}"
    else
      printf "n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'"
    fi
  fi
}
PRED="$(schema_pred)"

# ---- preflight ----
preflight(){
  command -v psql >/dev/null || die "psql not found on PATH"
  command -v bucardo >/dev/null || die "bucardo not found; install it (RUNBOOK Part 4)"
  buc list dbs >/dev/null 2>&1 || die "Bucardo control DB not ready; run the install (RUNBOOK Part 6a)"
  [[ "$(psrc -c 'select 1' 2>/dev/null)" == "1" ]] || die "cannot connect to SOURCE ($SRC_HOST:$SRC_PORT/$SRC_DB)"
  [[ "$(ptgt -c 'select 1' 2>/dev/null)" == "1" ]] || die "cannot connect to TARGET ($TGT_HOST:$TGT_PORT/$TGT_DB)"
  ptgt -c "SET session_replication_role=replica; RESET session_replication_role;" >/dev/null 2>&1 \
    || die "TARGET role cannot SET session_replication_role -> Bucardo cannot apply here (Supabase can; Cloud SQL/AlloyDB-as-target cannot)"
  log "preflight OK: source + target reachable, target allows session_replication_role"
}

# ---- enumerate ----
enumerate(){
  mapfile -t TABLES < <(psrc -c "
    SELECT n.nspname||'.'||c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE c.relkind='r' AND ($PRED)
      AND EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=c.oid AND i.indisunique)
    ORDER BY 1")
  mapfile -t NOKEY < <(psrc -c "
    SELECT n.nspname||'.'||c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE c.relkind='r' AND ($PRED)
      AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=c.oid AND i.indisunique)
    ORDER BY 1")
  SEQS=()
  if [[ "$REPLICATE_SEQUENCES" == "1" ]]; then
    mapfile -t SEQS < <(psrc -c "
      SELECT n.nspname||'.'||c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE c.relkind='S' AND ($PRED) ORDER BY 1")
  fi
  log "found ${#TABLES[@]} replicatable table(s), ${#NOKEY[@]} without a PK/unique key, ${#SEQS[@]} sequence(s)"
  if ((${#NOKEY[@]})); then
    log "tables WITHOUT a PK/unique index (Bucardo cannot replicate these):"
    printf '    - %s\n' "${NOKEY[@]}"
    [[ "$STRICT" == "1" ]] && die "STRICT=1 and ${#NOKEY[@]} table(s) lack a key; add PKs or set STRICT=0 to skip them"
  fi
  ((${#TABLES[@]})) || die "no replicatable tables found for the given schema filter"
}

verify(){
  log "sync status:"; buc status "$SYNC" 2>&1 | grep -E 'Current state|Last good|Onetimecopy|Autokick' || true
  log "row-count parity (source vs target):"
  local t s d mark
  for t in "${TABLES[@]}"; do
    s=$(psrc -c "SET statement_timeout=0; select count(*) from $t" 2>/dev/null || echo "?")
    d=$(ptgt -c "SET statement_timeout=0; select count(*) from $t" 2>/dev/null || echo "?")
    mark="OK"; [[ "$s" == "$d" ]] || mark="DIFF (CDC may still be catching up)"
    printf '    %-40s src=%s tgt=%s  %s\n' "$t" "$s" "$d" "$mark"
  done
}

# ================================ run ================================
preflight
enumerate

if [[ "$DRY_RUN" == "1" ]]; then
  log "DRY RUN. Would create sync '$SYNC' (onetimecopy=$ONETIMECOPY) over these tables:"
  printf '    %s\n' "${TABLES[@]}"
  ((${#SEQS[@]})) && { log "and sequences:"; printf '    %s\n' "${SEQS[@]}"; }
  exit 0
fi

if [[ "$VERIFY_ONLY" == "1" ]]; then verify; exit 0; fi

log "tearing down any prior '$SYNC' state (idempotent)"
buc stop >/dev/null 2>&1 || true; sleep 2
buc remove sync "$SYNC" >/dev/null 2>&1 || true
buc remove relgroup "$RELGROUP" >/dev/null 2>&1 || true
buc remove db "$SRC_LBL" "$TGT_LBL" >/dev/null 2>&1 || true
# Bucardo does not auto-remove its source triggers; drop leftovers so re-adds are clean.
psrc -c "DO \$\$ declare r record; begin
  for r in select n.nspname ns,c.relname rel,t.tgname tg
           from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
           where t.tgname like 'bucardo%' and ($PRED)
  loop execute format('DROP TRIGGER IF EXISTS %I ON %I.%I', r.tg, r.ns, r.rel); end loop;
end \$\$;" >/dev/null 2>&1 || true

log "registering databases"
buc add db "$SRC_LBL" dbname="$SRC_DB" host="$SRC_HOST" port="$SRC_PORT" user="$SRC_USER" "pass=$SRC_PASS" >/dev/null
buc add db "$TGT_LBL" dbname="$TGT_DB" host="$TGT_HOST" port="$TGT_PORT" user="$TGT_USER" "pass=$TGT_PASS" >/dev/null

log "creating relgroup and adding ${#TABLES[@]} table(s)"
buc add relgroup "$RELGROUP" >/dev/null
printf '%s\n' "${TABLES[@]}" | xargs -r -n 40 sudo -u bucardo bucardo add table db="$SRC_LBL" relgroup="$RELGROUP" >/dev/null

if ((${#SEQS[@]})); then
  log "adding ${#SEQS[@]} sequence(s) (best effort)"
  printf '%s\n' "${SEQS[@]}" | xargs -r -n 40 sudo -u bucardo bucardo add sequence db="$SRC_LBL" relgroup="$RELGROUP" >/dev/null \
    || log "WARN: sequence replication not configured; sync sequences at cutover with setval() from the source (RUNBOOK Part 8)"
fi

log "creating sync '$SYNC' (onetimecopy=$ONETIMECOPY) and starting Bucardo"
buc add sync "$SYNC" relgroup="$RELGROUP" dbs="$SRC_LBL:source,$TGT_LBL:target" onetimecopy="$ONETIMECOPY" >/dev/null
sudo rm -f /var/run/bucardo/fullstopbucardo 2>/dev/null || true
buc start >/dev/null
sleep 10
log "done. sync status:"
buc status "$SYNC" 2>&1 | grep -E 'Current state|Status|Onetimecopy|Autokick|Tables in sync' || buc status 2>&1 | tail -5

[[ "$DO_VERIFY" == "1" ]] && verify
log "CDC is live. Validate with a source insert (RUNBOOK Part 7); cut over per Part 8."
