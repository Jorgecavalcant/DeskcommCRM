# LOG_058 — Seed DeskcommCRM TESTE (dados documentados)

**Data:** 2026-11-14  
**Autor:** diretor-tecnologia (CTO) — missão autorizada pelo CEO  
**Ambiente:** https://deskcomm.jcplanejamento.com.br  
**Pasta:** `/srv/projetos/clientes/fala42`  
**Escopo:** popular tenant de TESTE via API oficial (SQL só para verificação). **Sem** alteração de código DeskcommCRM.

## Resumo

Seed idempotente da organização Tech 42, catálogo de produtos, funil SaaS B2B, etiquetas via contatos fictícios, respostas rápidas e perfil do admin OWNER. Signup público permanece fechado. WhatsApp/WAHA/Meta **não** conectados.

## A) Cadastrado

### 1) Organização (tenant `organizations`)
- Via: `PATCH /api/v1/admin/tenants/{id}`
- `display_name`: TECH 42  
- `legal_name`: Tech 42 LTDA  
- `cnpj`: 66.499.920/0001-04  
- `timezone`: America/Sao_Paulo · `locale`: pt-BR · `currency`: BRL · `country`: BR  
- Endereço sede: **LACUNA** (não inventado)  
- Logo: **LACUNA** — `POST /api/v1/marca/logo` recusa SVG (exige PNG/JPG); `mark.svg` não enviado  
- API B2B `/api/v1/companies`: **404** (módulo B2B desligado) — cadastro ficou no tenant, não em `companies`

### 2) Admin
- E-mail: jorgecavalcanteprofissional@gmail.com  
- `full_name`: Jorge Cavalcante · `job_title`: CEO (user_metadata via GoTrue `/auth/v1/user`)  
- Senha: **não alterada**

### 3) Produtos (`POST /api/v1/products`) — `preco_cents=0` (sem preço prometido)
| Código | Nome |
|--------|------|
| MPLAN | Método Planejar |
| FIADO | Fiado Pro |
| AGRO | AgroCredit |
| GIC | GIC — Gestão Inteligente Clínica |
| RYRO | Ryro Tech |
| SITE | Site institucional tech42.com.br |

### 4) Funil + etiquetas
- Pipeline: **Funil SaaS B2B** (`POST /api/v1/pipelines` + stages)  
- Etapas: Novo lead → Qualificação → Demonstração → Proposta → Negociação → Ganho / Perdido  
- Funil default **Pedidos** preservado  
- Etiquetas (nos contatos): teste, saas, lead frio, lead quente, follow-up  

### 5) Respostas rápidas (`POST /api/v1/message-templates`, shared)
- Saudação (`saudacao`)  
- Horário de atendimento (`horario`)  
- Envio de proposta (`proposta`) — sem prometer preço  

### 6) Contatos fictícios TESTE (5)
- Ana Teste Silva · +55 62 90000-0001  
- Bruno Fictício Souza · +55 62 90000-0002  
- Carla Demo Oliveira · +55 62 90000-0003  
- Diego Simulado Costa · +55 62 90000-0004  
- Elena Mock Ferreira · +55 62 90000-0005  
- Marcados com tag `teste` + custom_fields `origem_seed=LOG_058`  

### 7) Equipe
- Jorge Cavalcante (CEO) — admin documentado  
- Segundo admin bootstrap do instalador (`admin@deskcomm…`) **preservado**, sem troca de senha  
- Outros humanos: **LACUNA** nos docs — não inventados  

## B) Fontes
- `~/.claude/company.md`  
- `PROJETOS/metodo-planejar|fiado-pro|agrocredit|gic|ryro-tech|site-tech42/README.md`  
- CNPJ: site-tech42 (`termos.html` / `privacidade.html` / `index.html`)  
- Logo path (não uploadado): `PROJETOS/site-tech42/assets/mark.svg`  
- Credenciais locais (uso privado, não impressas): `~/Backups-Locais/deskcommcrm/privado/`  

## C) Lacunas
1. Endereço sede Tech 42  
2. Upload de logo (SVG rejeitado; falta PNG/JPG)  
3. Módulo B2B `/companies` off (404)  
4. E-mails de outros membros da equipe  

## D) Testes ANTES / DEPOIS
| Check | ANTES | DEPOIS |
|-------|-------|--------|
| fiadopro.com.br (-L) | 200 | 200 |
| fiadopro.com.br/api/health | 200 | 200 |
| tech42.com.br | 200 | 200 |
| deskcomm + /api/v1/health | 200 / healthy 1.111.0 | 200 / healthy 1.111.0 |
| RAM available | ~2588 MB | ~2515 MB (>= 2GB) |

## E) Confirmações
- `DISABLE_SIGNUP=true` (Supabase)  
- Sem conexão WAHA/Meta nesta missão  
- Sem senhas/tokens/service_role neste LOG  
- Sem alteração de RLS/auditoria  
- Sem modificação de código DeskcommCRM  

## F) Limpeza operacional
Arquivos temporários de sessão em `/tmp/deskcomm_seed_*` devem ser removidos após o seed (não versionar).
