#!/usr/bin/env python3
"""Lê `mc ls --recursive --versions --json` no stdin e resume o consumo de espaço.

Separa versão atual de versões antigas para mostrar onde o crescimento ocorreu:
agregação por prefixo, objetos com mais versões e distribuição temporal.

Uso (pipe a partir do container mc):
    ... | python3 scripts/minio/analyze_versions.py --depth 2 --top 20
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict


def human(size: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(size) < 1024.0:
            return f"{size:6.1f} {unit}"
        size /= 1024.0
    return f"{size:6.1f} PiB"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--depth", type=int, default=2, help="niveis de prefixo na agregacao")
    parser.add_argument("--top", type=int, default=20, help="quantos itens listar em cada ranking")
    args = parser.parse_args()

    versions_by_key: dict[str, list[dict]] = defaultdict(list)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        key = rec.get("key")
        if key:
            versions_by_key[key].append(rec)

    total_current = total_noncurrent = 0
    count_current = count_noncurrent = count_markers = 0
    by_prefix: dict[str, list[int]] = defaultdict(lambda: [0, 0, 0])  # atual, antigo, n_versoes
    by_month: dict[str, int] = defaultdict(int)
    version_counts: list[tuple[int, int, str]] = []

    for key, versions in versions_by_key.items():
        versions.sort(key=lambda v: v.get("lastModified", ""), reverse=True)
        prefix = "/".join(key.split("/")[: args.depth]) or "/"
        noncurrent_size = 0

        for pos, rec in enumerate(versions):
            size = int(rec.get("size") or 0)
            if rec.get("isDeleteMarker") or rec.get("deleteMarker"):
                count_markers += 1
                continue
            if pos == 0:
                total_current += size
                count_current += 1
                by_prefix[prefix][0] += size
            else:
                total_noncurrent += size
                count_noncurrent += 1
                noncurrent_size += size
                by_prefix[prefix][1] += size
            by_prefix[prefix][2] += 1
            by_month[str(rec.get("lastModified", ""))[:7]] += size

        version_counts.append((len(versions), noncurrent_size, key))

    print("=" * 78)
    print(f"objetos unicos      : {len(versions_by_key):>12,}")
    print(f"versoes atuais      : {count_current:>12,}  {human(total_current)}")
    print(f"versoes antigas     : {count_noncurrent:>12,}  {human(total_noncurrent)}")
    print(f"delete markers      : {count_markers:>12,}")
    print(f"total ocupado       : {'':>12}  {human(total_current + total_noncurrent)}")

    print("\n" + "=" * 78)
    print(f"POR PREFIXO (depth={args.depth}) — ordenado por total")
    print(f"{'prefixo':<44} {'atual':>10} {'antigo':>10} {'versoes':>8}")
    ranked = sorted(by_prefix.items(), key=lambda kv: kv[1][0] + kv[1][1], reverse=True)
    for prefix, (cur, old, nver) in ranked[: args.top]:
        print(f"{prefix[:44]:<44} {human(cur):>10} {human(old):>10} {nver:>8,}")

    print("\n" + "=" * 78)
    print(f"OBJETOS COM MAIS VERSOES (top {args.top})")
    version_counts.sort(reverse=True)
    for nver, old_size, key in version_counts[: args.top]:
        if nver <= 1:
            break
        print(f"{nver:>5} versoes  {human(old_size):>10} antigo  {key}")

    print("\n" + "=" * 78)
    print("VOLUME GRAVADO POR MES (lastModified de todas as versoes)")
    for month in sorted(by_month):
        if month:
            print(f"{month}  {human(by_month[month])}")


if __name__ == "__main__":
    main()
