#!/usr/bin/env bash
# Provisiona usuário do Trino: senha (hash bcrypt) + grupo da ACL.
#
# Como o Trino autentica e autoriza (resumo):
#   Senha : arquivo user:hash   → .env_secrets/trino_password.db
#   Grupo : arquivo grupo:users → .env_secrets/trino_groups.txt
#   ACL   : config/trino/rules.json decide o que cada GRUPO enxerga.
#   O usuário não aparece em rules.json — trocar o nível é trocar o grupo.
#
# Níveis:
#   admin       tudo (DDL, register_table, kill de queries)
#   engenharia  SELECT em bronze, silver e gold
#   analista    SELECT em silver e gold — sem bronze
#
# Uso:
#   ./scripts/trino/set-user.sh <user> <nivel>            # gera a senha
#   ./scripts/trino/set-user.sh <user> <nivel> --prompt   # digita a senha
#   ./scripts/trino/set-user.sh <user> --remove
#
#   ./scripts/trino/set-user.sh usr_k4t9 admin
#   ./scripts/trino/set-user.sh usr_m2x7 engenharia
#   ./scripts/trino/set-user.sh usr_p8d3 analista
#
# Rodar de novo para o mesmo usuário rotaciona a senha e/ou troca o nível.
# A senha em claro nunca é gravada: aparece uma vez no terminal e só o hash
# vai para o arquivo.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

LEVELS="admin engenharia analista"
USER_NAME=""
LEVEL=""
PROMPT_MODE=0
REMOVE=0

usage() {
  cat >&2 <<'EOF'
Uso:
  set-user.sh <user> <nivel> [--prompt]
  set-user.sh <user> --remove

  Níveis: admin | engenharia | analista

  Exemplos:
    set-user.sh usr_k4t9 admin
    set-user.sh usr_p8d3 analista --prompt
    set-user.sh usr_p8d3 --remove
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt|-p) PROMPT_MODE=1; shift ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "Opcao desconhecida: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "$USER_NAME" ]]; then
        USER_NAME="$1"
      elif [[ -z "$LEVEL" ]]; then
        LEVEL="$1"
      else
        echo "Arg extra: $1" >&2
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

[[ -n "$USER_NAME" ]] || { usage; exit 1; }
[[ "$USER_NAME" =~ ^[a-z][a-z0-9_.-]{2,31}$ ]] || {
  echo "Usuario invalido: use 3-32 caracteres [a-z0-9_.-], começando por letra." >&2
  exit 1
}

if [[ "$REMOVE" -eq 1 ]]; then
  [[ -z "$LEVEL" && "$PROMPT_MODE" -eq 0 ]] || {
    echo "--remove não aceita nível nem --prompt." >&2
    exit 1
  }
else
  [[ -n "$LEVEL" ]] || { echo "Informe o nível." >&2; usage; exit 1; }
  case " $LEVELS " in
    *" $LEVEL "*) ;;
    *) echo "Nivel invalido: $LEVEL (use: $LEVELS)." >&2; exit 1 ;;
  esac
fi

SECRETS_DIR="${LAKEHOUSE_SECRETS_DIR:-$ROOT/.env_secrets}"
HASH_FILE="${TRINO_HASH_FILE:-$SECRETS_DIR/trino_password.db}"
GROUPS_FILE="${TRINO_GROUPS_FILE:-$SECRETS_DIR/trino_groups.txt}"
BCRYPT_COST="${TRINO_BCRYPT_COST:-10}"
HTPASSWD_IMAGE="${HTPASSWD_IMAGE:-httpd:2.4-alpine}"

TMP_FILE=""
cleanup() { [[ -n "${TMP_FILE:-}" && -f "$TMP_FILE" ]] && rm -f "$TMP_FILE"; }
trap cleanup EXIT

generate_token() {
  local n="${1:-24}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -d '/+=\n' | head -c "$n"
  elif [[ -r /dev/urandom ]]; then
    head -c 64 /dev/urandom | base64 | tr -d '/+=\n' | head -c "$n"
  else
    echo "Sem openssl." >&2
    exit 1
  fi
}

