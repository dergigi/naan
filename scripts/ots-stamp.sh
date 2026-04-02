#!/usr/bin/env bash
# ots-stamp.sh — Submit a Nostr event ID to OpenTimestamps
# Usage: ots-stamp.sh <event_id>
#
# Creates a pending .ots file in the OTS_DIR.
# The event ID (which is a SHA-256 hash) is stamped directly.
#
# Requires: ots (github.com/fiatjaf/ots)

set -euo pipefail

export PATH="$HOME/go/bin:$PATH"

OTS_DIR="${OTS_DIR:-/data/.openclaw/agents/naan/workspace/archives/ots}"
EVENT_ID="${1:?Usage: ots-stamp.sh <event_id>}"

mkdir -p "$OTS_DIR"

# Check if already stamped
if [ -f "${OTS_DIR}/${EVENT_ID}.ots" ]; then
  echo "Already stamped: ${EVENT_ID}.ots"
  exit 0
fi

cd "$OTS_DIR"
ots stamp --hash "$EVENT_ID" 2>&1

if [ -f "${OTS_DIR}/${EVENT_ID}.ots" ]; then
  echo "Pending OTS proof saved: ${OTS_DIR}/${EVENT_ID}.ots"
else
  echo "ERROR: Failed to create OTS stamp" >&2
  exit 1
fi
