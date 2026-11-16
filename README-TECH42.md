# Fala42 — operação Tech42 (DeskcommCRM self-hosted)

**URL:** https://fala42.tech42.com.br (novo) · alias legado https://deskcomm.jcplanejamento.com.br  
**Pasta:** `/srv/projetos/clientes/fala42`  
**SSH:** `fiadopro-vps`  
**Atualizado:** 14/11/2026

Este stack é **isolado**: Supabase próprio + containers `deskcommcrm-*`.  
Não compartilha banco com Fiado Pro / Planejar / outros.

## Ligar

```bash
cd /srv/projetos/clientes/fala42

# Supabase mínimo
(cd .runtime/supabase && docker compose --env-file .env \
  -f docker-compose.yml -f docker-compose.deskcomm.yml -f docker-compose.tech42.yml \
  up -d db auth rest realtime imgproxy storage api-gw)

# CRM
docker compose --env-file .env \
  -f docker-compose.prod.yml -f docker-compose.single-server.yml -f docker-compose.tech42.yml \
  up -d redis srh waha app worker scheduler
```

Ou: `bash tech42/install-tech42.sh` (idempotente; não reinstala Supabase se `.runtime/supabase/.env` já existe).

## Desligar rápido (só DeskcommCRM)

```bash
bash /srv/projetos/clientes/fala42/tech42/rollback-tech42.sh
```

Equivale a `compose down` **somente** deste projeto + rede `deskcommcrm_supabase`.  
**Não** toca Fiado Pro, jc-caddy nem outros stacks. Pasta e volumes ficam no disco.

## Atualizar (imagens)

```bash
cd /srv/projetos/clientes/fala42
docker compose --env-file .env \
  -f docker-compose.prod.yml -f docker-compose.single-server.yml -f docker-compose.tech42.yml \
  pull app worker scheduler
docker compose --env-file .env \
  -f docker-compose.prod.yml -f docker-compose.single-server.yml -f docker-compose.tech42.yml \
  up -d --no-deps app worker scheduler
```

## Backup de segredos

| Onde | Caminho |
|------|---------|
| VPS | `/srv/projetos/clientes/fala42/.env` (600) |
| VPS | `/srv/projetos/clientes/fala42/.runtime/admin-credentials` (600) |
| VPS | `/srv/projetos/clientes/fala42/.runtime/supabase/.env` (600) |
| Mac | `~/Backups-Locais/deskcommcrm/privado/` (pasta 700, arquivos 600) |

**Nunca** imprimir senhas/tokens. Admin: e-mail em `OWNER_EMAIL` no arquivo de credenciais.

## Caddy

Blocos em `/srv/infraestrutura/caddy/Caddyfile` (paralelos):  
- `fala42.tech42.com.br` (público) → app `127.0.0.1:10028` + supabase paths → `127.0.0.1:10050`  
- `deskcomm.jcplanejamento.com.br` (legado, mantido) → mesmos upstreams  
WAHA global `/api/v1/webhooks/waha` → 403 em ambos.  
Studio **não** exposto. Alterar só com backup → `caddy validate` → `docker exec jc-caddy caddy reload` (nunca restart).

## Limites de memória (MiB) — overlays Tech42

| Serviço | Limite |
|---------|--------|
| app | 384 |
| worker | 240 |
| scheduler | 96 |
| waha | 240 |
| redis | 48 |
| srh | 64 |
| db | 384 |
| api-gw | 96 |
| auth | 96 |
| rest | 80 |
| realtime | 160 |
| storage | 120 |
| imgproxy | 48 |
| **Soma limites** | **~2056 MiB** |

Desligados de propósito: studio, functions, meta, pooler, Caddy do Deskcomm, voice-agent.

## Remover de vez

1. `bash tech42/rollback-tech42.sh`
2. Apagar pasta `/srv/projetos/clientes/fala42` (manual)
3. Remover bloco Caddy + validate + reload
4. Apagar backup local no Mac se não precisar mais

## WhatsApp (próximos passos — NÃO conectar ainda)

1. Abrir o painel DeskcommCRM com o admin
2. Configurar sessão WAHA / canal WhatsApp pelo fluxo do produto
3. Liberar webhook só quando Jorge autorizar (hoje `/api/v1/webhooks/waha` responde 403 no Caddy)
4. Não ligar Meta Cloud API neste teste sem decisão explícita

## Auditoria de segurança Supabase (14/11/2026)

Ver `LOG_057` em `/srv/infraestrutura/documentacao/logs/`.

## Seed de dados TESTE (LOG_058 — 14/11/2026)

População via **API oficial** (OWNER), sem alterar código do DeskcommCRM. Detalhes: `tech42/LOG_058-seed-dados-teste.md` e série `/srv/infraestrutura/documentacao/logs/LOG_058_DESKCOMMCRM_SEED_DADOS_TESTE_20261114.md`.

| Item | Conteúdo |
|------|----------|
| Organização | TECH 42 / Tech 42 LTDA · CNPJ 66.499.920/0001-04 · fuso America/Sao_Paulo · pt-BR · BRL |
| Admin | Jorge Cavalcante (CEO) — senha não alterada |
| Produtos | Método Planejar, Fiado Pro, AgroCredit, GIC, Ryro Tech, Site institucional (`preco_cents=0`) |
| Funil | Funil SaaS B2B: Novo lead → Qualificação → Demonstração → Proposta → Negociação → Ganho/Perdido |
| Etiquetas | teste, saas, lead frio, lead quente, follow-up |
| Templates | Saudação, Horário de atendimento, Envio de proposta |
| Contatos | 5 fictícios TESTE (+55 62 90000-0001…0005) |
| Equipe | Só usuários já existentes; signup fechado (`DISABLE_SIGNUP=true`) |

**Lacunas:** endereço sede; logo (API não aceita SVG); módulo B2B `/companies` off; outros e-mails de equipe não documentados.

**Não feito nesta missão:** conectar WhatsApp/WAHA/Meta; abrir portas; alterar Fiado Pro / outros stacks.
