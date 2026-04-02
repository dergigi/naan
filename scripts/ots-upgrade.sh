#!/usr/bin/env bash
# ots-upgrade.sh — Upgrade pending OTS proofs and publish kind 1040 events
# Usage: ots-upgrade.sh [--publish]
#
# Scans OTS_DIR for pending .ots files, attempts to upgrade them.
# With --publish, publishes kind 1040 events for upgraded proofs.
#
# Requires: ots, nak
# Env: NSEC_FILE (path to nsec key)

set -euo pipefail

export PATH="$HOME/go/bin:$PATH"

OTS_DIR="${OTS_DIR:-/data/.openclaw/agents/naan/workspace/archives/ots}"
NSEC_FILE="${NSEC_FILE:-/data/.openclaw/agents/naan/workspace/.nostr-nsec.key}"
RELAYS=("wss://relay.damus.io" "wss://relay.primal.net" "wss://nos.lol")
PUBLISH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --publish) PUBLISH=true; shift ;;
    *) shift ;;
  esac
done

if [ ! -d "$OTS_DIR" ]; then
  echo "No OTS directory found: $OTS_DIR"
  exit 0
fi

UPGRADED=0
PENDING=0
PUBLISHED=0

for OTS_FILE in "$OTS_DIR"/*.ots; do
  [ -f "$OTS_FILE" ] || continue

  EVENT_ID=$(basename "$OTS_FILE" .ots)
  DONE_FILE="${OTS_DIR}/${EVENT_ID}.done"

  # Skip already published
  if [ -f "$DONE_FILE" ]; then
    continue
  fi

  # Check if still pending
  INFO=$(ots info "$OTS_FILE" 2>&1)
  if echo "$INFO" | grep -q "pending"; then
    echo "Upgrading: $EVENT_ID"
    ots upgrade "$OTS_FILE" 2>&1 || true

    # Re-check after upgrade
    INFO=$(ots info "$OTS_FILE" 2>&1)
    if echo "$INFO" | grep -q "pending"; then
      echo "  Still pending"
      PENDING=$((PENDING + 1))
      continue
    fi
  fi

  # If we get here, the proof has a Bitcoin attestation
  echo "  Upgraded! Bitcoin attestation found."
  UPGRADED=$((UPGRADED + 1))

  # Verify the proof
  if ots verify "$OTS_FILE" 2>&1 | grep -q "success"; then
    echo "  Verified against Bitcoin blockchain."
  fi

  if [ "$PUBLISH" = true ]; then
    # Read the .ots file content as base64 for the kind 1040 event
    OTS_CONTENT=$(base64 -w0 "$OTS_FILE")
    NSEC=$(cat "$NSEC_FILE")

    echo "  Publishing kind 1040..."
    nak event \
      --sec "$NSEC" \
      -k 1040 \
      -t "e=$EVENT_ID" \
      -c "$OTS_CONTENT" \
      "${RELAYS[@]}" 2>&1

    # Mark as published
    echo "published=$(date +%s)" > "$DONE_FILE"
    PUBLISHED=$((PUBLISHED + 1))
    echo "  Published kind 1040 for event $EVENT_ID"
  fi
done

echo ""
echo "=== OTS Upgrade Summary ==="
echo "Upgraded:  $UPGRADED"
echo "Pending:   $PENDING"
echo "Published: $PUBLISHED"
