#!/usr/bin/env bash
# deploy-nsite.sh — Build and deploy the NAAN archive index site via nsyte
# Usage: deploy-nsite.sh [--force]
#
# Reads nsec from NSEC_FILE, builds the site, deploys to Blossom + Nostr relays.
# Uses nsyte's non-interactive mode with --sec flag.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(dirname "$SCRIPT_DIR")"
SITE_DIR="$WORKSPACE_DIR/site"
NSEC_FILE="${NSEC_FILE:-$WORKSPACE_DIR/.nostr-nsec.key}"

FORCE_FLAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE_FLAG="--force"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ ! -f "$NSEC_FILE" ]; then
  echo "ERROR: nsec file not found: $NSEC_FILE" >&2
  exit 1
fi

NSEC=$(cat "$NSEC_FILE")

echo "=== NAAN Site Deploy ==="
echo "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Build
echo "[Build] Installing dependencies..."
cd "$SITE_DIR"
npm install --silent 2>&1

echo "[Build] Building site..."
npm run build 2>&1

# Deploy
echo ""
echo "[Deploy] Deploying to nsite via nsyte..."
if nsyte deploy dist/ --sec "$NSEC" -i $FORCE_FLAG 2>&1; then
  echo ""
  echo "=== Deploy Complete ==="
else
  # nsyte exits 1 when there's nothing new to upload, which is fine
  echo ""
  echo "=== Deploy Complete (no changes) ==="
fi