read_prompt() {
  local label="$1" p1 p2
  [[ -t 0 ]] || { echo "Precisa de TTY." >&2; exit 1; }
  read -r -s -p "${label}: " p1; echo >&2
  read -r -s -p "Confirme: " p2; echo >&2
  [[ -n "$p1" && "$p1" == "$p2" && ${#p1} -ge 16 ]] || {
    echo "Senha invalida (mínimo 16 caracteres, iguais nas duas vezes)." >&2
    exit 1
  }
  printf '%s' "$p1"
}

# Gera a linha user:hash. A senha entra por stdin — nunca como argumento, para
# não aparecer em `ps` nem no histórico do shell.
bcrypt_line() {
  local user="$1" secret="$2" line
  if command -v htpasswd >/dev/null 2>&1; then
    line="$(printf '%s\n' "$secret" | htpasswd -niBC "$BCRYPT_COST" "$user" | head -n 1)"
  elif docker info >/dev/null 2>&1; then
    line="$(printf '%s\n' "$secret" \
      | docker run --rm -i "$HTPASSWD_IMAGE" htpasswd -niBC "$BCRYPT_COST" "$user" \
      | head -n 1)"
  else
    echo "Precisa de htpasswd (apache2-utils) ou Docker para gerar o hash." >&2
    exit 1
  fi
  line="$(printf '%s' "$line" | tr -d '\r')"
  [[ "$line" == "${user}:\$2"* ]] || { echo "Falha ao gerar hash bcrypt." >&2; exit 1; }
  printf '%s' "$line"
}

# Os dois arquivos são montados no container um a um (bind de arquivo). O
# conteúdo é reescrito no MESMO arquivo: trocar por `mv` criaria outro inode e
# o Trino continuaria lendo o antigo até ser recriado.
# Permissão 644: o processo do Trino não é dono dos arquivos e precisa ler.
# O que protege é o diretório (.env_secrets 700) e o fato de só haver hashes.
replace_content() {
  local target="$1"
  [[ -f "$target" ]] || : > "$target"
  cat "$TMP_FILE" > "$target"
  chmod 644 "$target"
  rm -f "$TMP_FILE"
  TMP_FILE=""
}

# $1 = linha user:hash a gravar (vazio = só remover o usuário)
update_hash_file() {
  TMP_FILE="$(mktemp)"
  if [[ -f "$HASH_FILE" ]]; then
    awk -F: -v u="$USER_NAME" '$1 != u' "$HASH_FILE" > "$TMP_FILE"
  fi
  [[ -z "$1" ]] || printf '%s\n' "$1" >> "$TMP_FILE"
  replace_content "$HASH_FILE"
}

# $1 = grupo de destino (vazio = só remover o usuário)
# Um usuário fica em um único nível: sai de todos os grupos antes de entrar.
update_groups_file() {
  TMP_FILE="$(mktemp)"
  [[ -f "$GROUPS_FILE" ]] || : > "$GROUPS_FILE"
  awk -F: -v u="$USER_NAME" -v target="$1" -v levels="$LEVELS" '
    BEGIN {
      n = split(levels, order, " ")
      for (i = 1; i <= n; i++) known[order[i]] = 1
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      g = $1
      gsub(/[[:space:]]/, "", g)
      if (!(g in seen)) {
        seen[g] = 1
        if (!(g in known)) extra[++m] = g
      }
      k = split($2, parts, ",")
      for (i = 1; i <= k; i++) {
        p = parts[i]
        gsub(/[[:space:]]/, "", p)
        if (p != "" && p != u) members[g] = (members[g] == "" ? p : members[g] "," p)
      }
    }
    END {
      if (target != "") members[target] = (members[target] == "" ? u : members[target] "," u)
      for (i = 1; i <= n; i++) print order[i] ":" members[order[i]]
      for (i = 1; i <= m; i++) print extra[i] ":" members[extra[i]]
    }
  ' "$GROUPS_FILE" > "$TMP_FILE"
  replace_content "$GROUPS_FILE"
}

warn_if_no_admin() {
  if grep -q '^admin:$' "$GROUPS_FILE"; then
    echo "AVISO: o grupo admin ficou vazio — ninguém consegue administrar o Trino." >&2
  fi
}

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR" 2>/dev/null || true

# --- remoção ---
if [[ "$REMOVE" -eq 1 ]]; then
  update_hash_file ""
  update_groups_file ""
  echo "OK — usuario removido: ${USER_NAME}" >&2
  warn_if_no_admin
  exit 0
fi

# --- criação / rotação ---
FIRST_RUN=0
[[ -f "$HASH_FILE" && -f "$GROUPS_FILE" ]] || FIRST_RUN=1

SHOW_ONCE=0
if [[ "$PROMPT_MODE" -eq 1 ]]; then
  SECRET="$(read_prompt "Senha (${USER_NAME})")"
else
  SECRET="$(generate_token 24)"
  SHOW_ONCE=1
fi

HASH_LINE="$(bcrypt_line "$USER_NAME" "$SECRET")"
update_hash_file "$HASH_LINE"
update_groups_file "$LEVEL"
unset HASH_LINE

echo "OK — trino: user=${USER_NAME} grupo=${LEVEL}" >&2
warn_if_no_admin

if [[ "$SHOW_ONCE" -eq 1 ]]; then
  echo "" >&2
  echo ">>> SENHA (copie agora — não fica gravada em lugar nenhum) <<<" >&2
  echo "user=${USER_NAME}" >&2
  printf 'senha=%s\n' "$SECRET"
  echo ">>> fim <<<" >&2
fi
unset SECRET

if [[ "$FIRST_RUN" -eq 1 ]]; then
  echo "Arquivos criados agora — recrie o Trino para montá-los:" >&2
  echo "  docker compose -f docker-compose.lakehouse-vm2.yml up -d --force-recreate trino" >&2
else
  echo "O Trino relê senha e grupos sozinho em alguns segundos (sem restart)." >&2
fi
