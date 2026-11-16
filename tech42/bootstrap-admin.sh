#!/usr/bin/env bash
# Aplica baseline.sql + cria admin inicial (SQL oficial do kit). Sem imprimir segredos.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNTIME_DIR="$PROJECT_DIR/.runtime"
SUPABASE_DIR="$RUNTIME_DIR/supabase"
CREDENTIALS_FILE="$RUNTIME_DIR/admin-credentials"
NET_NAME="deskcommcrm_supabase"
API_GW_HTTP_PORT=10050
DOMAIN="${DOMAIN:-deskcomm.jcplanejamento.com.br}"
APP_LOCALE="pt-BR"
AI_PROVIDER=""

log() { printf '[tech42] %s\n' "$*"; }
die() { printf '[tech42] ERRO: %s\n' "$*" >&2; exit 1; }

ler_env() {
  local arquivo="$1" chave="$2" linha
  linha="$(grep -E "^${chave}=" "$arquivo" 2>/dev/null | tail -1 || true)"
  linha="${linha#*=}"
  linha="${linha#\"}"; linha="${linha%\"}"
  linha="${linha#\'}"; linha="${linha%\'}"
  printf '%s' "$linha"
}

supabase_env="$SUPABASE_DIR/.env"
app_env="$PROJECT_DIR/.env"
[[ -f "$supabase_env" && -f "$app_env" && -f "$CREDENTIALS_FILE" ]] || die "faltam .env/credenciais"

service_key="$(ler_env "$supabase_env" SERVICE_ROLE_KEY)"
postgres_password="$(ler_env "$supabase_env" POSTGRES_PASSWORD)"
OWNER_EMAIL="$(ler_env "$CREDENTIALS_FILE" OWNER_EMAIL)"
OWNER_PASSWORD="$(ler_env "$CREDENTIALS_FILE" OWNER_PASSWORD)"
[[ -n "$service_key" && -n "$postgres_password" && -n "$OWNER_EMAIL" && -n "$OWNER_PASSWORD" ]] || die "credenciais incompletas"

postgres_password_uri="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$postgres_password")"
DB_URL="postgresql://postgres:${postgres_password_uri}@supabase-db:5432/postgres"

log "Aplicando baseline.sql (pode demorar; log em baseline-apply.log)"
SCHEMA_LOG="$PROJECT_DIR/baseline-apply.log"
(umask 077 && : > "$SCHEMA_LOG")
if ! docker run --rm --network "$NET_NAME" \
  -v "$PROJECT_DIR/supabase/baseline.sql:/baseline.sql:ro" \
  postgres:17.6-alpine \
  psql "$DB_URL" -v ON_ERROR_STOP=1 -f /baseline.sql \
  >"$SCHEMA_LOG" 2>&1; then
  # Reaplicacao: se ja tem tabelas, pode falhar — checa organizations
  if docker run --rm --network "$NET_NAME" postgres:17.6-alpine \
    psql "$DB_URL" -tAc "select 1 from information_schema.tables where table_schema='public' and table_name='organizations'" 2>/dev/null | grep -q 1; then
    log "baseline ja aplicado (organizations existe)"
  else
    die "baseline falhou — ver $SCHEMA_LOG"
  fi
fi

log "Criando usuario admin no Auth"
create_log="$RUNTIME_DIR/admin-create.log"
(umask 077 && : > "$create_log")
http_code="$(curl -sS -o "$create_log" -w '%{http_code}' \
  -X POST "http://127.0.0.1:${API_GW_HTTP_PORT}/auth/v1/admin/users" \
  -H "apikey: ${service_key}" \
  -H "Authorization: Bearer ${service_key}" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${OWNER_EMAIL}\",\"password\":\"${OWNER_PASSWORD}\",\"email_confirm\":true,\"user_metadata\":{\"locale\":\"${APP_LOCALE}\"}}" || true)"
log "Auth HTTP $http_code (200/201=ok, 422=ja existe)"

log "Promovendo owner (SQL oficial do kit)"
PROMOTE_LOG="$RUNTIME_DIR/promote-owner.log"
PROMOTE_SQL="$RUNTIME_DIR/promote-owner.sql"
(umask 077 && : > "$PROMOTE_LOG")
(umask 077 && cat > "$PROMOTE_SQL" <<SQL
do \$\$
declare v_org uuid; v_uid uuid;
begin
  select id into v_uid from auth.users where email = '${OWNER_EMAIL}';
  if v_uid is null then
    raise exception 'usuario % nao encontrado no auth.users', '${OWNER_EMAIL}';
  end if;
  select id into v_org from public.organizations where slug='minha-empresa';
  if v_org is null then
    insert into public.organizations (slug, display_name, legal_name, locale, created_by)
    values ('minha-empresa','Minha Empresa','Minha Empresa','${APP_LOCALE}', v_uid)
    returning id into v_org;
  else
    update public.organizations
       set locale = '${APP_LOCALE}'
     where id = v_org and coalesce(locale, 'pt-BR') = 'pt-BR';
  end if;
  insert into public.user_organizations (user_id, organization_id, role, accepted_at)
  values (v_uid, v_org, 'admin', now())
  on conflict (user_id, organization_id) do update set role='admin', revoked_at=null;
  if not exists (select 1 from public.platform_admins where user_id=v_uid and revoked_at is null) then
    insert into public.platform_admins (user_id, granted_by, scope, mfa_required, reason)
    values (v_uid, v_uid, 'full', false, 'Bootstrap inicial do self-host');
  end if;
end \$\$;
SQL
)

docker run --rm --network "$NET_NAME" \
  -v "$PROMOTE_SQL:/promote.sql:ro" \
  postgres:17.6-alpine \
  psql "$DB_URL" -v ON_ERROR_STOP=1 -f /promote.sql \
  >"$PROMOTE_LOG" 2>&1 || die "promote owner falhou — ver $PROMOTE_LOG"

log "Bootstrap OK. Login em https://${DOMAIN} — usuario: ${OWNER_EMAIL}"
log "Senha somente em: ${CREDENTIALS_FILE}"
