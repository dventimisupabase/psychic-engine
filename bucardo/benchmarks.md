# Bucardo AlloyDB -> Supabase migration benchmarks

Initial full-copy (Bucardo `onetimecopy`) throughput for the `shop` dataset, per scale rung.

## Topology
- **Source:** AlloyDB PostgreSQL 17 (`migtest.shop`), us-west2, via the AlloyDB Auth Proxy.
- **Bucardo host:** GCE `e2-micro` (Debian 12), us-west1, daemon + control DB only.
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

## scale=1000 initial copy, DIY snapshot method (not Bucardo onetimecopy)

Bucardo `onetimecopy` does **not** scale to this rung. Its single-transaction copy holds ~100 GB of un-recyclable WAL on top of the data (≈2× disk), which crashed the target at scale=1000 (issue #3). So the initial bulk load used a **DIY logical-replication-free snapshot copy** (`bucardo/diy_initial_sync.py`): one `pg_export_snapshot()` anchor connection + N parallel workers that `SET TRANSACTION SNAPSHOT` and stream binary `COPY` per PK-range chunk, committing per chunk (WAL recycles, no disk bomb). No replication slot, no `wal_level=logical`, so it stays logical-replication-free, like Bucardo's triggers. Bucardo is then used for **ongoing CDC only** (`onetimecopy=0`).

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
- **CDC at scale=1000 confirmed:** Bucardo `onetimecopy=0` (delta triggers only, no re-copy, the DIY load already placed the data, and the source is static so there is no snapshot→trigger gap). Insert (1 category + 500 events) replicated in **~4 s**, update **~3 s**, delete **~4 s**; sync state Good. Lag is **size-independent** (same ~2-4 s as scale 1/10/100): Bucardo's CDC scales flat, the initial copy was the only part that needed the DIY workaround. Daemon runs as the `bucardo` OS user (`sudo -u bucardo bucardo start`); files live under `/var/{log,run}/bucardo`.

## pgCopyDB (initial copy) + Bucardo (CDC), scale=100, index-heavy

The "buy" alternative to the DIY snapshot copy: **pgCopyDB for the initial bulk load** (no `--follow`, so still logical-replication-free), **Bucardo for CDC**. Target = green project `jatchjltrqzdmghigvtu` with the **IPv4 add-on** (pgCopyDB uses a *direct* connection, not the pooler; the VM is IPv4-only and Supabase direct is IPv6-only without the add-on). Needed **pgcopydb 0.18 + postgresql-client-17** from PGDG, Debian's stock 0.10 is PG15-only and cannot dump a PG17 server.

Source (AlloyDB, PG17) = full index-heavy `shop`: 25,553,940 rows, 17 indexes incl. a GIN on `events.payload`, 5 FKs.

| metric | value |
|---|---|
| rows | 25,553,940 (all 6 tables source == target) |
| indexes | all 17 rebuilt + valid (incl. GIN, 3.4 GB) |
| copy + index time | **~17 min** |
| target size | ~9.1 GB |
| parallelism | auto-split events→15 COPY procs (on event_id), orders/order_items→4 each; `--index-jobs 4` |

- **Batteries included, and it showed:** one `pgcopydb clone` did schema (pre/post-data via pg_dump/pg_restore 17), parallel COPY with **automatic PK-range splitting** (no key-picking), parallel index rebuild **incl. the GIN**, and sequence resets, while filtering the AlloyDB source's sharp edges via flags: `--exclude-schema bucardo,ai,google_ml,public`, `--skip-extensions` (the `google_*` AlloyDB extensions), `--no-owner --no-acl`. Comparable wall-clock to the scale=100 Bucardo index-workaround (~19 min) but **fully automatic** vs the manual DROP/COPY/CREATE dance.
- **Sharp edge (the "buy" tax): a long, silent operation over the cross-cloud WAN hangs the client. This is NOT a pgcopydb bug.** During the ~14 min `events` GIN build (`idx_events_payload`, 3.4 GB) the connection carries no traffic (the client sent `CREATE INDEX` and waits silently for the result), so a GCP-to-AWS idle-flow middlebox drops it. The index builds and commits fine server-side (`indisvalid=true`), but the completion never reaches the client, which blocks forever (0% CPU, needs a manual `pkill`). Diagnosed by elimination:
  - `--skip-vacuum` did NOT help (the first run's "vacuum phase" was a red herring; vacuum was merely downstream of the stuck index step).
  - Excluding the GIN (`[exclude-index] shop.idx_events_payload`) let pgcopydb sail through COPY, btrees, vacuum, and reach post-data in ~6 min with no hang, proving the GIN build (not pgcopydb) is the trigger.
  - A plain `psql CREATE INDEX ... gin` outside pgcopydb hung identically (index `valid=true` server-side, client blocked), proving it is the WAN/connection, not the tool.
  - pgcopydb's `keepalives_idle=10` did not prevent it (the path apparently ignores TCP keepalives).

  The migrated data is always complete and correct regardless (25.5M rows, all 17 indexes valid, all 5 FKs). Mitigations: run big index builds from a client co-located with the target (in-region, not the cross-cloud copy host); or fire-and-forget server-side (issue `CREATE INDEX`, drop the WAN connection, poll `pg_index.indisvalid`); or exclude big indexes from pgcopydb and build them that way. The DIY snapshot copy dodged this only because it is index-light and streams data continuously; a large GIN built over this same WAN would hit it too.
- **Ordering matters (buy tax #2):** pgcopydb cannot cleanly re-run against a source that already carries Bucardo's CDC triggers. Its schema dump includes the `bucardo.*` trigger definitions and the target post-data restore fails ("schema bucardo does not exist", 36 ignored errors); the FKs still restore. Run pgcopydb FIRST on a clean source, then add Bucardo.
- **Mitigation validated (fire-and-forget via pg_cron):** dropped the GIN and rebuilt it by scheduling the `CREATE INDEX` as a **pg_cron job** (a server-side background worker), then polled `pg_index.indisvalid` over short connections. It built in **~13 min** (`indisvalid=true`, 17/17 indexes valid) with the client holding **no long connection**, so **no hang**. This is the working "buy" recipe for a cross-cloud copy: pgcopydb for data + btrees, then build big indexes **server-side (pg_cron) or from an in-region client**, never over a long-held WAN connection. (Minor: unscheduling the job mid-run leaves a `canceled` row in `cron.job_run_details` even though the worker completes the index; a one-shot schedule is cleaner for production.)
- **IPv4 add-on required:** cheap on Supabase ($4/mo, provisioned via the `/platform/` Management API); on a stricter managed platform with no direct-connection option it could be a hard blocker, the DIY-vs-buy tradeoff in miniature.

**CDC (Bucardo `onetimecopy=0`) on the pgcopydb-loaded target:** insert ~4 s, update ~3 s, delete ~4 s, identical to every other rung (size-independent). The full **pgCopyDB + Bucardo** pipeline works end to end.

## CDC options: triggers vs logical replication (toolbox)

Three ways to do ongoing CDC AlloyDB -> Supabase:

| CDC option | mechanism | status on Supabase target |
|---|---|---|
| Bucardo | triggers (no LR) | works, ~3-4 s lag, every rung |
| pgCopyDB `--follow` | pgCopyDB-managed logical decoding | **FAILS at setup** (see below) |
| native LR (pub/sub) | self-managed `CREATE PUBLICATION`/`SUBSCRIPTION` | pending |

**AlloyDB source is LR-capable (2026-07-03):** enabled `alloydb.logical_decoding=on` (flag + restart -> `wal_level=logical`), and `postgres` can `ALTER ROLE ... WITH REPLICATION` and create logical slots (`test_decoding` + `pgoutput`). So the source is not the blocker. (`wal2json` is not available on AlloyDB; use `test_decoding`.)

**pgCopyDB `--follow` fails on the Supabase target, and it is the customer's exact wall.** The source slot is created fine (`Created logical replication slot "pgcopydb" with plugin "test_decoding"`), then pgCopyDB calls `pg_replication_origin_oid('pgcopydb')` on the *target* to track apply position and gets:

```
ERROR:  permission denied for function pg_replication_origin_oid
```

The `pg_replication_origin_*` functions are **superuser-only**, and Supabase's `postgres` is not a superuser, so pgCopyDB `--follow` cannot manage its apply-tracking origin and exits `rc=12`. This is why the customer moved off pgCopyDB `--follow`: a native `CREATE SUBSCRIPTION` manages replication origins **internally** (inside the apply worker), so it never issues the client-level `pg_replication_origin_*` call that pgCopyDB does. Note: on failure pgCopyDB leaves the **source slot behind**, drop it (`pg_drop_replication_slot`) or it retains WAL on AlloyDB.

**native LR: privilege-viable on Supabase (confirmed).** The AlloyDB source can `CREATE PUBLICATION` as `postgres`, and the Supabase `postgres` is a member of `pg_create_subscription` (a `WITH (connect=false)` probe only tripped the standard "non-superuser must put a password in the conninfo" rule, not a privilege block). So native LR does sidestep the `pg_replication_origin` wall (the subscription's apply worker manages origins internally) and matches the customer's production choice. We did NOT run the full streaming test: it is subscriber-pull, so it needs the private AlloyDB exposed to Supabase (public IP + authorized networks); native pg SSL requires the real endpoint (a `socat` tunnel can't TLS-terminate Postgres's SSL negotiation, so it would leak the password in cleartext). Given native LR is already proven in the customer's prod, the exposure was not worth it for confirmatory numbers.

### Choosing a CDC tool (AlloyDB -> Supabase, and generally)

Beyond "does it work," the choice turns on source/target constraints:

| dimension | Bucardo (triggers) | native LR |
|---|---|---|
| Logical replication required | no | yes |
| Source `wal_level=logical` (needs a restart) | **no** | yes |
| Expose the source (subscriber-pull) | **no** (VM pushes; both conns outbound) | yes (target must reach source) |
| Target privilege needed | `session_replication_role=replica` | `pg_create_subscription` |
| Source write overhead | triggers + delta rows (heavier) | logical decoding reads WAL (lighter) |
| Extra moving parts | Perl daemon + control DB | none (built-in) |

- **Bucardo's edge:** needs neither a source restart nor source exposure, and works on targets that restrict LR/subscriptions. Pick it when you can't restart/expose the source, or the target forbids LR.
- **native LR's edge:** lighter on the source write path (no triggers), standard Postgres. Pick it when the source permits logical decoding + can be exposed and you want minimal source overhead.
- **pgCopyDB `--follow`:** ruled out for Supabase (target `pg_replication_origin` superuser wall).

## Reproduction
- Data generator: `sql/build_migtest.sql` (`\set scale N`; 1 -> 255K rows, 10 -> 2.55M).
- Bucardo target wiring: drop stale target db, `bucardo add db <green> ...`, `add relgroup migrels`, `add table shop.* db=alloydb_src relgroup=migrels`, `add sync migsync relgroup=migrels dbs=alloydb_src:source,<green>:target onetimecopy=2`, `start`, `kick migsync 0`. See `bucardo/configure_sync.sh`.
