#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"
sudo lb clean || true
sudo lb config
sudo lb build
echo "ISO built (if successful): $(pwd)/live-image-amd64.hybrid.iso"
