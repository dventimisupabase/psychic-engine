# Bucardo migration tooling

Helpers for replicating from AlloyDB (source) to Supabase (target) with Bucardo,
part of the AlloyDB -> Supabase migration experiments.

## Topology (pulse)
- Source: AlloyDB `migtest.shop`, reached via the AlloyDB Auth Proxy.
- Bucardo host: a GCE VM (Debian 12). `sudo apt install bucardo` pulls Bucardo plus
  all Perl deps (DBD::Pg, DBIx::Safe) and a local Postgres for the control DB. This
  is far easier than building from source on macOS (Apple's system Perl lacks the
  DBI build headers needed to compile DBD::Pg).
- Control DB: local Postgres on the VM (Bucardo's bookkeeping, not the data).
- Target: Supabase Postgres.

## bucardo_install.exp
`bucardo install` is interactive and reads its prompt from the tty, so it hangs
under `ssh --command`. This expect script drives it. The key trick is forcing the
install to connect as the `postgres` superuser over the local socket; see the
header comment in the script for the full explanation.

Usage on the VM:

    sudo apt-get install -y expect
    expect -f bucardo_install.exp
    sudo -u postgres psql -c "ALTER ROLE bucardo PASSWORD 'bucardo'"
    bucardo status   # -> "No syncs have been created yet."
