#!/usr/bin/env bash
# hashtree-upload.sh — Chunk a file via Hashtree, push chunks to Blossom
# Usage: hashtree-upload.sh <file> [--server <url>] [--dry-run]
#
# Returns the Hashtree root hash (CID) on the last line of output.
# Requires: htree (hashtree-cli)

set -euo pipefail

HTREE="${HTREE:-htree}"
BLOSSOM_SERVERS=("https://blossom.primal.net" "https://cdn.hzrd149.com" "https://blossom.sovereignengineering.io" "https://haven.dergigi.com")
DRY_RUN=false
FILE=""
CUSTOM_SERVERS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) CUSTOM_SERVERS+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) FILE="$1"; shift ;;
  esac
done

if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "Usage: hashtree-upload.sh <file> [--server <url>] [--dry-run]" >&2
  exit 1
fi

if ! command -v "$HTREE" &>/dev/null; then
  echo "ERROR: htree not found. Install with: cargo install hashtree-cli" >&2
  exit 1
fi

SERVERS=("${CUSTOM_SERVERS[@]:-${BLOSSOM_SERVERS[@]}}")
if [ ${#CUSTOM_SERVERS[@]} -eq 0 ]; then
  SERVERS=("${BLOSSOM_SERVERS[@]}")
fi

FILESIZE=$(stat -c%s "$FILE")
FILENAME=$(basename "$FILE")

echo "=== Hashtree Chunking ==="
echo "File: $FILENAME ($FILESIZE bytes / $(numfmt --to=iec $FILESIZE))"

# Add file to local hashtree store (unencrypted so Blossom servers can serve chunks directly)
ADD_OUTPUT=$("$HTREE" add --local --unencrypted "$FILE" 2>&1)
echo "$ADD_OUTPUT"

# Extract the hash (CID) from htree add output
HTREE_HASH=$(echo "$ADD_OUTPUT" | grep -oP 'hash:\s+\K[a-f0-9]+')

if [ -z "$HTREE_HASH" ]; then
  echo "ERROR: Failed to extract hashtree root hash" >&2
  exit 1
fi

echo ""
echo "Root hash: $HTREE_HASH"

# Get info about the tree
INFO_OUTPUT=$("$HTREE" info "$HTREE_HASH" 2>&1) || true
echo "$INFO_OUTPUT"

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "[DRY RUN] Would push chunks to: ${SERVERS[*]}"
  echo "$HTREE_HASH"
  exit 0
fi

# Push chunks to each Blossom server
echo ""
echo "Pushing chunks to Blossom servers..."
PUSH_SUCCESS=0
for SERVER in "${SERVERS[@]}"; do
  echo "  Pushing to $SERVER..."
  if "$HTREE" push --server "$SERVER" "$HTREE_HASH" 2>&1 | sed 's/^/    /'; then
    echo "  ✓ $SERVER"
    PUSH_SUCCESS=$((PUSH_SUCCESS + 1))
  else
    echo "  ✗ $SERVER: push failed" >&2
  fi
done

if [ "$PUSH_SUCCESS" -eq 0 ]; then
  echo "ERROR: Failed to push to any Blossom server" >&2
  exit 1
fi

echo ""
echo "=== Hashtree Upload Complete ==="
echo "Root:    $HTREE_HASH"
echo "Servers: $PUSH_SUCCESS/${#SERVERS[@]} successful"
echo "Viewer:  https://files.iris.to/#/$HTREE_HASH/$FILENAME"
echo ""
# Last line is the hash for scripts to capture
echo "$HTREE_HASH"
