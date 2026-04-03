#!/usr/bin/env bash
# ots-stamp.sh — Submit a Nostr event ID to OpenTimestamps
# Usage: ots-stamp.sh <event_id>

source "$(dirname "$0")/naan-common.sh"

export PATH="$HOME/go/bin:$PATH"

EVENT_ID="${1:?Usage: ots-stamp.sh <event_id>}"

mkdir -p "$OTS_DIR"

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
