#!/usr/bin/env bash
# monitor-mentions.sh — Monitor public mentions, archive URLs, reply with results
# Usage: monitor-mentions.sh [--dry-run] [--since <unix_ts>]
#
# Subscribes to kind 1 events tagging NAAN's pubkey, filters by configurable
# access tiers (owner/friends/followers/follows/anyone), extracts URLs,
# archives them, and replies publicly.
#
# Uses NIP-65 relay discovery (kind 10002) to find NAAN's inbox relays and
# sender outbox relays, falling back to seed relays if discovery fails.
#
# Requires: nak, jq, curl, bash scripts in scripts/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$WORKSPACE_DIR/.mention-state"
NSEC_FILE="${NSEC_FILE:-$WORKSPACE_DIR/.nostr-nsec.key}"

# Source NIP-65 relay discovery
# shellcheck source=relay-discovery.sh
source "$SCRIPT_DIR/relay-discovery.sh"

# NAAN identity
NAAN_PUBKEY="d1ee2f8ee60e7b2496176963e9f710ca476c456f5f9be2bbe3b4f1e6c62052ff"

# Gigi's pubkey (always allowed as owner)
OWNER_PUBKEY="6e468422dfb74a5738702a8823b9b28168abab8655faacb6853cd0ee15deee93"

# Seed relays (used as baseline alongside NIP-65 discovered relays)
SEED_RELAYS=("wss://relay.damus.io" "wss://relay.primal.net" "wss://nos.lol" "wss://wot.dergigi.com" "wss://haven.dergigi.com" "wss://relay.dergigi.com")

# RELAYS array will be built dynamically from NIP-65 + seeds
RELAYS=()
DM_RELAYS=("wss://relay.damus.io" "wss://relay.primal.net" "wss://nos.lol")

# Access control: owner | friends | followers | follows | anyone
ACCESS_TIER="${ACCESS_TIER:-anyone}"
WHITELIST_FILE="${WHITELIST_FILE:-}"
BLACKLIST_FILE="${BLACKLIST_FILE:-}"

# Rate limits
MAX_ARCHIVES_PER_RUN=${MAX_ARCHIVES:-3}
MAX_AGE_SECONDS=${MAX_AGE_SECONDS:-1800}  # Ignore mentions older than 30 minutes

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

# State files
PROCESSED_FILE="$STATE_DIR/processed.txt"
FOLLOW_CACHE="$STATE_DIR/follows.json"
FOLLOW_CACHE_TS="$STATE_DIR/follows_ts"
FOLLOWERS_CACHE="$STATE_DIR/followers.json"
FOLLOWERS_CACHE_TS="$STATE_DIR/followers_ts"
touch "$PROCESSED_FILE"

# --- Fetch Gigi's follow list (kind 3) with caching ---
fetch_follow_list() {
  local now
  now=$(date +%s)
  local cache_age=3600  # Refresh every hour

  if [ -f "$FOLLOW_CACHE" ] && [ -f "$FOLLOW_CACHE_TS" ]; then
    local cached_at
    cached_at=$(cat "$FOLLOW_CACHE_TS")
    if (( now - cached_at < cache_age )); then
      return 0
    fi
  fi

  echo "[WoT] Fetching Gigi's follow list..."
  local follows_event=""
  for relay in "${RELAYS[@]}"; do
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
    # Use existing cache if available
    if [ ! -f "$FOLLOW_CACHE" ]; then
      echo "[]" > "$FOLLOW_CACHE"
    fi
  fi
}

