#!/usr/bin/env bash
set -euo pipefail

ROOT="/data/robot-dh/datasets/raw"
OUT="/data/robot-dh/datasets/manifests/raw_dataset_summary.txt"

mkdir -p "$(dirname -- "$OUT")"

{
  echo "Generated at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Disk:"
  df -h /data/robot-dh
  echo
  echo "Dataset sizes:"
  du -sh "$ROOT"/* 2>/dev/null || true
  echo
  echo "File counts by dataset root:"
  find "$ROOT" -type f | awk -v root="$ROOT/" '
    {
      path = $0
      sub("^" root, "", path)
      split(path, parts, "/")
      if (parts[1] != "") {
        counts[parts[1]]++
      }
    }
    END {
      for (name in counts) {
        print counts[name], name
      }
    }
  ' | sort -k2
  echo
  echo "Top large files:"
  find "$ROOT" -type f -printf '%s\t%p\n' | sort -nr | head -30
} | tee "$OUT"
