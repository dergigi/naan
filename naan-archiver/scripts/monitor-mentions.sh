#!/usr/bin/env bash
# monitor-mentions.sh — Monitor public mentions, archive URLs, reply with results
# Usage: monitor-mentions.sh [--dry-run] [--since <unix_ts>]
#
# WoT-gated: only processes mentions from the owner or their follow list.
# Rate limited: max 3 archives per run, ignores mentions older than 10 minutes.

source "$(dirname "$0")/naan-common.sh"

STATE_DIR="$NAAN_WORKSPACE/.mention-state"
MAX_ARCHIVES_PER_RUN=3
MAX_AGE_SECONDS=600

DRY_RUN=false
SINCE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --since) SINCE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$STATE_DIR"

PROCESSED_FILE="$STATE_DIR/processed.txt"
FOLLOW_CACHE="$STATE_DIR/follows.json"
FOLLOW_CACHE_TS="$STATE_DIR/follows_ts"
touch "$PROCESSED_FILE"

# --- Fetch owner's follow list (kind 3) with caching ---
fetch_follow_list() {
  local now
  now=$(date +%s)
  local cache_age=3600

  if [ -f "$FOLLOW_CACHE" ] && [ -f "$FOLLOW_CACHE_TS" ]; then
    local cached_at
    cached_at=$(cat "$FOLLOW_CACHE_TS")
    if (( now - cached_at < cache_age )); then
      return 0
    fi
  fi

  if [ -z "$OWNER_PUBKEY" ]; then
    echo "[WoT] No OWNER_PUBKEY set, skipping follow list fetch"
    echo "[]" > "$FOLLOW_CACHE"
    return 0
  fi

  echo "[WoT] Fetching owner's follow list..."
  local follows_event=""
  for relay in "${RELAYS_ARRAY[@]}"; do
    follows_event=$(nak req -k 3 -a "$OWNER_PUBKEY" --limit 1 "$relay" 2>/dev/null | head -1 || true)
    if [ -n "$follows_event" ]; then
      break
    fi
  done

  if [ -n "$follows_event" ]; then
    echo "$follows_event" | jq -r '[.tags[] | select(.[0]=="p") | .[1]]' > "$FOLLOW_CACHE"
    echo "$now" > "$FOLLOW_CACHE_TS"
    local count
    count=$(jq 'length' "$FOLLOW_CACHE")
    echo "[WoT] Cached $count follows"
  else
    echo "[WoT] WARNING: Could not fetch follow list" >&2
    if [ ! -f "$FOLLOW_CACHE" ]; then
      echo "[]" > "$FOLLOW_CACHE"
    fi
  fi
}

