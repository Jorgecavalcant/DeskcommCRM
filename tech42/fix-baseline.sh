#!/usr/bin/env bash
# Cria extensões + reaplica baseline (sem imprimir segredos).
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
NET_NAME="deskcommcrm_supabase"
cd "$PROJECT_DIR"

python3 <<'PY'
from pathlib import Path
import urllib.parse
sb = {}
for line in Path(".runtime/supabase/.env").read_text().splitlines():
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1)
        sb[k] = v
pw = sb["POSTGRES_PASSWORD"]
url = "postgresql://postgres:" + urllib.parse.quote(pw, safe="") + "@supabase-db:5432/postgres"
p = Path(".runtime/dburl")
p.write_text(url)
p.chmod(0o600)
print("dburl_ok")
PY

DBURL="$(cat .runtime/dburl)"
log() { printf '[tech42] %s\n' "$*"; }

log "Criando extensoes vector/citext/pg_trgm"
docker run --rm --network "$NET_NAME" postgres:17.6-alpine \
  psql "$DBURL" -v ON_ERROR_STOP=1 \
  -c "create extension if not exists vector with schema public; create extension if not exists citext with schema public; create extension if not exists pg_trgm with schema public;" \
  >/dev/null

n_tables="$(docker run --rm --network "$NET_NAME" postgres:17.6-alpine \
  psql "$DBURL" -tAc "select count(*) from information_schema.tables where table_schema='public';" | tr -d '[:space:]')"
log "Tabelas public atuais: $n_tables"

SCHEMA_LOG="$PROJECT_DIR/baseline-apply.log"
(umask 077 && : > "$SCHEMA_LOG")

has_org="$(docker run --rm --network "$NET_NAME" postgres:17.6-alpine \
  psql "$DBURL" -tAc "select 1 from information_schema.tables where table_schema='public' and table_name='organizations' limit 1" | tr -d '[:space:]' || true)"

if [[ "$has_org" == "1" ]]; then
  log "Schema parcial/existente — reaplicando sem ON_ERROR_STOP"
  docker run --rm --network "$NET_NAME" \
    -v "$PROJECT_DIR/supabase/baseline.sql:/baseline.sql:ro" \
    postgres:17.6-alpine \
    psql "$DBURL" -f /baseline.sql >"$SCHEMA_LOG" 2>&1 || true
else
  log "Aplicando baseline limpo com ON_ERROR_STOP"
  docker run --rm --network "$NET_NAME" \
    -v "$PROJECT_DIR/supabase/baseline.sql:/baseline.sql:ro" \
    postgres:17.6-alpine \
    psql "$DBURL" -v ON_ERROR_STOP=1 -f /baseline.sql >"$SCHEMA_LOG" 2>&1
fi

has_org="$(docker run --rm --network "$NET_NAME" postgres:17.6-alpine \
  psql "$DBURL" -tAc "select 1 from information_schema.tables where table_schema='public' and table_name='organizations' limit 1" | tr -d '[:space:]' || true)"
has_job="$(docker run --rm --network "$NET_NAME" postgres:17.6-alpine \
  psql "$DBURL" -tAc "select 1 from information_schema.tables where table_schema='public' and table_name='job_queue' limit 1" | tr -d '[:space:]' || true)"

log "organizations=$has_org job_queue=$has_job"
if [[ "$has_org" != "1" ]]; then
  # Mostra so linhas ERROR do log
  grep -E '^psql:.*ERROR:' "$SCHEMA_LOG" | tail -20 || true
  exit 1
fi
log "Baseline OK"
rm -f .runtime/dburl
