#!/usr/bin/env bash
# deploy-nsite.sh — Build and deploy the NAAN archive index as an nsite
# Usage: deploy-nsite.sh [--update]
#
# Clones the NAAN repo (or pulls latest if --update), builds the site,
# and deploys it as an nsite using the node's nsec.
#
# Requires: git, node, npm, nsyte, nak
# Reads: naan.conf (for NSEC_FILE, RELAYS, BLOSSOM_SERVERS)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/naan-common.sh"

NAAN_REPO="https://github.com/dergigi/naan.git"
SITE_DIR="${NAAN_WORKSPACE:-$(pwd)}/naan-site"
UPDATE_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update) UPDATE_ONLY=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "=== NAAN Site Deploy ==="
echo "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Clone or update the repo
if [ -d "$SITE_DIR/.git" ]; then
  echo "[Site] Pulling latest from dergigi/naan..."
  cd "$SITE_DIR"
  git pull origin main 2>&1
else
  echo "[Site] Cloning dergigi/naan..."
  git clone --depth 1 "$NAAN_REPO" "$SITE_DIR" 2>&1
  cd "$SITE_DIR"
fi

# Build the site
echo ""
echo "[Site] Installing dependencies..."
cd "$SITE_DIR/site"
npm install 2>&1

echo ""
echo "[Site] Building..."
npm run build 2>&1

# Read nsec
if [ ! -f "$NSEC_FILE" ]; then
  echo "ERROR: NSEC_FILE not found: $NSEC_FILE" >&2
  exit 1
fi
NSEC=$(cat "$NSEC_FILE")

# Build relay and server args
RELAY_ARGS=""
if [ ${#RELAYS_ARRAY[@]} -gt 0 ]; then
  RELAY_ARGS=$(printf '%s,' "${RELAYS_ARRAY[@]}")
  RELAY_ARGS="${RELAY_ARGS%,}"
fi

SERVER_ARGS=""
if [ ${#BLOSSOM_SERVERS_ARRAY[@]} -gt 0 ]; then
  SERVER_ARGS=$(printf '%s,' "${BLOSSOM_SERVERS_ARRAY[@]}")
  SERVER_ARGS="${SERVER_ARGS%,}"
fi

# Deploy
echo ""
echo "[Site] Deploying nsite..."
DEPLOY_CMD="nsyte deploy dist --sec $NSEC --non-interactive"
[ -n "$RELAY_ARGS" ] && DEPLOY_CMD="$DEPLOY_CMD --relays $RELAY_ARGS"
[ -n "$SERVER_ARGS" ] && DEPLOY_CMD="$DEPLOY_CMD --servers $SERVER_ARGS"

eval "$DEPLOY_CMD" 2>&1

# Get the npub for display
PUBKEY=$(nak event --sec "$NSEC" -k 0 -c "" 2>/dev/null | jq -r '.pubkey' 2>/dev/null || echo "unknown")
NPUB=$(nak encode npub "$PUBKEY" 2>/dev/null || echo "unknown")

echo ""
echo "=== Deploy Complete ==="
echo "Your archive index is live at:"
echo "  https://${NPUB}.nsite.lol/"
echo ""
echo "Run with --update to pull the latest site and redeploy."
