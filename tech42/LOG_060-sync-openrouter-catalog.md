# LOG_060 — DeskcommCRM TESTE: sync catálogo OpenRouter + bump mem app

- **Data (BRT):** 2026-11-14 noite (~22:28+ BRT)
- **Sync UTC:** ~2026-11-15T01:28:16Z
- **Ambiente:** DeskcommCRM de TESTE — https://deskcomm.jcplanejamento.com.br
- **VPS:** fiadopro-vps · pasta `/srv/projetos/clientes/fala42`
- **Escopo:** somente DeskcommCRM; Fiado Pro e demais sistemas não alterados
- **Agente publicado:** NÃO
- **Autor:** engenheiro-devops sob CTO (missão autorizada Jorge 14/11/2026)

## Objetivo
Sincronizar o catálogo OpenRouter no DeskcommCRM TESTE sem derrubar Fiado Pro nem outros sistemas.

## Causa raiz (por que o sync automático não tinha rodado)
1. Job `api/v1/cron/sync-model-catalog` **existe** no crontab do scheduler (`15 4 * * *` UTC).
2. Desde o deploy do ambiente de teste, a janela **04:15 UTC ainda não tinha disparado** no momento da missão (~01:28 UTC de 15/11).
3. Crons concorrentes falhavam com `curl (52) Empty reply` sob `APP_MEM_LIMIT=384m` (pressão de memória / OOM-like), **não** por mismatch de secret.
4. `INTERNAL_SECRET` app↔scheduler: **iguais** (comparação por hash). Auth cron validada (Bearer / `x-cron-secret`) → HTTP 200 em probe leve.
5. Scheduler **não** expõe `INTERNAL_CRON_SECRET` no env do container (só `INTERNAL_SECRET`); contrato oficial aceita ambos — sem impacto no probe.

## O que mudou
| Item | Ação |
|------|------|
| Overlay Tech42 | `docker-compose.tech42.yml`: default `APP_MEM_LIMIT` **384m → 512m** (backup local `.bak.membump_*`) |
| `.env` (não versionado) | `APP_MEM_LIMIT=512m` |
| Recreate | somente `deskcommcrm-app-1` (compose prod + single-server + tech42) |
| Scheduler | sem recreate |
| Decisão mem | **manter 512 MiB** — RAM available ≥2GB e Fiado Pro OK |

## Sync manual (memory-safe)
- Método: HTTP POST host → `http://127.0.0.1:10028/api/v1/cron/sync-model-catalog`
- Header: `x-cron-secret` (lido do `.env` sem echo de valor)
- **HTTP 200**
- Resumo resposta (sem segredos): `fonte=openrouter`, recebidos=**471**, gravados=**471**, depreciados=0, ressuscitados=0; nativos models.dev recebidos=50 / gravados=25
- Mem app durante/após: ~226 MiB / **512 MiB**; OOMKilled=false; health=healthy
- **Nenhum** `node` extra dentro do container app

## SQL read-only (`ai_models`)
- `count(*) WHERE provider='openrouter'` → **471**
- `EXISTS` `model_id='openai/gpt-6-luna-pro' AND deprecated_at IS NULL` → **true** (synced_at ~01:28:16 UTC)

## Inventário saúde
| Check | Antes | Depois |
|-------|-------|--------|
| Fiado Pro `GET :10004/api/health` | **200** | **200** |
| Deskcomm `GET :10028/api/v1/health` | **200** | **200** |
| RAM available (host) | ~2614 MB | ~2564 MB |
| Limite mem app | 384 MiB | **512 MiB** |

## Ajustes WhatsApp / Meta do mesmo dia (contexto; sem segredos)
Registro operacional complementar ao LOG_059 — valores públicos apenas:

- App Meta trocado para **"Método Planejar - Atendimento"** (`app_id` **1666720691138367**)
- `meta_waba_id` do canal corrigido **1613556960341239 → 2384470925321207**
- Política de privacidade temporária: https://fiadopro.com.br/privacidade
- Segredos **somente no Mac** (não nesta VPS log): `~/Backups-Locais/deskcommcrm/privado` e `~/TECH42/privado`

## Segredos
- Nenhum token, `INTERNAL_*`, `DATABASE_URL`, App Secret, verify token ou `.env` neste log.
- Staging de sync: resposta JSON em `/tmp` do host VPS (efêmero); sem cópia de secret.

## Paths úteis
- Overlay: `/srv/projetos/clientes/fala42/docker-compose.tech42.yml`
- LOGs Tech42: `/srv/projetos/clientes/fala42/tech42/`
- Docker logs: `deskcommcrm-app-1`, `deskcommcrm-scheduler-1`
- Runtime: `/srv/projetos/clientes/fala42/.runtime/`

## Status final
- Catálogo OpenRouter sincronizado (**471** modelos).
- `openai/gpt-6-luna-pro` ativo no catálogo.
- App em **512 MiB**; Fiado Pro intacto (**200**).
- Agente: **não publicado**.
