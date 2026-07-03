#!/usr/bin/env bash
# Logical-replication-free initial copy with pgcopydb (clone, NO --follow) -- the
# "buy" alternative to diy_initial_sync.py. Pair with Bucardo onetimecopy=0 for CDC.
# Neither uses logical decoding / replication slots.
#
# Requires pgcopydb >= 0.18 AND postgresql-client-17 (from PGDG). Debian's stock
# pgcopydb 0.10 is PG15-only and cannot pg_dump a PG17 server.
#
# The target needs a DIRECT connection -- pgcopydb does heavy concurrent catalog
# + schema work and does not ride a transaction pooler well. On Supabase that
# means the IPv4 add-on when the copy host is IPv4-only (Supabase direct is
# IPv6-only otherwise).
#
# Env:
#   SRC_URI   source libpq conninfo (e.g. AlloyDB via the auth proxy)
#   TGT_URI   target libpq conninfo (e.g. Supabase DIRECT: db.<ref>.supabase.co)
#   JOBS      table + split COPY jobs (default 8); index jobs fixed at 4
#
# Filters restrict the copy to the `shop` schema and skip the managed source's
# own schemas/extensions (AlloyDB ships google_ml_integration, google_columnar_
# engine, etc.) which the target neither has nor allows.
set -euo pipefail
export PATH=/usr/lib/postgresql/17/bin:$PATH
export PGCOPYDB_SOURCE_PGURI="${SRC_URI:?set SRC_URI}"
export PGCOPYDB_TARGET_PGURI="${TGT_URI:?set TGT_URI}"
JOBS="${JOBS:-8}"

FIL="$(mktemp)"
cat > "$FIL" <<'F'
[exclude-schema]
bucardo
ai
google_ml
public
F

# NB: against a Supabase target this HANGS after the events GIN build -- the
# CREATE INDEX commits but pgcopydb's index worker never exits (0% CPU, needs a
# manual pkill). Data + all indexes are complete before the hang. --skip-vacuum
# does NOT help (confirmed). Workarounds if you hit it: exclude the GIN via a
# [exclude-index] filter and build it manually after, or wrap this to detect the
# post-GIN idle hang, kill pgcopydb, and run ANALYZE yourself.
pgcopydb clone \
  --table-jobs "$JOBS" --index-jobs 4 \
  --split-tables-larger-than 256MB \
  --skip-extensions --no-owner --no-acl \
  --filters "$FIL"
