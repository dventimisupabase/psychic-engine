# Runbook: Migrate AlloyDB to Supabase with pgCopyDB + Bucardo

A step-by-step, copy-paste runbook for migrating a PostgreSQL database from
**Google AlloyDB** to **Supabase**, using:

- **pgCopyDB** for the one-time initial data copy, and
- **Bucardo** (trigger-based) for ongoing change data capture (CDC) up to cutover.

## When to use this (and why not just pgCopyDB `--follow`)

Use this when the target restricts **logical replication**, which is the usual
case for Supabase. pgCopyDB's built-in CDC (`pgcopydb --follow`) and native
Postgres logical replication both fail or are impractical against Supabase:

- `pgcopydb --follow` needs the **`pg_replication_origin_*`** functions on the
  target to track apply progress. Those are **superuser-only**, and Supabase's
  `postgres` role is not a superuser, so `--follow` dies with
  `ERROR: permission denied for function pg_replication_origin_oid`.
- Native logical replication (`CREATE SUBSCRIPTION`) works privilege-wise, but
  it is **subscriber-pull**: the Supabase target must connect *into* your
  (private) AlloyDB source, which forces you to give AlloyDB a public IP.

**Bucardo sidesteps both problems.** It is trigger-based (no logical replication,
no source restart) and **VM-mediated**: a daemon on a small VM connects *out* to
both source and target and pushes changes, so nothing has to connect into
AlloyDB.

## Architecture

```
  AlloyDB (source, private)                         Supabase (target)
        ^                                                  ^
        | (1) AlloyDB Auth Proxy (127.0.0.1:5433)          | session pooler / direct
        |                                                   |
   +----+---------------------------------------------------+----+
   |                    GCE VM  "bucardo-vm"                     |
   |   - AlloyDB Auth Proxy (systemd)                           |
   |   - pgcopydb  (initial copy, runs once)                    |
   |   - Bucardo daemon + control DB  (ongoing CDC)             |
   +------------------------------------------------------------+
```

Both the initial copy and CDC are driven from the VM. All connections are
outbound from the VM.

## IMPORTANT: read-only window assumption

The simple flow below assumes the **source is read-only during the initial
copy** (a maintenance window that covers the pgCopyDB run). Reason: Bucardo only
begins capturing changes once its triggers are installed, which happens *after*
the copy in the simple flow. Any writes to the source between pgCopyDB's snapshot
and Bucardo's trigger install would be lost.

- If your source can be read-only during the copy (or is already static): use
  the simple flow. It is what this runbook validates end to end.
