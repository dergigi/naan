#!/usr/bin/env bash
# monitor-archive-reactions.sh - Monitor Boris archive reactions and archive URLs
# Usage: monitor-archive-reactions.sh [--dry-run] [--backfill] [--since <unix_ts>] [--max-archives <n>] [--author <pubkey>] [--all-authors]
#
# Boris marks web URLs as archived with a kind 17 URL reaction:
#   content: 📚
#   tags: [["r", "https://example.com/..."]]
#
# This monitor watches those reactions from all authors by default, extracts the
# r-tag URL, and sends it through NAAN's normal archive pipeline. Use --author
# to scope a run to one or more pubkeys.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="${STATE_DIR:-$WORKSPACE_DIR/.archive-reaction-state}"

# shellcheck source=relay-discovery.sh
source "$SCRIPT_DIR/relay-discovery.sh"

SEED_RELAYS=("wss://relay.damus.io" "wss://relay.primal.net" "wss://nos.lol" "wss://wot.dergigi.com" "wss://haven.dergigi.com" "wss://relay.dergigi.com")

MAX_ARCHIVES_PER_RUN=${MAX_ARCHIVES:-3}
MAX_AGE_SECONDS=${MAX_AGE_SECONDS:-1800}
QUERY_LIMIT=${QUERY_LIMIT:-100}
REACTION_KIND=17
ARCHIVE_EMOJI="📚"

DRY_RUN=false
BACKFILL=false
SINCE=""
ALL_AUTHORS=true
AUTHORS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --backfill) BACKFILL=true; shift ;;
    --since) SINCE="$2"; shift 2 ;;
    --max-archives) MAX_ARCHIVES_PER_RUN="$2"; shift 2 ;;
    --author)
      ALL_AUTHORS=false
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

# Return success when a reaction event ID has already been handled.
is_processed() {
  local event_id="$1"
  grep -qF "$event_id" "$PROCESSED_FILE" 2>/dev/null
}

# Persist a handled event ID unless this is a dry run.
mark_processed() {
  local event_id="$1"
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  echo "$event_id" >> "$PROCESSED_FILE"
  tail -1000 "$PROCESSED_FILE" > "$PROCESSED_FILE.tmp" && mv "$PROCESSED_FILE.tmp" "$PROCESSED_FILE"
}

# Normalize relay URLs so deduplication treats trailing slashes as identical.
normalize_relay() {
  echo "$1" | sed 's|/$||'
}

# Add a relay URL to RELAYS once, preserving first-seen order.
add_relay() {
  local relay
  relay=$(normalize_relay "$1")
  [ -n "$relay" ] || return 0
  if [ -z "${SEEN_RELAYS[$relay]+x}" ]; then
    RELAYS+=("$relay")
    SEEN_RELAYS["$relay"]=1
  fi
}

# Extract the last web URL from a kind 17 reaction's r tags.
extract_reaction_url() {
  jq -r '
    [.tags[]? | select(.[0] == "r" and ((.[1] // "") | test("^https?://"; "i"))) | .[1]]
    | last // empty
  '
}

# Resolve a pubkey to a profile name, falling back to npub or raw hex.
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
echo "Mode: $([ "$BACKFILL" = true ] && echo "backfill" || echo "recent")"
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
elif [ "$BACKFILL" = true ]; then
  SINCE_TS=0
else
  SINCE_TS=$((NOW - MAX_AGE_SECONDS))
fi

echo "[Monitor] Querying kind $REACTION_KIND archive reactions since $(date -u -d @"$SINCE_TS" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "$SINCE_TS")..."

REACTIONS=""
QUERY_SUCCESS_COUNT=0
QUERY_FAIL_COUNT=0

for relay in "${RELAYS[@]}"; do
  query_args=(-k "$REACTION_KIND" --since "$SINCE_TS" --limit "$QUERY_LIMIT")
  if [ "$BACKFILL" = true ]; then
    query_args+=(--paginate)
  fi

  if [ "$ALL_AUTHORS" = true ]; then
    if NEW_REACTIONS=$(nak req "${query_args[@]}" "$relay" 2>/dev/null); then
      QUERY_SUCCESS_COUNT=$((QUERY_SUCCESS_COUNT + 1))
      if [ -n "$NEW_REACTIONS" ]; then
        REACTIONS="$REACTIONS
$NEW_REACTIONS"
      fi
    else
      QUERY_FAIL_COUNT=$((QUERY_FAIL_COUNT + 1))
      echo "[Warn] Query failed: $relay" >&2
    fi
  else
    for author in "${AUTHORS[@]}"; do
      if NEW_REACTIONS=$(nak req "${query_args[@]}" -a "$author" "$relay" 2>/dev/null); then
        QUERY_SUCCESS_COUNT=$((QUERY_SUCCESS_COUNT + 1))
        if [ -n "$NEW_REACTIONS" ]; then
          REACTIONS="$REACTIONS
$NEW_REACTIONS"
        fi
      else
        QUERY_FAIL_COUNT=$((QUERY_FAIL_COUNT + 1))
        echo "[Warn] Query failed: $relay author=$author" >&2
      fi
    done
  fi
done

if [ "$QUERY_SUCCESS_COUNT" -eq 0 ]; then
  echo "[Error] All relay queries failed ($QUERY_FAIL_COUNT failures); archive reaction state is unknown" >&2
  exit 1
fi

if [ "$QUERY_FAIL_COUNT" -gt 0 ]; then
  echo "[Monitor] Relay queries: $QUERY_SUCCESS_COUNT succeeded, $QUERY_FAIL_COUNT failed"
fi

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

  if [ "$BACKFILL" = false ]; then
    AGE=$((NOW - CREATED_AT))
    if [ "$AGE" -gt "$MAX_AGE_SECONDS" ]; then
      echo "[Skip] Too old ($AGE seconds): $EVENT_ID"
      mark_processed "$EVENT_ID"
      continue
    fi
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
    ARCHIVE_COUNT=$((ARCHIVE_COUNT + 1))
    continue
  fi

  echo "[Archive] Running archive pipeline..."
  ARCHIVE_OUTPUT=$(bash "$SCRIPT_DIR/archive-url.sh" "$TARGET_URL" --requester "$SENDER" < /dev/null 2>&1) || {
    echo "[Error] Archive failed for $TARGET_URL"
    echo "$ARCHIVE_OUTPUT" | tail -5
    continue
  }

  echo "$ARCHIVE_OUTPUT" | tail -10
  mark_processed "$EVENT_ID"
  ARCHIVE_COUNT=$((ARCHIVE_COUNT + 1))
done 3<<< "$UNIQUE_REACTIONS"

echo ""
echo "=== Monitor Complete ==="
echo "Archives processed: $ARCHIVE_COUNT"
