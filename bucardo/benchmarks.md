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

## scale=1000 initial copy — DIY snapshot method (not Bucardo onetimecopy)

Bucardo `onetimecopy` does **not** scale to this rung. Its single-transaction copy holds ~100 GB of un-recyclable WAL on top of the data (≈2× disk), which crashed the target at scale=1000 (issue #3). So the initial bulk load used a **DIY logical-replication-free snapshot copy** (`bucardo/diy_initial_sync.py`): one `pg_export_snapshot()` anchor connection + N parallel workers that `SET TRANSACTION SNAPSHOT` and stream binary `COPY` per PK-range chunk, committing per chunk (WAL recycles, no disk bomb). No replication slot, no `wal_level=logical` — so it stays logical-replication-free, like Bucardo's triggers. Bucardo is then used for **ongoing CDC only** (`onetimecopy=0`).

| metric | value |
|---|---|
| rows | 255,501,476 (all 6 tables verified source == target) |
| target size | 55 GB (**index-light**: PK + unique only) |
| copy time | 8,395 s (~2 h 20 m) |
| throughput | ~30,400 rows/s (~5-6 MB/s) |
| workers | 16 (big tables chunked by identity PK) |
| target disk | 250 GB (grown from **12 GB** via the Management API before the run) |

- **Index-light rung (user decision):** the scale=1000 source carries no secondary/GIN indexes (stripped for generation feasibility), so none were built on the target. The 6 btrees + the `events` GIN were exercised at scale=100.
- **Throughput is WAN-bound, not tunable from the copy side (evidenced):** 8 workers == 16 workers (same ~5-6 MB/s, so not parallelism); 14 of 16 target COPY backends parked on `ClientRead` (target *starved*, not write-bound, so a bigger target compute wouldn't help); copy-host CPU ~85% idle. The ceiling is the cross-cloud path GCP us-west1 → Supabase session pooler @ AWS us-east-1.
- **Disk was the real scale=1000 blocker earlier:** the target disk was only 12 GB. Grew it online to 250 GB via `POST https://api.supabase.green/v1/projects/{ref}/config/disk` with `{"attributes":{"size_gb":250,...}}` (Bearer = dashboard session JWT; `PATCH`/`PUT` 404, `POST` needs the `attributes` wrapper).
- CDC lag at scale=1000: _(pending Bucardo CDC test)_.

## Reproduction
- Data generator: `sql/build_migtest.sql` (`\set scale N`; 1 -> 255K rows, 10 -> 2.55M).
- Bucardo target wiring: drop stale target db, `bucardo add db <green> ...`, `add relgroup migrels`, `add table shop.* db=alloydb_src relgroup=migrels`, `add sync migsync relgroup=migrels dbs=alloydb_src:source,<green>:target onetimecopy=2`, `start`, `kick migsync 0`. See `bucardo/configure_sync.sh`.