# --- Fetch owner's followers (kind 3 events tagging owner) with caching ---
fetch_followers_list() {
  local now
  now=$(date +%s)
  local cache_age=3600

  if [ -f "$FOLLOWERS_CACHE" ] && [ -f "$FOLLOWERS_CACHE_TS" ]; then
    local cached_at
    cached_at=$(cat "$FOLLOWERS_CACHE_TS")
    if (( now - cached_at < cache_age )); then
      return 0
    fi
  fi

  echo "[WoT] Fetching owner's followers..."
  local all_followers="[]"
  for relay in "${RELAYS[@]}"; do
    local follower_events
    follower_events=$(nak req -k 3 -t p="$OWNER_PUBKEY" --limit 500 "$relay" 2>/dev/null || true)
    if [ -n "$follower_events" ]; then
      local follower_pubkeys
      follower_pubkeys=$(echo "$follower_events" | jq -r '.pubkey' 2>/dev/null | sort -u | jq -Rs 'split("\n") | map(select(. != ""))')
      all_followers=$(echo -e "$all_followers\n$follower_pubkeys" | jq -s 'flatten | unique')
      break
    fi
  done

  echo "$all_followers" > "$FOLLOWERS_CACHE"
  echo "$now" > "$FOLLOWERS_CACHE_TS"
  local count
  count=$(jq 'length' "$FOLLOWERS_CACHE")
  echo "[WoT] Cached $count followers"
}

# --- Access control helpers ---
_pubkey_in_file() {
  local pubkey="$1"
  local filepath="$2"
  [ -n "$filepath" ] && [ -f "$filepath" ] && grep -qxF "$pubkey" "$filepath" 2>/dev/null
}

_pubkey_follows_owner() {
  local pubkey="$1"
  for relay in "${RELAYS[@]}"; do
    local contact_event
    contact_event=$(nak req -k 3 -a "$pubkey" --limit 1 "$relay" 2>/dev/null | head -1 || true)
    if [ -n "$contact_event" ]; then
      if echo "$contact_event" | jq -e --arg pk "$OWNER_PUBKEY" '[.tags[] | select(.[0]=="p") | .[1]] | any(. == $pk)' > /dev/null 2>&1; then
        return 0
      fi
      return 1
    fi
  done
  return 1
}

_is_follower() {
  local pubkey="$1"
  [ -f "$FOLLOWERS_CACHE" ] && jq -e --arg pk "$pubkey" 'any(. == $pk)' "$FOLLOWERS_CACHE" > /dev/null 2>&1
}

# --- Check if pubkey is authorized ---
is_authorized() {
  local pubkey="$1"

  # 1. Blacklist always denies
  if _pubkey_in_file "$pubkey" "$BLACKLIST_FILE"; then
    return 1
  fi

  # 2. Whitelist always allows
  if _pubkey_in_file "$pubkey" "$WHITELIST_FILE"; then
    return 0
  fi

  # 3. Owner is always allowed
  if [ "$pubkey" = "$OWNER_PUBKEY" ]; then
    return 0
  fi

  # 4. Evaluate access tier
  case "$ACCESS_TIER" in
    owner)
      return 1
      ;;
    friends)
      # Mutual follows: owner follows them AND they follow owner
      if [ -f "$FOLLOW_CACHE" ]; then
        if jq -e --arg pk "$pubkey" 'any(. == $pk)' "$FOLLOW_CACHE" > /dev/null 2>&1; then
          if _pubkey_follows_owner "$pubkey"; then
            return 0
          fi
        fi
      fi
      return 1
      ;;
    followers)
      # Anyone who follows the owner
      if _is_follower "$pubkey"; then
        return 0
      fi
      return 1
      ;;
    follows)
      # Anyone the owner follows (default, backward-compatible)
      if [ -f "$FOLLOW_CACHE" ]; then
        if jq -e --arg pk "$pubkey" 'any(. == $pk)' "$FOLLOW_CACHE" > /dev/null 2>&1; then
          return 0
        fi
      fi
      return 1
      ;;
    anyone)
      return 0
      ;;
    *)
      echo "[WoT] Unknown ACCESS_TIER: $ACCESS_TIER, defaulting to owner-only" >&2
      return 1
      ;;
  esac
}

# --- Check if we already processed this event ---
is_processed() {
  local event_id="$1"
  grep -qF "$event_id" "$PROCESSED_FILE" 2>/dev/null
}

mark_processed() {
  local event_id="$1"
  echo "$event_id" >> "$PROCESSED_FILE"
  # Keep only last 500 entries
  tail -500 "$PROCESSED_FILE" > "$PROCESSED_FILE.tmp" && mv "$PROCESSED_FILE.tmp" "$PROCESSED_FILE"
}