- If you need **zero-downtime on a busy source**: see
  [Appendix A: zero-downtime ordering](#appendix-a-zero-downtime-on-a-busy-source),
  which installs Bucardo's triggers *before* the copy. It is more involved;
  validate it in staging first.

---

# Part 0: Prerequisites and naming

Fill these in once; the rest of the runbook references them.

```bash
# --- GCP / AlloyDB (source) ---
export GCP_PROJECT="your-gcp-project"
export ADB_REGION="us-west2"
export ADB_CLUSTER="your-alloydb-cluster"
export ADB_INSTANCE="primary"
export SRC_DB="your_source_db"          # the database to migrate
export SRC_SCHEMA="public"              # or your app schema, e.g. shop

# --- VM (Bucardo host) ---
export VM_NAME="bucardo-vm"
export VM_ZONE="us-west1-a"             # pick a zone near the AlloyDB region

# --- Supabase (target) ---
export SB_REF="your_project_ref"        # 20-char project ref
export SB_REGION="us-east-1"            # Supabase project region
# Passwords: store securely; do NOT commit them.
```

You will also need:
- `gcloud` authenticated with rights to create VMs and manage AlloyDB.
- The AlloyDB `postgres` (or an admin) password.
- The Supabase database password (Dashboard: Project Settings > Database).

---

# Part 1: Provision the Bucardo host VM

An `e2-micro` is enough for small/medium migrations (it is CPU-idle; the copy is
network-bound). For large databases prefer `e2-standard-4` for headroom.

```bash
gcloud compute instances create "$VM_NAME" \
  --project="$GCP_PROJECT" \
  --zone="$VM_ZONE" \
  --machine-type=e2-micro \
  --image-family=debian-12 --image-project=debian-cloud \
  --scopes=https://www.googleapis.com/auth/cloud-platform
```

Give the VM's service account permission to reach AlloyDB:

```bash
# Find the VM service account:
VM_SA=$(gcloud compute instances describe "$VM_NAME" --zone="$VM_ZONE" \
  --format='value(serviceAccounts[0].email)')
gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
  --member="serviceAccount:$VM_SA" --role="roles/alloydb.client"
```

SSH in for the rest:

```bash
gcloud compute ssh "$VM_NAME" --zone="$VM_ZONE"
```

---

# Part 2: Connect the VM to the AlloyDB source (Auth Proxy)

Run the AlloyDB Auth Proxy on the VM, bound to localhost, as a systemd service.

```bash
# On the VM:
curl -o alloydb-auth-proxy \
  https://storage.googleapis.com/alloydb-auth-proxy/v1.10.1/alloydb-auth-proxy.linux.amd64
chmod +x alloydb-auth-proxy
sudo mv alloydb-auth-proxy /usr/local/bin/

# Instance URI:
#   projects/PROJECT/locations/REGION/clusters/CLUSTER/instances/INSTANCE
sudo tee /etc/systemd/system/alloydb-proxy.service >/dev/null <<EOF
[Unit]
Description=AlloyDB Auth Proxy
After=network-online.target
[Service]
ExecStart=/usr/local/bin/alloydb-auth-proxy \
  "projects/${GCP_PROJECT}/locations/${ADB_REGION}/clusters/${ADB_CLUSTER}/instances/${ADB_INSTANCE}" \
  --port 5433
Restart=always
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now alloydb-proxy.service
```

Set the AlloyDB `postgres` password (from your workstation, or any shell with
`gcloud`), if you do not already have it:

```bash
gcloud alloydb users set-password postgres \
  --cluster="$ADB_CLUSTER" --region="$ADB_REGION" --password='CHOOSE_A_STRONG_PW'
```

Test the source connection from the VM (install the client first, Part 4):

```bash
PGPASSWORD='...' psql "host=127.0.0.1 port=5433 user=postgres dbname=$SRC_DB sslmode=disable" -c '\dt '"$SRC_SCHEMA"'.*'
```

### Source privileges Bucardo will need

Bucardo installs a `bucardo` schema and triggers **on the source**. The role it
connects as (here `postgres`) must be able to create that schema and create
triggers on the tables it replicates. If your tables are owned by another role,
grant ownership rights, e.g. as the AlloyDB admin:

```sql
GRANT CREATE ON DATABASE :"SRC_DB" TO postgres;
GRANT USAGE, CREATE ON SCHEMA :"SRC_SCHEMA" TO postgres;
GRANT SELECT, TRIGGER ON ALL TABLES IN SCHEMA :"SRC_SCHEMA" TO postgres;
-- If tables are owned by an IAM/other role, grant membership so postgres owns them:
-- GRANT "owner-role" TO postgres;
```

Note: Bucardo does **not** require `wal_level=logical` or any AlloyDB restart.
That is one of its advantages over logical-replication approaches.

---

# Part 3: Provision the Supabase target

1. Create the Supabase project (Dashboard) sized for your data. Note the project
   ref and database password.
2. Decide the connection you will use:
   - **Session pooler** (works from any IPv4 host, use for **Bucardo**):
     `host=aws-0-${SB_REGION}.pooler.supabase.com port=5432 user=postgres.${SB_REF} dbname=postgres sslmode=require`
   - **Direct** (use for **pgCopyDB**, which does heavy concurrent schema work):
     `host=db.${SB_REF}.supabase.co port=5432 user=postgres dbname=postgres sslmode=require`
     The direct endpoint is IPv6-only unless you enable the **IPv4 add-on**
     (Dashboard: Project Settings > Add-ons > IPv4, or the Management API). A
     GCE VM is IPv4-only, so enable IPv4 if you will use the direct endpoint.
3. Confirm the target allows `session_replication_role` (Bucardo needs it on
   apply; Supabase permits it):
   ```bash
   PGPASSWORD='...' psql "host=aws-0-${SB_REGION}.pooler.supabase.com port=5432 user=postgres.${SB_REF} dbname=postgres sslmode=require" \
     -c "SET session_replication_role = replica; RESET session_replication_role;"
   ```
   If this errors with `permission denied`, the target cannot run Bucardo
   (this is the case for Cloud SQL and AlloyDB-as-target; Supabase is fine).

Do **not** create the app schema on the target yourself; pgCopyDB creates it.

---

# Part 4: Install pgCopyDB and Bucardo on the VM

pgCopyDB shells out to `pg_dump`/`pg_restore`, and `pg_dump` refuses to dump a
server newer than itself. AlloyDB is **PG17**, so we need `pg_dump` **17** and a
pgCopyDB built for PG17. We get both from the **PGDG apt repository** and pin the
pgCopyDB build.

Why PGDG and not just a newer base OS: no distro whose default PostgreSQL is
below 17 ships a `pg_dump` that can dump PG17 (Debian 12 = PG15, Ubuntu 24.04 LTS
= PG16), so you would add PGDG regardless. And a distro's own `pgcopydb` is
frozen at release and lags upstream. PGDG is the authoritative, continuously
updated source for pgCopyDB and every `postgresql-client-NN`, works on Debian and
Ubuntu alike, and lets you pin an exact build.

```bash
# On the VM: add PGDG
sudo apt-get update && sudo apt-get install -y curl ca-certificates gnupg
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
  https://www.postgresql.org/media/keys/ACCC4CF8.asc
. /etc/os-release
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update

# Check the available pgcopydb build for your base OS, then pin it:
apt-cache policy pgcopydb        # e.g. Candidate: 0.18-1.pgdg12+1 on Debian 12

# Pin pgcopydb to a known-good build. Adjust the build suffix to your base OS:
#   Debian 12 -> pgdg12+1,  Debian 13 -> pgdg13+1,  Ubuntu 24.04 -> pgdg24.04+1
# postgresql-client-17 stays major-pinned to 17 (any 17.x pg_dump works, and you
# still get 17.x security updates).
PGCOPYDB_VER="0.18-1.pgdg12+1"
sudo apt-get install -y \
  postgresql-client-17 \
  "pgcopydb=${PGCOPYDB_VER}" \
  bucardo postgresql postgresql-plperl
sudo apt-mark hold pgcopydb      # freeze pgcopydb against accidental upgrades

# Verify: pgcopydb should say "compatible with Postgres ... 17"; pg_dump must be 17.x
export PATH=/usr/lib/postgresql/17/bin:$PATH
pgcopydb --version
pg_dump --version
```

Note: `apt-get install bucardo postgresql` also installs a local PostgreSQL on
the VM; Bucardo uses it for its control database.

---

# Part 5: Initial copy with pgCopyDB (run on a clean source)

Run this **before** setting up Bucardo. If the source already has Bucardo
triggers, pgCopyDB's schema dump will include them and the target restore will
fail (`schema "bucardo" does not exist`).

```bash
# On the VM
export PATH=/usr/lib/postgresql/17/bin:$PATH
export PGCOPYDB_SOURCE_PGURI="host=127.0.0.1 port=5433 user=postgres password='SRC_PW' dbname=${SRC_DB} sslmode=disable"
export PGCOPYDB_TARGET_PGURI="host=db.${SB_REF}.supabase.co port=5432 user=postgres password='SB_PW' dbname=postgres sslmode=require"

# Filters: copy only your app schema; skip AlloyDB's own schemas/extensions.
cat > /tmp/filters.ini <<'FIL'
[exclude-schema]
bucardo
ai
google_ml
FIL

pgcopydb clone \
  --table-jobs 8 --index-jobs 4 \
  --split-tables-larger-than 256MB \
  --skip-extensions --no-owner --no-acl \
  --filters /tmp/filters.ini
```

Notes and options:
- `--skip-extensions --no-owner --no-acl`: AlloyDB ships Google-specific
  extensions (`google_ml_integration`, `google_columnar_engine`, ...) and roles
  the target does not have; these flags avoid importing them.
- `[exclude-schema]`: list every non-app schema in the source. Include `public`
  too if it holds nothing you want.
- pgCopyDB automatically splits large tables into parallel COPY jobs and rebuilds
  indexes in parallel; no manual tuning needed for correctness.

### Gotcha: large index builds over a cross-cloud WAN can hang

If the VM (GCP) and the target (Supabase on AWS) are in different clouds, a
**long, single index build** (for example a large GIN on a `jsonb` column) can
hang: the build runs for many minutes with no traffic on the connection, an idle
middlebox drops it, the index finishes server-side but pgCopyDB never gets the
completion and blocks forever. The data and all other indexes are fine; only the
client hangs. This affects any client (pgCopyDB or plain `psql`), not just
pgCopyDB.

**`CREATE INDEX CONCURRENTLY` does not fix this.** The hang is about the idle
connection, not locking. CONCURRENTLY is still one statement the client blocks on
with an idle connection for the whole build, so it drops the same way. It is
worse on a drop: CONCURRENTLY is not atomic, so an interrupted build leaves an
`INVALID` index you must drop and rebuild, whereas a plain `CREATE INDEX` often
commits server-side despite the client hang. Retrying does not help either: the
build outlasts the idle timeout on every attempt, so it fails deterministically.

**Fix: detach the build from the fragile connection.** Exclude the big index from
pgCopyDB and build it either server-side via `pg_cron` (a background worker, no
long-held WAN connection) or from a client co-located with the target (AWS
us-east-1). Add to `filters.ini`:

```ini
[exclude-index]
your_schema.your_big_gin_index
```

Then build it on the target via pg_cron and poll to completion:

```sql
-- schedule it (runs in a background worker), then unschedule once it starts
select cron.schedule('build_idx', '* * * * *',
  $job$SET statement_timeout=0; SET maintenance_work_mem='512MB';
       CREATE INDEX your_big_gin_index ON your_schema.events USING gin (payload)$job$);
-- watch for the build to start, then stop the job from re-firing:
--   select 1 from pg_stat_activity where query ilike '%your_big_gin_index%' and state='active';
select cron.unschedule('build_idx');

-- poll until valid:
select indisvalid from pg_index i join pg_class c on c.oid=i.indexrelid
 where c.relname='your_big_gin_index';
-- if the row exists but indisvalid=false, the build was interrupted (transient):
--   drop index if exists your_schema.your_big_gin_index;   -- then reschedule
```

Notes:
- pg_cron is available on Supabase; `cron.database_name` must be the database
  holding your tables (usually `postgres`).
- Poll until `indisvalid=true`; only **drop-and-retry if the index shows up
  `INVALID`**. That retry covers a genuinely transient interruption, not the
  deterministic idle-timeout hang above (which is why detaching the build, not
  retrying, is the actual fix).
- **When the target is live during the build** (the zero-downtime flow in
  Appendix A, where Bucardo applies CDC to the target while you build the index),
  prefer `CREATE INDEX CONCURRENTLY` so the build does not lock the table against
  those writes. Caveat: CONCURRENTLY cannot run inside a transaction block, so it
  may not run under pg_cron (pg_cron does run `VACUUM`, which has the same
  restriction, so it may work; validate first); if not, run CONCURRENTLY from an
  in-region client. In the **primary flow** the target takes no writes during the
  build, so the plain `CREATE INDEX` above is fine and locking is not a concern.

### Verify the copy

```bash
# Row counts must match source and target for every table (use timeout 0 for big tables):
for t in $(psql "$PGCOPYDB_SOURCE_PGURI" -tAc \
  "select tablename from pg_tables where schemaname='${SRC_SCHEMA}'"); do
  s=$(psql "$PGCOPYDB_SOURCE_PGURI" -tAc "SET statement_timeout=0; select count(*) from ${SRC_SCHEMA}.$t")
  d=$(psql "$PGCOPYDB_TARGET_PGURI" -tAc "SET statement_timeout=0; select count(*) from ${SRC_SCHEMA}.$t")
  echo "$t: src=$s tgt=$d $([ "$s" = "$d" ] && echo OK || echo MISMATCH)"
done
```

---

# Part 6: Set up Bucardo CDC

## 6a. Install the Bucardo control database (one time)

`bucardo install` is interactive. Run it as the local `postgres` superuser over
the unix socket (peer auth), then set the control-role password to match
`/etc/bucardorc`.

```bash
# On the VM
sudo -u postgres bucardo install \
  --dbhost=/var/run/postgresql --dbuser=postgres --dbname=postgres
# When prompted, accept defaults (P to proceed). If it refuses to run
# non-interactively, use the expect script in this repo: bucardo/bucardo_install.exp

# Set the control-role password and matching /etc/bucardorc
sudo -u postgres psql -c "ALTER ROLE bucardo PASSWORD 'bucardo';"
sudo tee /etc/bucardorc >/dev/null <<'EOF'
dbport = 5432
dbhost = localhost
dbname = bucardo
dbuser = bucardo
dbpass = bucardo
EOF

# The daemon and its files live under the 'bucardo' OS user. Always drive it as:
sudo -u bucardo bucardo status
```

## 6b. Register databases, tables, and the sync

**One-command option (recommended).** [`bucardo_migrate.sh`](bucardo_migrate.sh)
in this repo does all of 6b for you: it enumerates every replicatable table (and
sequence) on the source, tears down any prior sync of the same name, and creates
and starts the sync (`onetimecopy=0`). You never list tables or touch Bucardo
directly. Run it on the VM after the pgCopyDB copy:

```bash
# Preview what would be replicated (no changes):
SRC_DB="$SRC_DB" SRC_PASS='SRC_PW' \
TGT_HOST="aws-0-${SB_REGION}.pooler.supabase.com" TGT_USER="postgres.${SB_REF}" TGT_PASS='SB_PW' \
  ./bucardo_migrate.sh --dry-run

# Apply, then check row-count parity:
SRC_DB="$SRC_DB" SRC_PASS='SRC_PW' \
TGT_HOST="aws-0-${SB_REGION}.pooler.supabase.com" TGT_USER="postgres.${SB_REF}" TGT_PASS='SB_PW' \
  ./bucardo_migrate.sh --verify
```

It skips (and lists) any table without a PK/unique index, since Bucardo cannot
replicate those; pass `STRICT=1` to abort instead. See the script header for all
knobs (`SCHEMAS`, `EXCLUDE_SCHEMAS`, `SYNC`, `REPLICATE_SEQUENCES`, ...). Then go
to Part 7 to validate. Requires the control DB from 6a.

The manual equivalent is below, for reference or debugging:

```bash
# Source (AlloyDB via the proxy) and target (Supabase via the session pooler)
sudo -u bucardo bucardo add db srcdb \
  dbname="$SRC_DB" host=127.0.0.1 port=5433 user=postgres pass='SRC_PW'

sudo -u bucardo bucardo add db tgtdb \
  dbname=postgres host="aws-0-${SB_REGION}.pooler.supabase.com" port=5432 \
  user="postgres.${SB_REF}" pass='SB_PW'

# Relgroup + tables. List tables EXPLICITLY;
# "bucardo add all tables schema=..." throws "Can't use string as an ARRAY ref".
sudo -u bucardo bucardo add table \
  ${SRC_SCHEMA}.table1 ${SRC_SCHEMA}.table2 ${SRC_SCHEMA}.table3 \
  db=srcdb relgroup=migrels

# Sync with onetimecopy=0: triggers-only CDC, NO re-copy (pgCopyDB already
# loaded the data). autokick=1 (default) applies changes continuously.
sudo -u bucardo bucardo add sync migsync \
  relgroup=migrels dbs=srcdb:source,tgtdb:target onetimecopy=0
```

Tip: every table to be replicated must have a primary key or a unique index.

## 6c. Start the daemon

```bash
sudo rm -f /var/run/bucardo/fullstopbucardo   # clear any stale full-stop flag
sudo -u bucardo bucardo start
sleep 8
sudo -u bucardo bucardo status migsync        # expect: Current state: Good, Onetimecopy: No
```

---

# Part 7: Validate CDC

Make a change on the source and confirm it reaches the target within a few
seconds. Use a primary-key range as a fast probe on large tables.

```bash
SRC="host=127.0.0.1 port=5433 user=postgres password='SRC_PW' dbname=${SRC_DB} sslmode=disable"
TGT="host=aws-0-${SB_REGION}.pooler.supabase.com port=5432 user=postgres.${SB_REF} dbname=postgres sslmode=require"

# INSERT on source:
psql "$SRC" -c "insert into ${SRC_SCHEMA}.some_table (col) values ('cdc-probe');"
sleep 5
# Confirm on target:
psql "$TGT" -c "select * from ${SRC_SCHEMA}.some_table where col='cdc-probe';"
# Then test UPDATE and DELETE the same way, and clean up the probe row.
```

Expected lag is a few seconds and is independent of table size. Check counters
with `sudo -u bucardo bucardo status migsync`.

---

# Part 8: Cutover

1. Put the application into maintenance / stop writes to AlloyDB.
2. Wait for Bucardo to drain: `sudo -u bucardo bucardo status migsync` until the
   last-good time is current and there is no backlog.
3. Final verification: re-run the row-count check from Part 5.
4. Reset sequences on the target if needed (pgCopyDB set them at copy time; if
   the source advanced them during CDC, re-sync with `setval` from the source
   max per sequence).
5. Point the application at Supabase.
6. Stop Bucardo: `sudo -u bucardo bucardo stop`.

---

# Part 9: Cleanup

```bash
# Remove the Bucardo sync + its source triggers (triggers are NOT auto-removed):
sudo -u bucardo bucardo stop
sudo -u bucardo bucardo remove sync migsync
sudo -u bucardo bucardo remove relgroup migrels
sudo -u bucardo bucardo remove table ${SRC_SCHEMA}.table1 ${SRC_SCHEMA}.table2 ...
# Drop any leftover bucardo triggers on the source if the above did not:
#   DROP TRIGGER bucardo_* ON ${SRC_SCHEMA}.<table>;  (and the bucardo schema)

# Tear down the VM when done:
gcloud compute instances delete "$VM_NAME" --zone="$VM_ZONE"
```

---

# Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `pgcopydb` version says "compatible with Postgres 10-15" | Debian's 0.10. Install 0.18+ from PGDG (Part 4). |
| pgCopyDB restore: `schema "bucardo" does not exist` | Source already has Bucardo triggers. Run pgCopyDB **before** Bucardo, on a clean source. |
| pgCopyDB hangs after a big index (0% CPU, never exits) | Long index build over cross-cloud WAN, connection dropped. Exclude the index and build it server-side via pg_cron (Part 5). Data is fine; `pkill pgcopydb`. |
| pgCopyDB target error `permission denied for function pg_replication_origin_oid` | You used `--follow`. Do not; use Bucardo for CDC (that is this runbook). |
| `bucardo add all tables schema=...` errors `Can't use string as an ARRAY ref` | List the tables explicitly. |
| `bucardo start/stop`: `Permission denied ... /var/log/bucardo` | Run as the bucardo user: `sudo -u bucardo bucardo ...`. |
| Bucardo sync goes `Bad`, target error `SQLSTATE 42501` on `session_replication_role` | Target forbids `session_replication_role` (Cloud SQL / AlloyDB-as-target). Bucardo cannot apply there. Supabase is fine. |
| Big `CREATE INDEX` / `count(*)` cancelled after ~2 min on Supabase | Default `statement_timeout`. `SET statement_timeout = 0` in that session. |
| Direct target host does not resolve from the VM | Direct endpoint is IPv6-only without the IPv4 add-on. Enable IPv4, or use the session pooler. |
| Bucardo sync `Bad` after a crash, stale full-stop | `sudo rm -f /var/run/bucardo/fullstopbucardo` then `sudo -u bucardo bucardo start`. |

---

# Appendix A: zero-downtime on a busy source

The simple flow loses writes that happen during the initial copy, because
Bucardo starts capturing only after the copy. For a source that cannot be made
read-only for the duration of the copy, capture changes **during** the copy:

1. Copy the **schema only** while the source is still clean (no Bucardo triggers
   yet): `pgcopydb clone --skip-extensions --no-owner --no-acl --filters ... `
   with data excluded (or `pgcopydb copy schema`). Consider excluding large
   indexes here and building them at the end.
2. Configure Bucardo (`add db/relgroup/table/sync onetimecopy=0`) **with
   `autokick=0`** and `bucardo start`. Triggers now record every changed row's
   key into Bucardo's delta tables, but nothing is applied yet.
3. Copy the **data** with `pgcopydb copy table-data` (into the pre-created
   schema). Because Bucardo is only recording (not applying), there is no
   COPY-vs-apply conflict.
4. Build any excluded indexes on the target (pg_cron, Part 5).
5. `sudo -u bucardo bucardo update sync migsync autokick=1` and
   `sudo -u bucardo bucardo kick migsync`. Bucardo now applies the accumulated
   deltas by re-reading current source rows per key (idempotent upsert), so any
   row changed during the copy converges to its current value. Ongoing CDC then
   continues normally.

This ordering is the standard trigger-based-CDC pattern but has more moving
parts than the simple flow. **Validate it in a staging copy before running it
against production data.**
