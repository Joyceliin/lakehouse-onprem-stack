#!/usr/bin/env python3
"""VACUUM de tabela Delta no MinIO via delta-rs (deltalake).

Usa o snapshot oficial (checkpoint + commits posteriores) para listar arquivos
vivos — nao reconstroi o estado so a partir dos JSON do _delta_log.

Requisito no host: pip install deltalake

ATENCAO: rode com a ingestao parada.

Dry-run (padrao):
    MINIO_ENDPOINT=http://<minio-host>:9000 \
      python3 scripts/minio/delta_vacuum_mc.py bronze/projeto_a/tb_amostra \
        --retention-hours 24

Aplicar:
    MINIO_ENDPOINT=http://<minio-host>:9000 \
      python3 scripts/minio/delta_vacuum_mc.py bronze/projeto_a/tb_amostra \
        --retention-hours 24 --apply
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SECRETS_DIR = Path(os.environ.get("LAKEHOUSE_SECRETS_DIR", ROOT / ".env_secrets"))
MINIO_ENDPOINT = os.environ.get("MINIO_ENDPOINT", "http://127.0.0.1:9000")


def read_secret(name: str) -> str:
    path = SECRETS_DIR / name
    if not path.is_file():
        sys.exit(f"Secret ausente ou ilegivel: {path}")
    return path.read_text(encoding="utf-8").strip()


def storage_options() -> dict[str, str]:
    return {
        "AWS_ACCESS_KEY_ID": read_secret("minio_root_user"),
        "AWS_SECRET_ACCESS_KEY": read_secret("minio_root_password"),
        "AWS_ENDPOINT_URL": MINIO_ENDPOINT,
        "AWS_ALLOW_HTTP": "true",
        "AWS_S3_ALLOW_UNSAFE_RENAME": "true",
        "AWS_REGION": os.environ.get("AWS_REGION", "us-east-1"),
    }


def open_table(table: str):
    try:
        from deltalake import DeltaTable
    except ImportError:
        sys.exit(
            "Pacote deltalake ausente. Instale no host:\n"
            "  pip install 'deltalake>=0.17'"
        )
    uri = f"s3://{table}"
    return DeltaTable(uri, storage_options=storage_options())


def human(size: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(size) < 1024.0:
            return f"{size:.1f}{unit}"
        size /= 1024.0
    return f"{size:.1f}PiB"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="VACUUM Delta via delta-rs (respeita checkpoint)."
    )
    parser.add_argument("table", help="ex: bronze/projeto_a/tb_amostra")
    parser.add_argument("--retention-hours", type=int, default=72)
    parser.add_argument("--apply", action="store_true", help="apaga de fato")
    parser.add_argument(
        "--force",
        action="store_true",
        help="ignorado (mantido por compatibilidade; vacuum usa snapshot oficial)",
    )
    args = parser.parse_args()

    table = args.table.strip("/")
    print(f"tabela={table} retencao={args.retention_hours}h apply={args.apply}")
    if args.force:
        print("aviso: --force ignorado (nao e mais necessario)", file=sys.stderr)

    dt = open_table(table)
    live = dt.files()
    print(f"versao={dt.version()} arquivos vivos={len(live)} (snapshot delta-rs)")

    # dry_run=True: lista candidatos sem apagar; enforce=False permite <168h.
    candidates = dt.vacuum(
        retention_hours=args.retention_hours,
        dry_run=True,
        enforce_retention_duration=False,
    )
    print(f"orfaos fora da retencao={len(candidates)}")
    if candidates:
        preview = candidates[:20]
        for path in preview:
            print(f"  {path}")
        if len(candidates) > 20:
            print(f"  ... +{len(candidates) - 20} arquivos")

    listing_path = Path(f"/tmp/orphans_{table.replace('/', '_')}.txt")
    listing_path.write_text("".join(f"{p}\n" for p in candidates), encoding="utf-8")
    print(f"lista completa em {listing_path}")

    if not candidates:
        print("nada a remover.")
        return

    if not args.apply:
        print("\ndry-run — nada foi apagado. Repita com --apply para remover.")
        return

    print("removendo via delta-rs vacuum...")
    removed = dt.vacuum(
        retention_hours=args.retention_hours,
        dry_run=False,
        enforce_retention_duration=False,
    )
    print(f"removidos={len(removed)}")
    print("concluido. Rode purge-deleted-versions.sh para liberar espaco no MinIO versionado.")


if __name__ == "__main__":
    main()