# --- Resolve pubkey to profile name ---
resolve_name() {
  local pubkey="$1"
  local name=""
  for relay in "${RELAYS[@]}"; do
    name=$(timeout 5 nak req -k 0 -a "$pubkey" --limit 1 "$relay" 2>/dev/null | head -1 | jq -r '.content' 2>/dev/null | jq -r '.display_name // .name // empty' 2>/dev/null || true)
    if [ -n "$name" ]; then
      echo "$name"
      return
    fi
  done
  # Fallback: npub
  nak encode npub "$pubkey" 2>/dev/null || echo "$pubkey"
}

# --- Extract URLs from text ---
extract_urls() {
  local text="$1"
  echo "$text" | grep -oP 'https?://[^\s\)"'"'"'<>]+' | head -5 || true
}

# --- Reply to a note ---
reply_to_note() {
  local original_event_id="$1"
  local original_pubkey="$2"
  local reply_text="$3"
  local root_event_id="${4:-}"

  local nsec
  nsec=$(cat "$NSEC_FILE")

  local tag_args=()
  # NIP-10 reply threading
  if [ -n "$root_event_id" ] && [ "$root_event_id" != "$original_event_id" ]; then
    tag_args+=(-t "e=${root_event_id};;root")
    tag_args+=(-t "e=${original_event_id};;reply")
  else
    tag_args+=(-t "e=${original_event_id};;root")
  fi
  tag_args+=(-t "p=$original_pubkey")

  echo "[Reply] Publishing reply..."
  nak event \
    --sec "$nsec" \
    -k 1 \
    "${tag_args[@]}" \
    -c "$reply_text" \
    "${RELAYS[@]}" < /dev/null 2>&1
}

# --- Main ---
echo "=== NAAN Mention Monitor ==="
echo "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Access tier: $ACCESS_TIER"
echo ""

# --- NIP-65 relay discovery ---
# Build relay list dynamically from NAAN's kind 10002 inbox relays + seeds
echo "[NIP-65] Discovering NAAN's inbox relays..."
INBOX_RELAYS=()
while IFS= read -r relay_url; do
  [ -n "$relay_url" ] && INBOX_RELAYS+=("$relay_url")
done < <(discover_inbox_relays "$NAAN_PUBKEY" 2>/dev/null || true)

