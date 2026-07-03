#!/usr/bin/env python3
"""
DIY logical-replication-free initial sync: consistent, parallel COPY via
pg_export_snapshot(). No replication slot, no wal_level=logical, no logical
decoding -- only COPY + REPEATABLE READ snapshots, which any managed Postgres
allows. Intended as the initial bulk load ahead of Bucardo (trigger) CDC.

Env:
  SRC_DSN   source libpq DSN (e.g. AlloyDB via the auth proxy)
  TGT_DSN   target libpq DSN (e.g. Supabase via the session pooler)
  JOBS      parallel copy workers (default 8)
  {USERS,ORDERS,ORDER_ITEMS,EVENTS}_CHUNKS
            how many PK-range chunks to split each big table into (more chunks
            = more concurrent streams). NB: aggregate throughput is often WAN-
            bound (cross-cloud / pooler), in which case adding workers/chunks
            does not help -- see bucardo/benchmarks.md scale=1000.

Table plan below: small tables = 1 unit; big tables chunked by an integer key.
Assumes target already has the schema with secondary indexes DROPPED (rebuild
them afterward for speed). Sets session_replication_role=replica on the target
so FK checks are skipped during load (works where the role may set it, e.g.
Supabase; harmless to remove if not permitted).
"""
import os, sys, threading, concurrent.futures, psycopg2

SRC = os.environ["SRC_DSN"]
TGT = os.environ["TGT_DSN"]
JOBS = int(os.environ.get("JOBS", "8"))

# (table, chunk_column_or_None, n_chunks). Big tables are chunked by their
# contiguous identity PK so each chunk streams on its own connection -- the
# more parallel streams, the higher the aggregate throughput when the ceiling
# is per-connection/WAN rather than the copy host's CPU.
TABLES = [
    ("shop.categories",  None,            1),
    ("shop.products",    None,            1),
    ("shop.users",       "user_id",       int(os.environ.get("USERS_CHUNKS", "2"))),
    ("shop.orders",      "order_id",      int(os.environ.get("ORDERS_CHUNKS", "4"))),
    ("shop.order_items", "order_item_id", int(os.environ.get("ORDER_ITEMS_CHUNKS", "8"))),
    ("shop.events",      "event_id",      int(os.environ.get("EVENTS_CHUNKS", "8"))),
]

# Anchor: export one consistent snapshot and keep this connection open for the
# entire run so every worker can attach to the identical instant.
anchor = psycopg2.connect(SRC)
anchor.set_session(isolation_level="REPEATABLE READ", readonly=True)
ac = anchor.cursor()
ac.execute("SELECT pg_export_snapshot()")
SNAP = ac.fetchone()[0]
print(f"exported snapshot {SNAP}", flush=True)

def bounds(table, col):
    with psycopg2.connect(SRC) as c, c.cursor() as cur:
        cur.execute(f"SELECT min({col}), max({col}) FROM {table}")
        return cur.fetchone()

def copy_unit(table, col, lo, hi):
    where = "" if col is None else f"WHERE {col} BETWEEN {lo} AND {hi}"
    s = psycopg2.connect(SRC); s.set_session(isolation_level="REPEATABLE READ", readonly=True)
    sc = s.cursor(); sc.execute(f"SET TRANSACTION SNAPSHOT '{SNAP}'")
    t = psycopg2.connect(TGT); tc = t.cursor()
    tc.execute("SET statement_timeout = 0")
    try: tc.execute("SET session_replication_role = replica")
    except Exception: t.rollback()
    r, w = os.pipe()
    rf, wf = os.fdopen(r, "rb"), os.fdopen(w, "wb")
    def produce():
        try: sc.copy_expert(f"COPY (SELECT * FROM {table} {where}) TO STDOUT (FORMAT binary)", wf)
        finally: wf.close()
    th = threading.Thread(target=produce); th.start()
    tc.copy_expert(f"COPY {table} FROM STDIN (FORMAT binary)", rf)
    rf.close(); th.join(); t.commit()
    s.close(); t.close()
    return f"{table}{'' if col is None else f' [{lo},{hi}]'}"

units = []
for table, col, n in TABLES:
    if not col or n <= 1:
        units.append((table, None, None, None))
    else:
        lo, hi = bounds(table, col)
        step = (hi - lo) // n + 1
        a = lo
        while a <= hi:
            units.append((table, col, a, min(a + step - 1, hi)))
            a += step

print(f"{len(units)} copy units, {JOBS} workers", flush=True)
errors = 0
with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as ex:
    futs = {ex.submit(copy_unit, *u): u for u in units}
    for f in concurrent.futures.as_completed(futs):
        try: print("done:", f.result(), flush=True)
        except Exception as e:
            errors += 1; print("FAILED", futs[f], "->", e, flush=True)

anchor.close()  # release the snapshot only after all workers finished
print("DONE" if errors == 0 else f"COMPLETED WITH {errors} ERRORS", flush=True)
sys.exit(1 if errors else 0)
