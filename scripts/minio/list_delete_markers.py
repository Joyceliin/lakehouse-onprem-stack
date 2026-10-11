#!/usr/bin/env python3
"""Lê `mc ls --versions --json` no stdin e emite paths cujo HEAD é delete marker."""
from __future__ import annotations

import json
import sys
from collections import defaultdict


def main() -> None:
    prefix = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else ""
    objs: dict[str, list[dict]] = defaultdict(list)
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
            objs[key].append(rec)

    deleted: list[str] = []
    for key, versions in objs.items():
        versions.sort(key=lambda v: v.get("lastModified", ""), reverse=True)
        latest = versions[0]
        if latest.get("isDeleteMarker") or latest.get("deleteMarker"):
            deleted.append(key.rstrip("/"))

    print(f"objetos_unicos={len(objs)} delete_markers={len(deleted)}", file=sys.stderr)
    for key in deleted:
        if prefix:
            print(f"{prefix}/{key}")
        else:
            print(key)


if __name__ == "__main__":
    main()
