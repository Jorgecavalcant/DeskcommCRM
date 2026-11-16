# LOG_062 — Fala42 renomear + mover pasta + domínio público

**Data:** 2026-11-16 (America/Sao_Paulo)  
**Autorização CEO:** Jorge — "altere tudo"  
**Executor:** diretor-tecnologia via /jc + sniper-delegation  
**Pré-condição:** LOG_061 concluído; VPS livre

## Objetivo
Renomear DeskcommCRM self-hosted para **Fala42**, mover de `/srv/projetos/laboratorio/deskcommcrm` para `/srv/projetos/clientes/fala42`, publicar https://fala42.tech42.com.br sem perda de dados.

## Protocolo
- sniper-delegation aplicado
- Infra/SSH/Caddy/docker: CTO direto
- Overlay mecânico (APP_NAME/DOMAIN/docs): edição 1–2 linhas / sed
- Código TS de produto: **não alterado** (`DEFAULT_APP_NAME` intacto)
- Modelos API: não houve geração de lógica TS nesta rodada; revisão de PR do overlay via OpenRouter `x-ai/grok-4.7` (ver PR)

## Passo 2 — Backup
- Mac: `~/Backups-Locais/deskcommcrm/20261116-1159/` (+ `privado/` 700/600)
- VPS staging: `/tmp/fala42-backup-20261116-1159/`
- Conteúdo: envs, pg dumps (globals/postgres/_supabase), tarballs volumes (waha-data/media/db-config), binds (pgdata/storage/supabase-volumes-excl-pgdata), Caddyfile pré
- Restore teste: DB temp `fala42_restore_test` — 283 tabelas (= live), depois DROP
- SHA256: **12/12 OK** Mac ↔ VPS

## Fase A — rename visível
- `platform_branding.app_name` → Fala42
- `.env` `APP_NAME=Fala42`
- `tech42/install-tech42.sh` seed APP_NAME=Fala42
- `DEFAULT_APP_NAME` em `lib/branding.ts` **não** alterado

## Fase B — move
- Gravado `COMPOSE_PROJECT_NAME=deskcommcrm` no `.env` raiz **antes** do mv
- down app → down supabase (`--remove-orphans`, **sem** `-v`)
- `mv` → `/srv/projetos/clientes/fala42`
- up supabase → up app
- Resultado: **13** containers `deskcommcrm-*`; volumes nomeados intactos; bind PG no path novo; domínio legado HTTP 200
- Docs overlay atualizados para path novo

## Fase C — domínio público
- dig A `fala42.tech42.com.br` = 46.224.55.18 (reconfirmado)
- Caddy: bloco **novo** paralelo (legado **mantido**); backup datado; validate; `caddy reload` (sem restart)
- TLS Let’s Encrypt OK; HTTPS 200; WAHA global 403
- URLs `.env` atualizadas (APP: DOMAIN, NEXT_PUBLIC_APP_URL, NEXT_PUBLIC_SUPABASE_URL; SB: SUPABASE_PUBLIC_URL, API_EXTERNAL_URL, SITE_URL, PROXY_DOMAIN; ADDITIONAL_REDIRECT_URLS com **ambos** hosts)
- recreate `--no-deps`: auth + app
- Meta Developers: **não** alterado

## Health final
- https://fala42.tech42.com.br → 200 (marca Fala42 no HTML)
- https://deskcomm.jcplanejamento.com.br → 200
- Fiado Pro / demais stacks intocados
- RAM ~7.6G avail ~2.6G; disco 82% (~14G livres)

## Meta Callback (pendência CEO)
- Path: `/api/v1/webhooks/meta/<webhook_path_token>`
- Host novo: `https://fala42.tech42.com.br`
- URL completa (600): `/srv/projetos/clientes/fala42/.runtime/meta-callback-url-fala42.txt`
- Verify Token: cofre local / painel (não rotacionado nesta rodada)
- Canal `meta_cloud` status WORKING; override URI ainda null (erro histórico #2200)
- WhatsApp outbound de teste **não** disparado: Callback no painel Meta ainda precisa ser atualizado pelo CEO; App Secret pendência do LOG_059

## Rollback C (domínio)
1. Remover bloco `fala42.tech42.com.br` do Caddyfile (ou restaurar `/srv/infraestrutura/caddy/Caddyfile.bak-fala42-*`)
2. `docker exec jc-caddy caddy validate` + `caddy reload`
3. Reverter chaves URL nos `.env` a partir dos backups `*.pre-fala42-urls-*` e recreate app+auth `--no-deps`

## Rollback B (pasta)
1. down stacks sem `-v`
2. `mv /srv/projetos/clientes/fala42 /srv/projetos/laboratorio/deskcommcrm`
3. up supabase → app

## Pendências
1. CEO: atualizar Callback URL no Meta Developers para host fala42 (token inalterado)
2. CEO: App Secret em `/admin/meta` (LOG_059)
3. Remover bloco legado deskcomm quando CEO autorizar
4. Merge do PR overlay no fork (CEO)
