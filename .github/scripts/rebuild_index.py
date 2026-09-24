#!/usr/bin/env python3
"""Regenerate the store's root index.json from every face's metadata.json.

Each publish writes `faces/<publisher>/<slug>/metadata.json` (a StoreFace JSON
record authored by Mirante). This script scans all of them and emits a
StoreManifest at the repo root:
  {
    "schemaVersion": 1,
    "generatedAt": "<iso-8601>",
    "publisher": null,
    "faces": [ ...storeFace records... ]
  }

It also patches each record's `compiled` flag to true when a valid face.bin is
present next to the .fprj, so the app hides the "Compiling" badge once the
Windows toolchain produced a binary.
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FACES = ROOT / "faces"
INDEX = ROOT / "index.json"

SCHEMA_VERSION = 1


def infer_compiled(face_dir: Path) -> bool:
    return (face_dir / "face.bin").exists()


def collect() -> list[dict]:
    faces: list[dict] = []
    for face_dir in sorted(p for p in FACES.glob("*/*") if p.is_dir()):
        metadata = face_dir / "metadata.json"
        if not metadata.is_file():
            print(f"skip {face_dir}: no metadata.json", file=sys.stderr)
            continue
        try:
            record = json.loads(metadata.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            print(f"skip {face_dir}: invalid metadata.json ({exc})", file=sys.stderr)
            continue
        record["compiled"] = infer_compiled(face_dir)
        faces.append(record)
    return faces


def main() -> int:
    faces = collect()
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "publisher": None,
        "faces": faces,
    }
    INDEX.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {INDEX} with {len(faces)} face(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())