# Bucardo AlloyDB -> Supabase migration benchmarks

Initial full-copy (Bucardo `onetimecopy`) throughput for the `shop` dataset, per scale rung.

## Topology
- **Source:** AlloyDB PostgreSQL 17 (`migtest.shop`), us-west2, via the AlloyDB Auth Proxy.
- **Bucardo host:** GCE `e2-micro` (Debian 12), us-west1 — daemon + control DB only.
- **Target:** Supabase (green) PostgreSQL 17, `small` compute, us-east-1, via the session pooler.
- Cross-region source -> host -> target (real WAN on the target write hop).

## Results

| scale | rows       | target size | copy time      | rows/s   | CDC lag | target |
|------:|-----------:|------------:|---------------:|---------:|--------:|--------|
| 1     | 255,607    | ~151 MB     | 9 s            | ~28,400  | ~4 s    | small  |
| 10    | 2,554,079  | 938 MB      | 114 s          | ~22,400  | ~4 s    | small  |
| 100†  | 25,553,940 | ~9.6 GB     | 239 s (copy)   | ~107,000 | ~2 s    | medium |

Dataset = full `shop` schema incl. `events` (1.5M rows at scale=10, 15M at scale=100) with a GIN index on `jsonb` `payload`.

† **scale=100 used a manual index workaround, not vanilla onetimecopy.** Vanilla onetimecopy (indexes present → the `events` GIN maintained inline, row by row) ran at ~2,700 rows/s and was aborted at ~35 min (≈1.5 h projected; see issue #3). Instead we did the Bucardo-native workaround: `DROP INDEX` the target's secondary indexes → Bucardo `onetimecopy` **index-free = 239 s / ~107K rows/s** → rebuild indexes = **btrees ~76 s + GIN ~836 s (~14 min)**. End-to-end ≈ **19 min**, dominated by the 15M-row `jsonb` GIN rebuild. NB: scale 1 & 10 copy times *include* inline index maintenance, so the 100 copy figure is not apples-to-apples.

## Notes
- All tables verified row-for-row against source after each copy; ongoing CDC confirmed each time.
- **CDC scales flat:** at scale=100 (25.5M rows in place) a 500-row insert replicated in ~2 s and an update + delete propagated correctly. CDC lag tracks change volume, not table size, Bucardo's strong suit. The initial bulk copy is its weak one.
- **onetimecopy doesn't scale (issue #3):** all tables in one transaction, indexes maintained inline. Bucardo's built-in `rebuild_index` would help but writes `pg_class` directly (superuser-only → barred on managed targets), hence the manual DROP/CREATE INDEX workaround.
- **Supabase `statement_timeout` gotcha:** the manual GIN rebuild is killed by the default 2-min `statement_timeout`; the rebuild session needs `SET statement_timeout = 0` (Bucardo's own connections already do this).
- **pg_flight_recorder** (troubleshooting profile) runs on every target and captured each copy (e.g. at scale=10 WAL rose ~16 MB -> ~2.5 GB; post-copy GIN vacuum; no anomalies). On the AlloyDB source it's not installable without enabling `pg_cron` (flag + restart); see issue #2.
- **Cloud SQL / AlloyDB targets are not usable with stock Bucardo** (they block `session_replication_role`); see issue #1. Supabase permits it, so these are unmodified-Bucardo runs.

## Reproduction
- Data generator: `sql/build_migtest.sql` (`\set scale N`; 1 -> 255K rows, 10 -> 2.55M).
- Bucardo target wiring: drop stale target db, `bucardo add db <green> ...`, `add relgroup migrels`, `add table shop.* db=alloydb_src relgroup=migrels`, `add sync migsync relgroup=migrels dbs=alloydb_src:source,<green>:target onetimecopy=2`, `start`, `kick migsync 0`. See `bucardo/configure_sync.sh`.
