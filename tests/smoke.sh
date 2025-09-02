#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."  # repo root

cd scrnaseq
source ~/.env
source ENV
cd scrnaseq

echo "[smoke] scrnaseq preview..."
just preview > /tmp/scrnaseq_preview.log 2>&1 || {
  echo "[smoke] FAIL: see /tmp/scrnaseq_preview.log" >&2
  exit 1
}

echo "[smoke] OK"

