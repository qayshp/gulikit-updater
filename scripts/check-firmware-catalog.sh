#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Explicit maintainer operation, never part of a normal build. This requests
# bounded official release metadata only: no USB, payload download, or pin changes.
# JSON records are printed even on partial failure; exit 1 flags review in CI.
exec swift run gulikit releases --refresh --json