is_authorized() {
  local pubkey="$1"

  # Owner is always allowed
  if [ -n "$OWNER_PUBKEY" ] && [ "$pubkey" = "$OWNER_PUBKEY" ]; then
    return 0
  fi

  # If no owner set, allow all
  if [ -z "$OWNER_PUBKEY" ]; then
    return 0
  fi

  # Check follow list
  if [ -f "$FOLLOW_CACHE" ]; then
    if jq -e --arg pk "$pubkey" 'any(. == $pk)' "$FOLLOW_CACHE" > /dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

is_processed() {
  local event_id="$1"
  grep -qF "$event_id" "$PROCESSED_FILE" 2>/dev/null
}

mark_processed() {
  local event_id="$1"
  echo "$event_id" >> "$PROCESSED_FILE"
  tail -500 "$PROCESSED_FILE" > "$PROCESSED_FILE.tmp" && mv "$PROCESSED_FILE.tmp" "$PROCESSED_FILE"
}

extract_urls() {
  local text="$1"
  echo "$text" | grep -oP 'https?://[^\s\)"'"'"'<>]+' | head -5
}

reply_to_note() {
  local original_event_id="$1"
  local original_pubkey="$2"
  local reply_text="$3"

  local nsec
  nsec=$(_read_nsec)

  local tag_args=()
  tag_args+=(-t "e=${original_event_id};;root")
  tag_args+=(-t "p=$original_pubkey")

  echo "[Reply] Publishing reply..."
  nak event \
    --sec "$nsec" \
    -k 1 \
    "${tag_args[@]}" \
    -c "$reply_text" \
    "${RELAYS_ARRAY[@]}" 2>&1
}

# --- Main ---
echo "=== NAAN Mention Monitor ==="
echo "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

fetch_follow_list

NOW=$(date +%s)
if [ -n "$SINCE" ]; then
  SINCE_TS="$SINCE"
else
  SINCE_TS=$((NOW - MAX_AGE_SECONDS))
fi

echo "[Monitor] Querying mentions since $(date -u -d @"$SINCE_TS" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "$SINCE_TS")..."

MENTIONS=""
for relay in "${RELAYS_ARRAY[@]}"; do
  NEW_MENTIONS=$(nak req -k 1 -t p="$NODE_PUBKEY" --since "$SINCE_TS" --limit 20 "$relay" 2>/dev/null || true)
  if [ -n "$NEW_MENTIONS" ]; then
    MENTIONS="$MENTIONS
$NEW_MENTIONS"
  fi
done

if [ -z "$(echo "$MENTIONS" | tr -d '[:space:]')" ]; then
  echo "[Monitor] No mentions found"
  exit 0
fi

UNIQUE_MENTIONS=$(echo "$MENTIONS" | grep -v '^$' | jq -s 'unique_by(.id) | sort_by(.created_at) | reverse | .[]' -c 2>/dev/null || true)

if [ -z "$UNIQUE_MENTIONS" ]; then
  echo "[Monitor] No valid mentions"
  exit 0
fi

ARCHIVE_COUNT=0

while IFS= read -r event_json; do
  [ -z "$event_json" ] && continue

  EVENT_ID=$(echo "$event_json" | jq -r '.id')
  SENDER=$(echo "$event_json" | jq -r '.pubkey')
  CONTENT=$(echo "$event_json" | jq -r '.content')
  CREATED_AT=$(echo "$event_json" | jq -r '.created_at')

  if is_processed "$EVENT_ID"; then
    continue
  fi

  if [ "$SENDER" = "$NODE_PUBKEY" ]; then
    mark_processed "$EVENT_ID"
    continue
  fi

  AGE=$((NOW - CREATED_AT))
  if [ "$AGE" -gt "$MAX_AGE_SECONDS" ]; then
    mark_processed "$EVENT_ID"
    continue
  fi

  if ! is_authorized "$SENDER"; then
    echo "[Skip] Unauthorized sender: ${SENDER:0:16}..."
    mark_processed "$EVENT_ID"
    continue
  fi

  echo ""
  echo "[Mention] From: ${SENDER:0:16}..."
  echo "[Mention] Content: $CONTENT"

  URLS=$(extract_urls "$CONTENT")
  if [ -z "$URLS" ]; then
    mark_processed "$EVENT_ID"
    continue
  fi

  if [ "$ARCHIVE_COUNT" -ge "$MAX_ARCHIVES_PER_RUN" ]; then
    echo "[Rate limit] Max archives per run reached ($MAX_ARCHIVES_PER_RUN)"
    break
  fi

  TARGET_URL=$(echo "$URLS" | head -1)
  echo "[Archive] Target: $TARGET_URL"

  # Check if already archived
  EXISTING=$(bash "$NAAN_SCRIPT_DIR/lookup-archive.sh" "$TARGET_URL" 2>/dev/null | grep -c '"id"' || true)
  if [ "$EXISTING" -gt 0 ]; then
    echo "[Skip] URL already archived"
    EXISTING_EVENT=$(nak req -k 4554 -t r="$TARGET_URL" --limit 1 "${RELAYS_ARRAY[0]}" 2>/dev/null | head -1 || true)
    if [ -n "$EXISTING_EVENT" ]; then
      EX_HASH=$(echo "$EXISTING_EVENT" | jq -r '[.tags[] | select(.[0]=="x") | .[1]] | first // "unknown"')
      EX_URL=$(echo "$EXISTING_EVENT" | jq -r '[.tags[] | select(.[0]=="url") | .[1]] | first // ""')
      REPLY="Already archived!\n\n${EX_URL}\n\nsha256: ${EX_HASH}"
      if [ "$DRY_RUN" = false ]; then
        reply_to_note "$EVENT_ID" "$SENDER" "$(echo -e "$REPLY")"
      fi
    fi
    mark_processed "$EVENT_ID"
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would archive: $TARGET_URL"
    mark_processed "$EVENT_ID"
    continue
  fi

  echo "[Archive] Running archive pipeline..."
  ARCHIVE_OUTPUT=$(bash "$NAAN_SCRIPT_DIR/archive-url.sh" "$TARGET_URL" 2>&1) || {
    echo "[Error] Archive failed for $TARGET_URL"
    reply_to_note "$EVENT_ID" "$SENDER" "Archive failed for $TARGET_URL. I'll look into it."
    mark_processed "$EVENT_ID"
    continue
  }

  echo "$ARCHIVE_OUTPUT" | tail -10

  RESULT_BLOSSOM=$(echo "$ARCHIVE_OUTPUT" | grep "^Blossom:" | head -1 | sed 's/^Blossom:\s*//' | awk '{print $1}')
  RESULT_SHA=$(echo "$ARCHIVE_OUTPUT" | grep "^SHA-256:" | head -1 | awk '{print $2}')

  REPLY="Archived!\n\n${RESULT_BLOSSOM}\n\nsha256: ${RESULT_SHA}"
  reply_to_note "$EVENT_ID" "$SENDER" "$(echo -e "$REPLY")"

  mark_processed "$EVENT_ID"
  ARCHIVE_COUNT=$((ARCHIVE_COUNT + 1))

done <<< "$UNIQUE_MENTIONS"

echo ""
echo "=== Monitor Complete ==="
echo "Archives processed: $ARCHIVE_COUNT"
