# Bucardo migration tooling

Reproducible setup for replicating AlloyDB (source) -> Supabase (target) with
Bucardo, part of the AlloyDB -> Supabase migration experiments.

> **Operator runbook:** for the full end-to-end migration (pgCopyDB initial copy
> + Bucardo CDC) with exact, copy-paste steps, see
> [RUNBOOK-alloydb-to-supabase.md](RUNBOOK-alloydb-to-supabase.md). This README
> is the Bucardo-tooling reference / quick notes behind that runbook.

## Result (pulse)
Full initial copy of ~255k rows in ~9s, then ongoing CDC: a row inserted on the
AlloyDB source lands on the Supabase target in ~4s.

## Topology
- Source: AlloyDB `migtest.shop`, reached via the AlloyDB Auth Proxy.
- Bucardo host: a GCE VM (Debian 12, Always Free e2-micro). Runs the Bucardo daemon,
  the control DB (local Postgres), and the auth proxy (a systemd service bound to
  127.0.0.1:5433).
- Control DB: local Postgres on the VM (Bucardo bookkeeping, not the data).
- Target: Supabase Postgres via the session-mode connection pooler (the direct db
  host is not reachable over IPv4 from the VM).

## Pipeline

### 0. VM prerequisites
    sudo apt-get install -y bucardo postgresql postgresql-plperl expect
    # plus the Linux alloydb-auth-proxy as a systemd service -> 127.0.0.1:5433

### 1. Install the Bucardo control DB
`bucardo install` is interactive; drive it with `bucardo_install.exp` (it forces a
PTY and answers the menu, connecting as the postgres superuser over the local
socket). Afterward align the role password with /etc/bucardorc:
    sudo -u postgres psql -c "ALTER ROLE bucardo PASSWORD 'bucardo'"

### 2. Source privileges (run as the table OWNER on AlloyDB)
`postgres`/alloydbsuperuser cannot create triggers on objects owned by another
role, so grant it owner rights:
    GRANT CREATE ON DATABASE migtest TO postgres;
    GRANT USAGE, CREATE ON SCHEMA shop TO postgres;
    GRANT SELECT, TRIGGER ON ALL TABLES IN SCHEMA shop TO postgres;
    GRANT "<owner-role>" TO postgres;   -- membership = create AND drop triggers

### 3. Target schema (Bucardo copies DATA, not DDL)
Create the tables on the target first, using a pg_dump whose major version matches
the source server:
    pg_dump "<source>" --schema-only --schema=shop --no-owner --no-privileges \
      | psql "<target>"

### 4. Configure + start the sync
    SRC_PASS=... TGT_HOST=... TGT_USER=postgres.<ref> TGT_PASS=... ./configure_sync.sh

## Gotchas
- `bucardo add all tables schema=...` errors with "Can't use string as an ARRAY
  ref"; list tables explicitly (see configure_sync.sh).
- Use the Supabase SESSION pooler (port 5432), not the transaction pooler (6543);
  Bucardo needs session state.
- The target role must be able to `SET session_replication_role` (Supabase's
  postgres can); Bucardo uses it to disable target FKs/triggers during apply.
- `GENERATED ALWAYS AS IDENTITY` primary keys copy fine via Bucardo's COPY-based
  initial load.
