# Bucardo AlloyDB -> Supabase migration benchmarks

Initial full-copy (Bucardo `onetimecopy`) throughput for the `shop` dataset, per scale rung.

## Topology
- **Source:** AlloyDB PostgreSQL 17 (`migtest.shop`), us-west2, via the AlloyDB Auth Proxy.
- **Bucardo host:** GCE `e2-micro` (Debian 12), us-west1 — daemon + control DB only.
- **Target:** Supabase (green) PostgreSQL 17, `small` compute, us-east-1, via the session pooler.
- Cross-region source -> host -> target (real WAN on the target write hop).

## Results

| scale | rows       | target size | copy time | rows/s   | MB/s | CDC lag |
|------:|-----------:|------------:|----------:|---------:|-----:|--------:|
| 1     | 255,607    | ~151 MB     | 9 s       | ~28,400  | ~17  | ~4 s    |
| 10    | 2,554,079  | 938 MB      | 114 s     | ~22,400  | ~8.2 | ~4 s    |

Dataset = full `shop` schema incl. 1.5M `events` rows (scale=10) with a GIN index on `jsonb` `payload`, maintained during load.

## Notes
- All 6 tables verified row-for-row against source after each copy; ongoing CDC confirmed each time (source insert lands on target in ~4 s).
- **pg_flight_recorder** (troubleshooting profile) on the target captured each copy. At scale=10: WAL rose ~16 MB -> ~2.5 GB over the copy window; wait events CPU-bound with light `DataFileRead`; a post-copy vacuum cleaned up the `events` GIN index; no anomalies.
- Throughput dip 1 -> 10 (28.4K -> 22.4K rows/s) is expected: GIN-index maintenance on the larger `events` table plus WAN to the target.
- **Cloud SQL / AlloyDB targets are not usable with stock Bucardo** (they block `session_replication_role`); see issue #1. Supabase permits it, so these are unmodified-Bucardo runs.

## Reproduction
- Data generator: `sql/build_migtest.sql` (`\set scale N`; 1 -> 255K rows, 10 -> 2.55M).
- Bucardo target wiring: drop stale target db, `bucardo add db <green> ...`, `add relgroup migrels`, `add table shop.* db=alloydb_src relgroup=migrels`, `add sync migsync relgroup=migrels dbs=alloydb_src:source,<green>:target onetimecopy=2`, `start`, `kick migsync 0`. See `bucardo/configure_sync.sh`.
