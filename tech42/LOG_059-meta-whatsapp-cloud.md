# LOG_059 — DeskcommCRM TESTE: WhatsApp Cloud API (Meta)

- **Data:** 2026-11-14 (2026-11-14T23:02:02Z)
- **Ambiente:** DeskcommCRM de TESTE — https://deskcomm.jcplanejamento.com.br
- **VPS:** fiadopro-vps · pasta /srv/projetos/clientes/fala42
- **Escopo:** somente DeskcommCRM; Fiado Pro e demais sistemas não alterados
- **Código do produto:** NÃO modificado

## Objetivo
Conectar o número oficial Meta Cloud API ao canal do DeskcommCRM de teste (channel_sessions + platform_meta_app + webhook).

## Dados públicos usados
- Número: +55 62 9826-4745
- phone_number_id: 887191147815960
- waba_id (via health_status da Graph): 1613556960341239
- App Meta: JC Planejamento | Atendimento (app_id 1890218125256011)
- System user: Integracao Deskcomm

## Ações executadas

### 1) Cofre local (Mac)
- Token permanente refletido em `~/TECH42/privado/deskcommcrm-meta.env` e espelho em `~/Backups-Locais/deskcommcrm/privado/` (chmod 600; pasta privado 700).
- TECH42/privado coberto por `.gitignore` (`privado/*`).
- Verify token gerado (CSPRNG base64url) e guardado em arquivos 600 no cofre (sem valor neste log).

### 2) Cifra at-rest
- `private.app_secrets.nuvemshop_oauth_key` estava **ausente** (chave existia só no `.env`).
- Semeada a partir do `.env` da instalação (mesmo procedimento do kit hostgator) — **sem alterar código**.
- `fn_encrypt_oauth` passou a responder (probe OK).

### 3) platform_meta_app (migration 0257)
- Linha singleton id=1 criada com **verify_token_encrypted** via `fn_encrypt_oauth`.
- **app_secret_encrypted = NULL** (App Secret ainda não disponível).
- Nota de produto: o resolvedor `appDaMeta()` só usa o par completo do banco; sem App Secret cai no `.env` (hoje sem META_*). Handshake do webhook fica 403 até o App Secret ser colado.

### 4) channel_sessions
- Tentativa via API `POST /api/v1/channels/official` (OWNER autenticado): **422 Invalid parameter**.
  - Causa: Graph `GET /{waba_id}/phone_numbers` retorna OAuthException 100 / subcode **2388339** com o system user token (WABA inacessível para listagem, embora `health_status` exponha o id).
- Cadastro via **SQL oficial** com `fn_encrypt_oauth` (autorizado na missão):
  - provider=`meta_cloud`, status=`WORKING`, origem=`token_manual`
  - meta_phone_number_id / meta_waba_id / token cifrado / webhook_path_token gerado
  - session_id: `5d752d65-aca7-4ce4-9b47-73f42c7e7e09`

### 5) Webhook override na Meta
- Tentativa de override no phone_number_id: Meta **#2200** — Callback verification HTTP 403.
- Esperado enquanto App Secret não completa o par verify+secret (e/ou URL ainda não configurada no painel com o verify em vigor).
- Desfecho gravado em `meta_webhook_override_erro` (sem segredo).

### 6) Caddy
- Bloco `deskcomm.jcplanejamento.com.br`: apenas `/api/v1/webhooks/waha` → 403.
- **Nenhuma alteração** no Caddyfile (meta/* já passa pelo reverse_proxy do app).
- WAHA permanece 403.

### 7) Graph API (teste de credencial)
- `GET /v21.0/887191147815960`: HTTP **200**
- display_phone_number: +55 62 9826-4745
- verified_name: JC Planejamento – Atendimento
- quality_rating: GREEN
- status: CONNECTED
- **Nenhuma mensagem enviada** a cliente real.
- Observação de saúde Meta (não bloqueia cadastro): WABA com alerta de método de pagamento; Business sem verificação completa.

## Onde colar o App Secret (próximo passo do CEO)
1. **UI Deskcomm (caminho oficial):** `https://deskcomm.jcplanejamento.com.br/admin/meta` — campo "Chave secreta do aplicativo" (platform admin). Ao salvar, o verify token **já gerado é preservado**.
2. Alternativa SQL: `platform_meta_app.app_secret_encrypted = fn_encrypt_oauth(<app_secret>)` (service_role / psql).
3. Em seguida, no **Meta Developers** (App › WhatsApp › Configuration): colar Callback URL + Verify Token dos arquivos do cofre local; assinar campos messages (+ smb_* se coexistência).

## Recursos VPS (após ação)
- RAM available: 2611 MB
- Disco / disponível: 16G (uso 80%)

## Segredos
- Nenhum token, App Secret, verify token, senha ou service_role neste log.
- Staging `.runtime/meta-connect-*` removido após uso.

## Status final
- Canal: **criado / WORKING** (envio depende de pagamento/verificação Meta; recebimento depende de App Secret + verify no painel Meta).
- Caddy: meta passa; WAHA 403; sem mudança.
- Pendência CEO: colar **App Secret** em `/admin/meta` e configurar Callback URL no painel Meta.

## Caddy follow-up (mesmo LOG)
- Descoberta: `respond @waha_global 403` no topo do site **não bloqueava** (tráfego WAHA chegava ao app: 404/405).
- Correção **somente** no bloco `deskcomm.jcplanejamento.com.br`: `handle @waha_global { respond 403 }`.
- Backup: `/srv/infraestrutura/caddy/Caddyfile.bak-deskcomm-meta-20261114`
- `caddy validate` OK + `caddy reload` (sem restart).
- Pós-reload: WAHA → 403; `/api/v1/webhooks/meta/*` continua passando (404 do app = chegou ao Deskcomm).
