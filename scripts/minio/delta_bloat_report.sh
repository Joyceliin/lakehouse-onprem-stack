#!/usr/bin/env bash
# scripts/minio/delta_bloat_report.sh
# Relatorio de inchaco por tabela Delta: compara arquivos vivos (checkpoint) com
# objetos fisicos no MinIO e estima o espaco recuperavel por VACUUM.
# Somente leitura — nao altera nada.
#
# Uso:
#   MINIO_ENDPOINT=https://<minio-host>:9000 \
#     bash scripts/minio/delta_bloat_report.sh bronze silver gold
#
# HTTPS (VM2): exige config/minio/certs/public.crt (CA do mc).
#
# Leitura do resultado:
#   fator alto (objetos >> vivos) => tabela reescrita em overwrite sem VACUUM
#   fator ~1                      => append saudavel
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SECRETS_DIR="${LAKEHOUSE_SECRETS_DIR:-$ROOT/.env_secrets}"
CERTS_DIR="${LAKEHOUSE_MINIO_CERTS_DIR:-$ROOT/config/minio/certs}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-https://127.0.0.1:9000}"
MC_IMAGE="${MC_IMAGE:-minio/mc}"
ALIAS_NAME="myminio"

if [ "$#" -eq 0 ]; then
  set -- bronze silver gold
fi

read_secret() {
  local path="$1"
  if [ ! -r "$path" ]; then
    echo "Secret ausente ou ilegivel: ${path}" >&2
    exit 1
  fi
  tr -d '\r\n' < "$path"
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 e obrigatorio no host (a imagem mc nao tem awk/sed)." >&2
  exit 1
fi

CERT_MOUNT=()
MC_ALIAS_SETUP="mc alias set ${ALIAS_NAME} ${MINIO_ENDPOINT} \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null"
case "${MINIO_ENDPOINT}" in
  https://*)
    if [ ! -r "${CERTS_DIR}/public.crt" ]; then
      echo "HTTPS exige CA: ${CERTS_DIR}/public.crt (rode scripts/minio/gen-tls-certs.sh)." >&2
      exit 1
    fi
    CERT_MOUNT=(-v "${CERTS_DIR}/public.crt:/certs/public.crt:ro")
    MC_ALIAS_SETUP="mkdir -p /root/.mc/certs/CAs && cp /certs/public.crt /root/.mc/certs/CAs/minio.crt && ${MC_ALIAS_SETUP}"
    ;;
esac

export MINIO_ROOT_USER
export MINIO_ROOT_PASSWORD
MINIO_ROOT_USER="$(read_secret "${SECRETS_DIR}/minio_root_user")"
MINIO_ROOT_PASSWORD="$(read_secret "${SECRETS_DIR}/minio_root_password")"

mc_sh() {
  docker run --rm --network host \
    -e MINIO_ROOT_USER \
    -e MINIO_ROOT_PASSWORD \
    "${CERT_MOUNT[@]}" \
    --entrypoint /bin/sh \
    "${MC_IMAGE}" \
    -c "${MC_ALIAS_SETUP} && $*"
}

RAW="$(mktemp)"
trap 'rm -f "${RAW}"' EXIT

for bucket in "$@"; do
  echo "varrendo ${bucket}..." >&2
  # Cada _last_checkpoint identifica a raiz de uma tabela Delta.
  checkpoints="$(mc_sh "mc find ${ALIAS_NAME}/${bucket} --name _last_checkpoint" || true)"
  [ -n "${checkpoints}" ] || continue

  while IFS= read -r cp_path; do
    [ -n "${cp_path}" ] || continue
    table="${cp_path%/_delta_log/_last_checkpoint}"

    # version = numero de commits ate o checkpoint; numOfAddFiles = arquivos vivos.
    meta="$(mc_sh "mc cat ${cp_path}" 2>/dev/null \
      | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("version", 0), d.get("numOfAddFiles", 0))
' 2>/dev/null || echo "0 0")"

    # mc du separa campos por TAB; normaliza para espaco antes de gravar o TSV.
    usage="$(mc_sh "mc du ${table}/" 2>/dev/null | tail -1 | tr '\t' ' ' || true)"
    log_usage="$(mc_sh "mc du ${table}/_delta_log/" 2>/dev/null | tail -1 | tr '\t' ' ' || true)"

    printf '%s\t%s\t%s\t%s\n' "${table#${ALIAS_NAME}/}" "${meta}" "${usage}" "${log_usage}" >> "${RAW}"
  done <<< "${checkpoints}"
done

python3 - "${RAW}" <<'PYEOF'
import sys

UNITS = {"B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3, "TiB": 1024**4}


def to_bytes(text: str) -> float:
    for unit, mult in sorted(UNITS.items(), key=lambda kv: -len(kv[0])):
        if text.endswith(unit):
            try:
                return float(text[: -len(unit)]) * mult
            except ValueError:
                return 0.0
    return 0.0


def human(size: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(size) < 1024.0:
            return f"{size:.1f}{unit}"
        size /= 1024.0
    return f"{size:.1f}PiB"


rows = []
with open(sys.argv[1]) as handle:
    for line in handle:
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 3:
            continue
        table = parts[0]
        meta = parts[1].split()
        usage = parts[2].split()
        log_usage = parts[3].split() if len(parts) > 3 else []

        version = int(meta[0]) if meta else 0
        live = int(meta[1]) if len(meta) > 1 else 0
        size = to_bytes(usage[0]) if usage else 0.0
        objects = int(usage[1]) if len(usage) > 1 else 0
        log_size = to_bytes(log_usage[0]) if log_usage else 0.0
        log_objects = int(log_usage[1]) if len(log_usage) > 1 else 0

        # Desconta o _delta_log: interessa a razao entre arquivos de dados.
        rows.append((table, version, live, objects - log_objects, size - log_size))

rows.sort(key=lambda r: (r[3] / r[2] if r[2] else 0), reverse=True)

print(f"\n{'tabela':<46} {'commits':>8} {'vivos':>7} {'objetos':>9} {'fator':>7} {'tamanho':>10} {'recuperavel~':>13}")
print("-" * 106)
for table, version, live, objects, size in rows:
    factor = objects / live if live else 0
    waste = size * (1 - live / objects) if objects else 0
    flag = "  <-- overwrite sem VACUUM" if factor >= 10 else ""
    print(f"{table[:46]:<46} {version:>8,} {live:>7,} {objects:>9,} "
          f"{factor:>7.1f} {human(size):>10} {human(waste):>13}{flag}")

total_waste = sum(s * (1 - l / o) for _, _, l, o, s in rows if o and l)
print(f"\ntotal potencialmente recuperavel: {human(total_waste)}")
PYEOF
