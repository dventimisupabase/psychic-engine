#!/usr/bin/env bash
# Configure and start the AlloyDB -> Supabase Bucardo sync. Run ON the Bucardo VM.
# Connection params come from environment variables; NO secrets are stored here.
#
# Required env: SRC_PASS, TGT_HOST, TGT_USER, TGT_PASS
# Example:
#   SRC_PASS=... TGT_HOST=aws-0-us-east-1.pooler.supabase.green \
#   TGT_USER=postgres.<project-ref> TGT_PASS=... ./configure_sync.sh
set -euo pipefail

: "${SRC_HOST:=127.0.0.1}"        # AlloyDB Auth Proxy, local on the VM
: "${SRC_PORT:=5433}"
: "${SRC_DB:=migtest}"
: "${SRC_USER:=postgres}"
: "${SRC_PASS:?set SRC_PASS}"
: "${TGT_HOST:?set TGT_HOST (Supabase session pooler host)}"
: "${TGT_PORT:=5432}"
: "${TGT_DB:=postgres}"
: "${TGT_USER:?set TGT_USER (e.g. postgres.<project-ref>)}"
: "${TGT_PASS:?set TGT_PASS}"
: "${TABLES:=shop.categories shop.products shop.users shop.orders shop.order_items shop.events}"

b() { sudo -u bucardo bucardo "$@"; }

b add db alloydb_src  dbname="$SRC_DB" host="$SRC_HOST" port="$SRC_PORT" user="$SRC_USER" pass="$SRC_PASS" || true
b add db supabase_tgt dbname="$TGT_DB" host="$TGT_HOST" port="$TGT_PORT" user="$TGT_USER" pass="$TGT_PASS" || true
b add relgroup migrels || true

# NOTE: `bucardo add all tables schema=...` fails with
# "Can't use string as an ARRAY ref" — list the tables explicitly instead.
b add table $TABLES db=alloydb_src relgroup=migrels

b add sync migsync relgroup=migrels dbs=alloydb_src:source,supabase_tgt:target onetimecopy=2
b start 'pulse'
b kick migsync 0
b status migsync
