#!/usr/bin/env python3
"""Lista e baixa objetos de um bucket S3/MinIO. Credenciais só via ambiente."""
from __future__ import annotations

import os
import sys
from pathlib import Path

import boto3
from botocore.client import Config
from botocore.exceptions import ClientError


def env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        print(f"Defina a variável de ambiente {name}.", file=sys.stderr)
        sys.exit(1)
    return value


def main() -> None:
    endpoint = env("S3_ENDPOINT")
    access_key = env("S3_ACCESS_KEY")
    secret_key = env("S3_SECRET_KEY")
    bucket = os.environ.get("S3_BUCKET", "silver").strip() or "silver"
    prefix = os.environ.get("S3_PREFIX", "").strip()
    destino = Path(os.environ.get("S3_DESTINO", "./saida-s3"))

    if prefix and not prefix.endswith("/"):
        prefix += "/"

    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        config=Config(signature_version="s3v4"),
    )

    print(f"Bucket={bucket} prefixo={prefix}")
    destino.mkdir(parents=True, exist_ok=True)

    paginator = s3.get_paginator("list_objects_v2")
    encontrados = 0
    try:
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
            for obj in page.get("Contents") or []:
                key = obj["Key"]
                if key.endswith("/"):
                    continue
                encontrados += 1
                local = destino / key.replace("/", os.sep)
                local.parent.mkdir(parents=True, exist_ok=True)
                print(f"baixando {key}")
                s3.download_file(bucket, key, str(local))
    except ClientError as exc:
        print(f"Falha ao acessar o bucket: {exc}", file=sys.stderr)
        sys.exit(1)

    print(f"Objetos baixados: {encontrados}")
    if encontrados == 0:
        print("Nenhum objeto nesse prefixo (ou sem permissão de listagem).")


if __name__ == "__main__":
    main()
