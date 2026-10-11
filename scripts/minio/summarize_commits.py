#!/usr/bin/env python3
"""Resume commits do _delta_log: operacao, modo, arquivos adicionados/removidos.

Recebe no stdin varios commits concatenados, separados por linhas
`---COMMIT <arquivo>---` (formato produzido por delta_commit_audit.sh).
"""
from __future__ import annotations

import json
import sys
from collections import Counter


def human(size: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB"):
        if abs(size) < 1024.0:
            return f"{size:.1f}{unit}"
        size /= 1024.0
    return f"{size:.1f}TiB"


def parse_commit(lines: list[str]) -> dict:
    info: dict = {"add": 0, "remove": 0, "add_bytes": 0, "remove_bytes": 0}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            action = json.loads(line)
        except json.JSONDecodeError:
            continue

        if "commitInfo" in action:
            ci = action["commitInfo"]
            params = ci.get("operationParameters", {})
            info["operation"] = ci.get("operation")
            info["mode"] = params.get("mode") or params.get("predicate")
            info["partitionBy"] = params.get("partitionBy")
            info["timestamp"] = ci.get("timestamp")
            info["engine"] = ci.get("engineInfo")
            metrics = ci.get("operationMetrics", {})
            info["metrics"] = metrics
        elif "add" in action:
            info["add"] += 1
            info["add_bytes"] += int(action["add"].get("size") or 0)
        elif "remove" in action:
            info["remove"] += 1
            info["remove_bytes"] += int(action["remove"].get("size") or 0)
    return info


def main() -> None:
    commits: list[tuple[str, dict]] = []
    current_name = ""
    buffer: list[str] = []

    for line in sys.stdin:
        if line.startswith("---COMMIT "):
            if current_name:
                commits.append((current_name, parse_commit(buffer)))
            current_name = line.strip().removeprefix("---COMMIT ").removesuffix("---")
            buffer = []
        else:
            buffer.append(line)
    if current_name:
        commits.append((current_name, parse_commit(buffer)))

    print(f"{'versao':<26} {'operacao':<16} {'modo':<12} {'add':>5} {'rm':>5} {'add_sz':>9} {'rm_sz':>9}")
    print("-" * 92)
    for name, info in commits:
        print(
            f"{name:<26} {str(info.get('operation'))[:16]:<16} {str(info.get('mode'))[:12]:<12} "
            f"{info['add']:>5} {info['remove']:>5} "
            f"{human(info['add_bytes']):>9} {human(info['remove_bytes']):>9}"
        )

    print("\n--- resumo ---")
    ops = Counter(str(i.get("operation")) for _, i in commits)
    modes = Counter(str(i.get("mode")) for _, i in commits)
    print(f"operacoes : {dict(ops)}")
    print(f"modos     : {dict(modes)}")
    print(f"add total : {sum(i['add'] for _, i in commits)} arquivos, "
          f"{human(sum(i['add_bytes'] for _, i in commits))}")
    print(f"rm total  : {sum(i['remove'] for _, i in commits)} arquivos, "
          f"{human(sum(i['remove_bytes'] for _, i in commits))}")

    engines = {str(i.get("engine")) for _, i in commits if i.get("engine")}
    if engines:
        print(f"engine    : {', '.join(engines)}")

    partition = {str(i.get("partitionBy")) for _, i in commits if i.get("partitionBy")}
    if partition:
        print(f"partitionBy: {', '.join(partition)}")

    stamps = sorted(i["timestamp"] for _, i in commits if i.get("timestamp"))
    if len(stamps) > 1:
        deltas = [(b - a) / 1000.0 for a, b in zip(stamps, stamps[1:])]
        print(f"intervalo entre commits: min={min(deltas):.0f}s "
              f"medio={sum(deltas) / len(deltas):.0f}s max={max(deltas):.0f}s")


if __name__ == "__main__":
    main()
