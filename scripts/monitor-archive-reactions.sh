#!/usr/bin/env bash
# monitor-archive-reactions.sh - Monitor Boris archive reactions and archive URLs
# Usage: monitor-archive-reactions.sh [--dry-run] [--since <unix_ts>] [--author <pubkey>] [--all-authors]
#
# Boris marks web URLs as archived with a kind 17 URL reaction:
#   content: 📚
#   tags: [["r", "https://example.com/..."]]
#
# This monitor watches those reactions, extracts the r-tag URL, and sends it
# through NAAN's normal archive pipeline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="${STATE_DIR:-$WORKSPACE_DIR/.archive-reaction-state}"

# shellcheck source=relay-discovery.sh
source "$SCRIPT_DIR/relay-discovery.sh"

OWNER_PUBKEY="6e468422dfb74a5738702a8823b9b28168abab8655faacb6853cd0ee15deee93"
SEED_RELAYS=("wss://relay.damus.io" "wss://relay.primal.net" "wss://nos.lol" "wss://wot.dergigi.com" "wss://haven.dergigi.com" "wss://relay.dergigi.com")

MAX_ARCHIVES_PER_RUN=${MAX_ARCHIVES:-3}
MAX_AGE_SECONDS=${MAX_AGE_SECONDS:-1800}
REACTION_KIND=17
ARCHIVE_EMOJI="📚"

DRY_RUN=false
SINCE=""
ALL_AUTHORS=false
AUTHORS=("$OWNER_PUBKEY")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --since) SINCE="$2"; shift 2 ;;
    --author)
      if [ "${#AUTHORS[@]}" -eq 1 ] && [ "${AUTHORS[0]}" = "$OWNER_PUBKEY" ]; then
        AUTHORS=()
      fi
      AUTHORS+=("$2")
      shift 2
      ;;
    --all-authors) ALL_AUTHORS=true; AUTHORS=(); shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$STATE_DIR"
PROCESSED_FILE="$STATE_DIR/processed.txt"
touch "$PROCESSED_FILE"

is_processed() {
  local event_id="$1"
  grep -qF "$event_id" "$PROCESSED_FILE" 2>/dev/null
}

mark_processed() {
  local event_id="$1"
  echo "$event_id" >> "$PROCESSED_FILE"
  tail -1000 "$PROCESSED_FILE" > "$PROCESSED_FILE.tmp" && mv "$PROCESSED_FILE.tmp" "$PROCESSED_FILE"
}

normalize_relay() {
  echo "$1" | sed 's|/$||'
}

add_relay() {
  local relay
  relay=$(normalize_relay "$1")
  [ -n "$relay" ] || return 0
  if [ -z "${SEEN_RELAYS[$relay]+x}" ]; then
    RELAYS+=("$relay")
    SEEN_RELAYS["$relay"]=1
  fi
}