if [ ${#INBOX_RELAYS[@]} -gt 0 ]; then
  echo "[NIP-65] Found ${#INBOX_RELAYS[@]} inbox relays from kind 10002"
  for r in "${INBOX_RELAYS[@]}"; do
    echo "  - $r"
  done
else
  echo "[NIP-65] No inbox relays found, using seed relays only"
fi

# Merge inbox relays + seed relays (deduplicated)
declare -A _seen_relays
for r in "${INBOX_RELAYS[@]}" "${SEED_RELAYS[@]}"; do
  normalized=$(echo "$r" | sed 's|/$||')
  if [ -z "${_seen_relays[$normalized]+x}" ]; then
    RELAYS+=("$normalized")
    _seen_relays["$normalized"]=1
  fi
done
unset _seen_relays

echo "[NIP-65] Monitoring ${#RELAYS[@]} relays total"
echo ""

fetch_follow_list

# Fetch followers if needed for the current access tier
if [ "$ACCESS_TIER" = "followers" ]; then
  fetch_followers_list
fi

# Determine since timestamp
NOW=$(date +%s)
if [ -n "$SINCE" ]; then
  SINCE_TS="$SINCE"
else
  SINCE_TS=$((NOW - MAX_AGE_SECONDS))
fi

echo "[Monitor] Querying mentions since $(date -u -d @"$SINCE_TS" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date -u -r "$SINCE_TS" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "$SINCE_TS")..."

# Query for kind 1 events tagging NAAN
MENTIONS=""
for relay in "${RELAYS[@]}"; do
  NEW_MENTIONS=$(nak req -k 1 -t p="$NAAN_PUBKEY" --since "$SINCE_TS" --limit 20 "$relay" 2>/dev/null || true)
  if [ -n "$NEW_MENTIONS" ]; then
    MENTIONS="$MENTIONS
$NEW_MENTIONS"
  fi
done

if [ -z "$(echo "$MENTIONS" | tr -d '[:space:]')" ]; then
  echo "[Monitor] No mentions found"
  exit 0
fi

# Deduplicate by event ID
UNIQUE_MENTIONS=$(echo "$MENTIONS" | grep -v '^$' | jq -s 'unique_by(.id) | sort_by(.created_at) | reverse | .[]' -c 2>/dev/null || true)

if [ -z "$UNIQUE_MENTIONS" ]; then
  echo "[Monitor] No valid mentions"
  exit 0
fi

ARCHIVE_COUNT=0

while IFS= read -r event_json <&3; do
  [ -z "$event_json" ] && continue

  EVENT_ID=$(echo "$event_json" | jq -r '.id')
  SENDER=$(echo "$event_json" | jq -r '.pubkey')
  CONTENT=$(echo "$event_json" | jq -r '.content')
  CREATED_AT=$(echo "$event_json" | jq -r '.created_at')

  # Skip if already processed
  if is_processed "$EVENT_ID"; then
    echo "[Skip] Already processed: $EVENT_ID"
    continue
  fi

  # Skip self-mentions
  if [ "$SENDER" = "$NAAN_PUBKEY" ]; then
    mark_processed "$EVENT_ID"
    continue
  fi

  # Check age
  AGE=$((NOW - CREATED_AT))
  if [ "$AGE" -gt "$MAX_AGE_SECONDS" ]; then
    echo "[Skip] Too old ($AGE seconds): $EVENT_ID"
    mark_processed "$EVENT_ID"
    continue
  fi

  # Check authorization
  if ! is_authorized "$SENDER"; then
    echo "[Skip] Unauthorized sender: $SENDER (tier: $ACCESS_TIER)"
    mark_processed "$EVENT_ID"
    continue
  fi

  SENDER_NAME=$(resolve_name "$SENDER")
  echo ""
  echo "[Mention] From: $SENDER_NAME ($SENDER)"
  echo "[Mention] Content: $CONTENT"
  echo "[Mention] Event: $EVENT_ID"

  # Extract URLs from the mention itself
  URLS=$(extract_urls "$CONTENT")

  # If no URLs found, check if this is a reply and fetch the parent note
  if [ -z "$URLS" ]; then
    echo "[Parent] No URLs in mention, checking for parent note..."

    # Try reply tag first, then root tag (NIP-10 markers)
    PARENT_ID=""
    PARENT_ID=$(echo "$event_json" | jq -r '
      # First try marked tags (NIP-10 recommended)
      ([.tags[] | select(.[0]=="e" and .[3]=="reply") | .[1]] | first) //
      ([.tags[] | select(.[0]=="e" and .[3]=="root") | .[1]] | first) //
      # Fallback: positional e tags (last e tag = reply, first = root)
      ([ .tags[] | select(.[0]=="e") | .[1] ] | if length > 1 then .[-1] elif length == 1 then .[0] else null end) //
      empty
    ' 2>/dev/null || true)

    if [ -z "$PARENT_ID" ] || [ "$PARENT_ID" = "null" ]; then
      echo "[Skip] No URLs and not a reply"
      mark_processed "$EVENT_ID"
      continue
    fi

    echo "[Parent] Fetching parent event: $PARENT_ID"
    PARENT_EVENT=""
    for relay in "${RELAYS[@]}"; do
      PARENT_EVENT=$(nak req --id "$PARENT_ID" --limit 1 "$relay" 2>/dev/null | head -1 || true)
      if [ -n "$PARENT_EVENT" ]; then
        break
      fi
    done

    if [ -z "$PARENT_EVENT" ]; then
      echo "[Skip] Could not fetch parent event $PARENT_ID"
      mark_processed "$EVENT_ID"
      continue
    fi

    PARENT_CONTENT=$(echo "$PARENT_EVENT" | jq -r '.content')
    URLS=$(extract_urls "$PARENT_CONTENT")
    if [ -z "$URLS" ]; then
      echo "[Skip] No URLs in parent note either"
      mark_processed "$EVENT_ID"
      continue
    fi

    echo "[Parent] Found URLs in parent note: $(echo "$URLS" | tr '\n' ' ')"
  fi

  # Rate limit
  if [ "$ARCHIVE_COUNT" -ge "$MAX_ARCHIVES_PER_RUN" ]; then
    echo "[Rate limit] Max archives per run reached ($MAX_ARCHIVES_PER_RUN)"
    break
  fi

  # Process the first URL
  TARGET_URL=$(echo "$URLS" | head -1)
  echo "[Archive] Target: $TARGET_URL"

  # Check if already archived
  EXISTING=$(bash "$SCRIPT_DIR/lookup-archive.sh" "$TARGET_URL" < /dev/null 2>/dev/null | grep -c '"id"' || true)
  if [ "$EXISTING" -gt 0 ]; then
    echo "[Skip] URL already archived ($EXISTING existing archives)"
    # Still reply with the existing archive info
    EXISTING_EVENT=$(nak req -k 4554 -t r="$TARGET_URL" --limit 1 "${RELAYS[0]}" < /dev/null 2>/dev/null | head -1 || true)
    if [ -n "$EXISTING_EVENT" ]; then
      EX_HASH=$(echo "$EXISTING_EVENT" | jq -r '[.tags[] | select(.[0]=="x") | .[1]] | first // "unknown"')
      EX_URL=$(echo "$EXISTING_EVENT" | jq -r '[.tags[] | select(.[0]=="url") | .[1]] | first // ""')
      EX_ID=$(echo "$EXISTING_EVENT" | jq -r '.id')

      REPLY="Already archived!\n\n${EX_URL}\n\nsha256: ${EX_HASH}\nnostr:${EX_ID}"

      if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would reply: $REPLY"
      else
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

  # Run the archive pipeline
  echo "[Archive] Running archive pipeline..."
  ARCHIVE_OUTPUT=$(bash "$SCRIPT_DIR/archive-url.sh" "$TARGET_URL" --requester "$SENDER" < /dev/null 2>&1) || {
    echo "[Error] Archive failed for $TARGET_URL"
    echo "$ARCHIVE_OUTPUT" | tail -5
    REPLY="Archive failed for $TARGET_URL. I'll look into it."
    reply_to_note "$EVENT_ID" "$SENDER" "$REPLY"
    mark_processed "$EVENT_ID"
    continue
  }

  echo "$ARCHIVE_OUTPUT" | tail -10

  # Extract results from output
  RESULT_EVENT=$(echo "$ARCHIVE_OUTPUT" | grep "^Event:" | head -1 | awk '{print $2}')
  RESULT_BLOSSOM=$(echo "$ARCHIVE_OUTPUT" | grep "^Blossom:" | head -1 | sed 's/^Blossom:\s*//' | awk '{print $1}')
  RESULT_SHA=$(echo "$ARCHIVE_OUTPUT" | grep "^SHA-256:" | head -1 | awk '{print $2}')
  RESULT_SIZE=$(echo "$ARCHIVE_OUTPUT" | grep "^Size:" | head -1 | sed 's/^Size:\s*//')

  # Build reply
  REPLY="Archived!\n\n${RESULT_BLOSSOM}\n\nsha256: ${RESULT_SHA}"
  if [ -n "$RESULT_SIZE" ]; then
    REPLY="${REPLY}\nSize: ${RESULT_SIZE}"
  fi

  reply_to_note "$EVENT_ID" "$SENDER" "$(echo -e "$REPLY")"

  # Summary line for cron agent
  NAAN_NAME=$(resolve_name "$NAAN_PUBKEY")
  echo ""
  echo "[Done] Archived by ${NAAN_NAME}, requested by ${SENDER_NAME}"
  echo "[Done] URL: $TARGET_URL"
  echo "[Done] Blossom: $RESULT_BLOSSOM"

  mark_processed "$EVENT_ID"
  ARCHIVE_COUNT=$((ARCHIVE_COUNT + 1))

done 3<<< "$UNIQUE_MENTIONS"

echo ""
echo "=== Monitor Complete ==="
echo "Archives processed: $ARCHIVE_COUNT"
