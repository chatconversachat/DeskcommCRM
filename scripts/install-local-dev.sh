#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

cat <<'EOF'
DeskcommCRM — instalador local de desenvolvimento

Prepara um ambiente local completo (Supabase + WAHA + Redis local) pra rodar
o app com `pnpm dev`. Idempotente — pode rodar de novo a qualquer momento.

NÃO toca no kit self-host da VPS (docker-compose.prod.yml, hostgator-setup-kit/,
Caddyfile) — isso aqui é só a sua máquina de dev.

Etapas:
  1. valida Node 22, pnpm, Docker, Supabase CLI, openssl
  2. cria .env.local a partir do template (se não existir) e um .env vazio
     (o serviço `worker` do docker-compose exige que o arquivo exista)
  3. instala dependências com pnpm
  4. sobe o Supabase local em Docker (portas 64320-64329 — supabase/config.toml
     já remapeado pra não colidir com outros projetos Supabase locais) e aplica
     supabase/baseline.sql — a MESMA fonte de schema que o kit self-host usa
     (não o replay de supabase/migrations/*, que tem uma quebra histórica de
     ordenação nunca exercitada porque test:db também usa o baseline)
  5. gera (uma vez — não sobrescreve o que já está preenchido) todos os
     segredos locais que lib/env.ts espera, com a mesma receita do
     hostgator-setup-kit/install.sh (openssl rand -hex/-base64 32)
  6. sobe WAHA + worker + Redis local (fachada REST compatível Upstash) via
     docker compose
  7. imprime as URLs e o comando pra rodar `pnpm dev`
EOF

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERRO] Comando obrigatório não encontrado: $cmd"
    case "$cmd" in
      node) echo "Instale o Node.js 22 e tente novamente (nvm install 22)." ;;
      npm) echo "Instale o npm junto com o Node.js 22." ;;
      docker) echo "Instale o Docker Desktop ou Docker Engine." ;;
      openssl) echo "Instale o openssl (usado pra gerar os segredos locais)." ;;
    esac
    exit 1
  fi
}

# Node 22 via nvm, se disponível — o projeto exige (.nvmrc + WebSocket nativo).
if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
  # shellcheck disable=SC1090
  source "${NVM_DIR:-$HOME/.nvm}/nvm.sh"
  nvm use >/dev/null 2>&1 || { nvm install >/dev/null 2>&1 && nvm use >/dev/null 2>&1; } || true
fi

require_cmd node
require_cmd npm
require_cmd docker
require_cmd openssl

NODE_MAJOR="$(node -e 'process.stdout.write(process.versions.node.split(".")[0])')"
if [ "$NODE_MAJOR" -lt 22 ]; then
  echo "[AVISO] Node ${NODE_MAJOR} ativo — o projeto pede Node 22 (.nvmrc). Rode 'nvm use' antes de 'pnpm dev'."
fi

if ! command -v pnpm >/dev/null 2>&1; then
  echo "[INFO] pnpm não foi encontrado. Instalando..."
  npm install -g pnpm
fi
require_cmd pnpm

if ! command -v supabase >/dev/null 2>&1; then
  echo "[INFO] Supabase CLI não foi encontrado. Instalando..."
  npm install -g supabase
fi
require_cmd supabase

if [ ! -f .env.local ]; then
  echo "[INFO] Criando .env.local a partir de .env.example"
  cp .env.example .env.local
else
  echo "[INFO] .env.local já existe. Mantendo os valores já preenchidos."
fi
# docker compose (serviço worker) usa `env_file: [.env, .env.local]` e erra se
# o arquivo não existir — mesmo vazio, precisa existir. .env* é gitignored.
[ -f .env ] || : > .env

echo "[INFO] Instalando dependências do projeto com pnpm..."
pnpm install

# ---------------------------------------------------------------------------
# Supabase local
# ---------------------------------------------------------------------------
PROJECT_ID="$(sed -nE 's/^project_id = "(.*)"$/\1/p' supabase/config.toml)"
DB_CONTAINER="supabase_db_${PROJECT_ID}"

echo "[INFO] Subindo o Supabase local..."
if supabase status >/dev/null 2>&1; then
  echo "[INFO] Supabase local já está de pé."
else
  supabase start
fi

echo "[INFO] Conferindo se o schema (baseline.sql) já foi aplicado..."
SCHEMA_READY="$(docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc \
  "select to_regclass('public.organizations') is not null" 2>/dev/null || echo f)"

if [ "$SCHEMA_READY" != "t" ]; then
  echo "[INFO] Habilitando extensions (vector, citext, pg_trgm) — mesma receita do hostgator-setup-kit/install.sh..."
  docker exec "$DB_CONTAINER" psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c \
    "create extension if not exists vector with schema public; create extension if not exists citext with schema public; create extension if not exists pg_trgm with schema public;"
  echo "[INFO] Aplicando supabase/baseline.sql (modo install, ON_ERROR_STOP=1)..."
  docker exec -i "$DB_CONTAINER" psql -v ON_ERROR_STOP=1 -U postgres -d postgres < supabase/baseline.sql
else
  echo "[INFO] Schema já aplicado (tabela organizations existe). Pulando baseline.sql."
fi

STATUS_JSON="$(supabase status -o json)"
json_get() {
  node -e 'const d=JSON.parse(process.argv[1]); process.stdout.write(d[process.argv[2]] ?? "")' "$STATUS_JSON" "$1"
}
API_URL="$(json_get API_URL)"
ANON_KEY="$(json_get ANON_KEY)"
SERVICE_ROLE_KEY="$(json_get SERVICE_ROLE_KEY)"
DB_URL="$(json_get DB_URL)"
STUDIO_URL="$(json_get STUDIO_URL)"
INBUCKET_URL="$(json_get INBUCKET_URL)"

# ---------------------------------------------------------------------------
# .env.local — helpers de leitura/escrita idempotente
# ---------------------------------------------------------------------------
ENV_FILE=".env.local"

current_env() {
  grep -m1 "^${1}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true
}

set_env_force() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$val" 'BEGIN{FS=OFS="="} $1==k{$0=k"="v} {print}' "$ENV_FILE" > "${ENV_FILE}.tmp"
    mv "${ENV_FILE}.tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

set_env_if_empty() {
  local key="$1" val="$2"
  if [ -z "$(current_env "$key")" ]; then
    set_env_force "$key" "$val"
  fi
}

echo "[INFO] Sincronizando chaves do Supabase local em .env.local..."
set_env_force NEXT_PUBLIC_SUPABASE_URL "$API_URL"
set_env_force NEXT_PUBLIC_SUPABASE_ANON_KEY "$ANON_KEY"
set_env_force SUPABASE_SERVICE_ROLE_KEY "$SERVICE_ROLE_KEY"
set_env_force SUPABASE_DB_URL "$DB_URL"
# Variante pro container `worker`: 127.0.0.1 dentro de um container é o
# próprio container, não o host — precisa de host.docker.internal (mesma
# porta). Usada só via docker-compose.yml (environment: do serviço worker).
set_env_force SUPABASE_DB_URL_DOCKER "${DB_URL/127.0.0.1/host.docker.internal}"

echo "[INFO] Gerando segredos locais que ainda estão vazios (mesma receita do hostgator-setup-kit/install.sh)..."
gen_hex() { openssl rand -hex 32; }
gen_b64() { openssl rand -base64 32; }

set_env_if_empty INTERNAL_SECRET "$(gen_hex)"
set_env_if_empty INTERNAL_CRON_SECRET "$(gen_hex)"
set_env_if_empty NUVEMSHOP_OAUTH_ENCRYPTION_KEY "$(gen_hex)"
set_env_if_empty CPF_ENCRYPTION_KEY "$(gen_b64)"
set_env_if_empty AI_CRED_AES_KEY "$(gen_b64)"
set_env_if_empty WAHA_BYO_ENCRYPTION_KEY "$(gen_b64)"
set_env_if_empty IMPERSONATE_COOKIE_SECRET "$(gen_hex)"
set_env_if_empty LGPD_SIGNING_KEY "$(gen_hex)"
set_env_if_empty WAHA_HMAC_SECRET "$(gen_hex)"
set_env_if_empty SRH_TOKEN "$(gen_hex)"
set_env_if_empty WAHA_API_KEY "$(gen_hex)"
set_env_if_empty WAHA_WEBHOOK_BASE_URL "http://localhost:3000"

# Hash SHA512 hex da WAHA_API_KEY (plaintext) — é o que o container WAHA recebe.
WAHA_API_KEY_VAL="$(current_env WAHA_API_KEY)"
WAHA_API_KEY_SHA512="$(printf '%s' "$WAHA_API_KEY_VAL" | openssl dgst -sha512 -hex | awk '{print $NF}')"
set_env_force WAHA_API_KEY_SHA512 "$WAHA_API_KEY_SHA512"
# App roda no HOST (não no compose) — o WAHA precisa de host.docker.internal:3000.
set_env_force WAHA_HOOK_BASE_URL "http://host.docker.internal:3000"

# Upstash Redis → Redis local + serverless-redis-http (fachada REST), subidos
# pelo docker compose abaixo. Nada de conta Upstash real necessária em dev.
set_env_force UPSTASH_REDIS_REST_URL "http://127.0.0.1:64380"
set_env_force UPSTASH_REDIS_REST_TOKEN "$(current_env SRH_TOKEN)"

# ---------------------------------------------------------------------------
# WAHA + worker + Redis local
# ---------------------------------------------------------------------------
echo "[INFO] Subindo WAHA + worker + Redis local (docker compose)..."
docker compose --env-file .env.local up -d

cat <<EOF

============================================================================
Ambiente local pronto.
============================================================================

Supabase Studio:            ${STUDIO_URL}
Supabase API:                ${API_URL}
Mailpit (e-mails de teste):  ${INBUCKET_URL}
WAHA dashboard:               http://localhost:3030/dashboard/

Segredos locais e chaves do Supabase já estão em .env.local.
Ainda ficam vazios de propósito (degradam graciosamente, preencha se for
testar essas features — ver docs/SETUP.md):
  AI_GATEWAY_API_KEY / ANTHROPIC_API_KEY, OPENAI_API_KEY, SENTRY_DSN,
  NUVEMSHOP_* (a menos que NUVEMSHOP_ENABLED=true)

Próximos passos:

1. Rode o app:
   pnpm dev

2. Não existe tela de cadastro — crie o 1º usuário dono/admin com:
   OWNER_EMAIL=voce@exemplo.com OWNER_PASSWORD='senha-forte-aqui' \\
     npx tsx scripts/bootstrap-owner.ts

3. Acesse:
   http://localhost:3000
EOF