extract_reaction_url() {
  jq -r '
    [.tags[]? | select(.[0] == "r" and ((.[1] // "") | test("^https?://"; "i"))) | .[1]]
    | last // empty
  '
}

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
  nak encode npub "$pubkey" 2>/dev/null || echo "$pubkey"
}

echo "=== NAAN Archive Reaction Monitor ==="
echo "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
if [ "$ALL_AUTHORS" = true ]; then
  echo "Authors: all"
else
  echo "Authors: ${AUTHORS[*]}"
fi
echo ""

RELAYS=()
declare -A SEEN_RELAYS

if [ "$ALL_AUTHORS" = false ]; then
  for author in "${AUTHORS[@]}"; do
    while IFS= read -r relay_url; do
      add_relay "$relay_url"
    done < <(discover_outbox_relays "$author" 2>/dev/null || true)
  done
fi

for relay in "${SEED_RELAYS[@]}"; do
  add_relay "$relay"
done

echo "[NIP-65] Monitoring ${#RELAYS[@]} relays"
echo ""

NOW=$(date +%s)
if [ -n "$SINCE" ]; then
  SINCE_TS="$SINCE"
else
  SINCE_TS=$((NOW - MAX_AGE_SECONDS))
fi

echo "[Monitor] Querying kind $REACTION_KIND archive reactions since $(date -u -d @"$SINCE_TS" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "$SINCE_TS")..."

REACTIONS=""
for relay in "${RELAYS[@]}"; do
  if [ "$ALL_AUTHORS" = true ]; then
    NEW_REACTIONS=$(nak req -k "$REACTION_KIND" --since "$SINCE_TS" --limit 100 "$relay" 2>/dev/null || true)
    if [ -n "$NEW_REACTIONS" ]; then
      REACTIONS="$REACTIONS
$NEW_REACTIONS"
    fi
  else
    for author in "${AUTHORS[@]}"; do
      NEW_REACTIONS=$(nak req -k "$REACTION_KIND" -a "$author" --since "$SINCE_TS" --limit 100 "$relay" 2>/dev/null || true)
      if [ -n "$NEW_REACTIONS" ]; then
        REACTIONS="$REACTIONS
$NEW_REACTIONS"
      fi
    done
  fi
done

if [ -z "$(echo "$REACTIONS" | tr -d '[:space:]')" ]; then
  echo "[Monitor] No archive reactions found"
  exit 0
fi

UNIQUE_REACTIONS=$(echo "$REACTIONS" | grep -v '^$' | jq -s 'unique_by(.id) | sort_by(.created_at) | reverse | .[]' -c 2>/dev/null || true)
if [ -z "$UNIQUE_REACTIONS" ]; then
  echo "[Monitor] No valid archive reactions"
  exit 0
fi

ARCHIVE_COUNT=0

while IFS= read -r event_json <&3; do
  [ -z "$event_json" ] && continue

  EVENT_ID=$(echo "$event_json" | jq -r '.id // empty')
  SENDER=$(echo "$event_json" | jq -r '.pubkey // empty')
  CONTENT=$(echo "$event_json" | jq -r '.content // ""' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  CREATED_AT=$(echo "$event_json" | jq -r '.created_at // 0')

  [ -n "$EVENT_ID" ] || continue

  if is_processed "$EVENT_ID"; then
    echo "[Skip] Already processed: $EVENT_ID"
    continue
  fi

  if [ "$CONTENT" != "$ARCHIVE_EMOJI" ]; then
    echo "[Skip] Kind $REACTION_KIND is not a books archive reaction: $EVENT_ID"
    mark_processed "$EVENT_ID"
    continue
  fi

  AGE=$((NOW - CREATED_AT))
  if [ "$AGE" -gt "$MAX_AGE_SECONDS" ]; then
    echo "[Skip] Too old ($AGE seconds): $EVENT_ID"
    mark_processed "$EVENT_ID"
    continue
  fi

  TARGET_URL=$(echo "$event_json" | extract_reaction_url)
  if [ -z "$TARGET_URL" ]; then
    echo "[Skip] Archive reaction has no web r-tag: $EVENT_ID"
    mark_processed "$EVENT_ID"
    continue
  fi

  SENDER_NAME=$(resolve_name "$SENDER")
  echo ""
  echo "[Reaction] From: $SENDER_NAME ($SENDER)"
  echo "[Reaction] Event: $EVENT_ID"
  echo "[Archive] Target: $TARGET_URL"

  if [ "$ARCHIVE_COUNT" -ge "$MAX_ARCHIVES_PER_RUN" ]; then
    echo "[Rate limit] Max archives per run reached ($MAX_ARCHIVES_PER_RUN)"
    break
  fi

  EXISTING=$(bash "$SCRIPT_DIR/lookup-archive.sh" "$TARGET_URL" < /dev/null 2>/dev/null | grep -c '"id"' || true)
  if [ "$EXISTING" -gt 0 ]; then
    echo "[Skip] URL already archived ($EXISTING existing archives)"
    mark_processed "$EVENT_ID"
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would archive: $TARGET_URL"
    mark_processed "$EVENT_ID"
    continue
  fi

  echo "[Archive] Running archive pipeline..."
  ARCHIVE_OUTPUT=$(bash "$SCRIPT_DIR/archive-url.sh" "$TARGET_URL" --requester "$SENDER" < /dev/null 2>&1) || {
    echo "[Error] Archive failed for $TARGET_URL"
    echo "$ARCHIVE_OUTPUT" | tail -5
    mark_processed "$EVENT_ID"
    continue
  }

  echo "$ARCHIVE_OUTPUT" | tail -10
  mark_processed "$EVENT_ID"
  ARCHIVE_COUNT=$((ARCHIVE_COUNT + 1))
done 3<<< "$UNIQUE_REACTIONS"

echo ""
echo "=== Monitor Complete ==="
echo "Archives processed: $ARCHIVE_COUNT"
