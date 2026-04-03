import { EventStore } from "applesauce-core";
import { getDisplayName } from "applesauce-core/helpers/profile";
import { RelayPool } from "applesauce-relay/pool";
import { onlyEvents, toEventStore } from "applesauce-relay/operators";
import { createEventLoaderForStore } from "applesauce-loaders/loaders";
import { timeout, catchError, EMPTY } from "rxjs";

// --- Config ---
const SEED_RELAYS = [
  "wss://relay.damus.io",
  "wss://relay.primal.net",
  "wss://nos.lol",
];

const LOOKUP_RELAYS = ["wss://purplepag.es/", "wss://index.hzrd149.com/"];

const ARCHIVE_KIND = 4554;
const VIDEO_KIND_H = 34235;
const VIDEO_KIND_V = 34236;
const OTS_KIND = 1040;
const RELAY_DISCOVERY_KIND = 30166;
const MAX_DISCOVERED_RELAYS = 30;
const ALL_KINDS = [ARCHIVE_KIND, VIDEO_KIND_H, VIDEO_KIND_V];
const ARCHIVE_FILTER = { kinds: ALL_KINDS };

const MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const DAY_NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

// --- Core ---
const eventStore = new EventStore();
const pool = new RelayPool();

createEventLoaderForStore(eventStore, pool, {
  lookupRelays: LOOKUP_RELAYS,
});

// --- State ---
let discoveredRelayCount = 0;
let queriedRelayCount = 0;
const queriedRelays = new Set();
const profileCache = new Map();
const otsProofs = new Map();

// UI mode: "browse" (feed + text filter) or "lookup" (URL archive history)
let currentMode = "browse";
let activeFilter = "pages"; // "all" | "pages" | "videos"

// Lookup state
let lookupEvents = [];
let lookupUrl = "";
let calendarYear = new Date().getFullYear();
let selectedDate = null;

// --- Helpers ---
function getTag(event, name) {
  const tag = event.tags.find((t) => t[0] === name);
  return tag ? tag[1] : null;
}

function getAllTags(event, name) {
  return event.tags.filter((t) => t[0] === name).map((t) => t[1]);
}

function formatBytes(bytes) {
  if (!bytes) return null;
  const n = parseInt(bytes);
  if (isNaN(n)) return bytes;
  if (n < 1024) return n + " B";
  if (n < 1048576) return (n / 1024).toFixed(1) + " KB";
  if (n < 1073741824) return (n / 1048576).toFixed(1) + " MB";
  return (n / 1073741824).toFixed(2) + " GB";
}

function formatDuration(seconds) {
  if (!seconds) return null;
  const s = parseInt(seconds);
  if (isNaN(s)) return null;
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
  return `${m}:${String(sec).padStart(2, "0")}`;
}

function parseImeta(event) {
  const imetaTags = event.tags.filter((t) => t[0] === "imeta");
  const result = [];
  for (const tag of imetaTags) {
    const entry = {};
    for (let i = 1; i < tag.length; i++) {
      const space = tag[i].indexOf(" ");
      if (space > 0) {
        const key = tag[i].substring(0, space);
        const val = tag[i].substring(space + 1);
        if (key === "fallback") {
          entry.fallbacks = entry.fallbacks || [];
          entry.fallbacks.push(val);
        } else {
          entry[key] = val;
        }
      }
    }
    result.push(entry);
  }
  return result;
}

function isVideoEvent(event) {
  return event.kind === VIDEO_KIND_H || event.kind === VIDEO_KIND_V;
}

function formatDate(timestamp) {
  return new Date(timestamp * 1000).toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function formatDateShort(timestamp) {
  return new Date(timestamp * 1000).toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}

function getEventTimestamp(event) {
  const archivedAt = getTag(event, "archived-at");
  const publishedAt = getTag(event, "published_at");
  if (archivedAt) return parseInt(archivedAt);
  if (publishedAt) return parseInt(publishedAt);
  return event.created_at;
}

function getEventDate(event) {
  const ts = getEventTimestamp(event);
  return new Date(ts * 1000);
}

function dateKey(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function monthKey(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
}

// Detect whether input looks like a URL
function looksLikeUrl(input) {
  const trimmed = input.trim();
  if (!trimmed || trimmed.includes(" ")) return false;
  if (trimmed.match(/^https?:\/\//)) return true;
  // Has a dot and no spaces: likely a URL
  if (trimmed.includes(".") && trimmed.length > 4) return true;
  return false;
}

// Apply type filter to an event list
function applyTypeFilter(events) {
  if (activeFilter === "pages") return events.filter((e) => !isVideoEvent(e));
  if (activeFilter === "videos") return events.filter((e) => isVideoEvent(e));
  return events;
}

// --- Profile resolution ---
function subscribeToProfile(pubkey) {
  if (profileCache.has(pubkey)) return;
  profileCache.set(pubkey, { name: null });

  eventStore.profile(pubkey).subscribe((profile) => {
    if (profile) {
      const name = getDisplayName(profile, pubkey.substring(0, 12) + "…");
      const cached = profileCache.get(pubkey);
      if (cached && cached.name !== name) {
        cached.name = name;
        document.querySelectorAll(`[data-pubkey="${pubkey}"]`).forEach((el) => {
          el.textContent = `by ${name}`;
        });
      }
    }
  });
}

function getProfileName(pubkey) {
  const cached = profileCache.get(pubkey);
  return cached?.name || pubkey.substring(0, 12) + "…";
}

// --- OTS ---
function queryOtsProofs(relays, archiveEventIds) {
  if (archiveEventIds.length === 0) return;

  pool
    .subscription(relays, { kinds: [OTS_KIND], "#e": archiveEventIds, limit: 500 })
    .pipe(onlyEvents(), timeout(10000), catchError(() => EMPTY))
    .subscribe({
      next: (event) => {
        const referencedId = getTag(event, "e");
        if (referencedId && !otsProofs.has(referencedId)) {
          otsProofs.set(referencedId, true);
          const badge = document.querySelector(`[data-ots="${referencedId}"]`);
          if (badge) {
            badge.innerHTML = '<span class="tag ots" title="Bitcoin-timestamped via OpenTimestamps (NIP-03)">₿ timestamped</span>';
          }
        }
      },
    });
}

// ===================================================
// MODE SWITCHING
// ===================================================

function setMode(mode) {
  currentMode = mode;
  const browseView = document.getElementById("browseView");
  const lookupSection = document.getElementById("lookupSection");

  if (mode === "browse") {
    browseView.classList.remove("hidden");
    lookupSection.classList.add("hidden");
    // Re-render with current filter
    const events = eventStore.database.getTimeline(ARCHIVE_FILTER);
    renderArchives(events);
  } else {
    browseView.classList.add("hidden");
    lookupSection.classList.remove("hidden");
  }
}

// ===================================================
// BROWSE VIEW
// ===================================================

function updateStats() {
  const el = document.getElementById("stats");
  const allEvents = eventStore.database.getTimeline(ARCHIVE_FILTER);
  const archiveCount = allEvents.filter((e) => e.kind === ARCHIVE_KIND).length;
  const videoCount = allEvents.filter((e) => isVideoEvent(e)).length;
  const relayInfo =
    discoveredRelayCount > 0
      ? `${queriedRelayCount} relays queried (${SEED_RELAYS.length} seed + ${discoveredRelayCount} discovered via NIP-66)`
      : `${queriedRelayCount} relays queried`;
  const countParts = [];
  if (archiveCount > 0) countParts.push(`${archiveCount} archive${archiveCount !== 1 ? "s" : ""}`);
  if (videoCount > 0) countParts.push(`${videoCount} video${videoCount !== 1 ? "s" : ""}`);
  const total = allEvents.length;
  const countStr = countParts.length > 0 ? countParts.join(", ") : `${total} item${total !== 1 ? "s" : ""}`;
  el.innerHTML = `<span>${countStr}</span> found · ${relayInfo}`;
}

function renderArchives(events) {
  const list = document.getElementById("archiveList");
  const filter = document.getElementById("searchInput").value.toLowerCase();

  // Apply type filter first
  let filtered = applyTypeFilter(events);

  // Then text filter
  if (filter && !looksLikeUrl(filter)) {
    filtered = filtered.filter((e) => {
      const title = (getTag(e, "title") || "").toLowerCase();
      const url = (getTag(e, "r") || "").toLowerCase();
      const pages = getAllTags(e, "page").join(" ").toLowerCase();
      const hashtags = getAllTags(e, "t").join(" ").toLowerCase();
      return title.includes(filter) || url.includes(filter) || pages.includes(filter) || hashtags.includes(filter);
    });
  }

  updateStats();

  if (filtered.length === 0) {
    list.innerHTML = '<div class="empty">No archives found</div>';
    return;
  }

  const pubkeys = new Set(filtered.map((e) => e.pubkey));
  pubkeys.forEach((pk) => subscribeToProfile(pk));

  const eventIds = filtered.map((e) => e.id);
  queryOtsProofs(SEED_RELAYS, eventIds);

  list.innerHTML = filtered.map((event) => renderArchiveCard(event)).join("");
}

function renderArchiveCard(event) {
  const isVideo = isVideoEvent(event);
  const title = getTag(event, "title");
  const originalUrl = getTag(event, "r") || getAllTags(event, "page")[0] || "";
  const profileName = getProfileName(event.pubkey);
  const hasOts = otsProofs.has(event.id);

  if (isVideo) {
    const imeta = parseImeta(event);
    const videoMeta = imeta.find((m) => m.m && m.m.startsWith("video/")) || imeta[0] || {};
    const thumbMeta = imeta.find((m) => m.m && m.m.startsWith("image/"));
    const duration = getTag(event, "duration");
    const publishedAt = getTag(event, "published_at");
    const origin = event.tags.find((t) => t[0] === "origin");
    const hashtags = getAllTags(event, "t");

    const videoUrl = videoMeta.url || "";
    const thumbUrl = videoMeta.image || (thumbMeta && thumbMeta.url) || "";
    const dims = videoMeta.dim || "";
    const size = videoMeta.size || "";
    const hash = videoMeta.x || "";
    const mime = videoMeta.m || "";
    const hashtreeRoot = videoMeta.hashtree || getTag(event, "hashtree") || "";
    const fallbacks = videoMeta.fallbacks || [];
    const allUrls = [videoUrl, ...fallbacks].filter(Boolean);

    const displayDate = publishedAt ? formatDate(parseInt(publishedAt)) : formatDate(event.created_at);
    const displayTitle = escapeHtml(title || originalUrl || "Untitled Video");
    const durationStr = formatDuration(duration);
    const kindLabel = event.kind === VIDEO_KIND_V ? "shorts" : "video";

    return `
    <div class="archive-card video-card">
      ${thumbUrl ? `
      <div class="video-thumb">
        <a href="${escapeHtml(videoUrl || originalUrl)}" target="_blank">
          <img src="${escapeHtml(thumbUrl)}" alt="${displayTitle}" loading="lazy" />
          ${durationStr ? `<span class="video-duration">${durationStr}</span>` : ""}
        </a>
      </div>` : ""}
      <div class="archive-title">
        ${videoUrl
          ? `<a href="${escapeHtml(videoUrl)}" target="_blank">${displayTitle}</a>`
          : displayTitle}
      </div>
      ${originalUrl ? `<a class="archive-url" href="${escapeHtml(originalUrl)}" target="_blank">${escapeHtml(originalUrl)}</a>` : ""}
      <div class="archive-meta">
        <span class="tag">${displayDate}</span>
        <span class="tag format">🎬 ${escapeHtml(kindLabel.toUpperCase())}</span>
        ${mime ? `<span class="tag">${escapeHtml(mime)}</span>` : ""}
        ${dims ? `<span class="tag">${escapeHtml(dims)}</span>` : ""}
        ${size ? `<span class="tag">${formatBytes(size)}</span>` : ""}
        ${durationStr ? `<span class="tag">⏱ ${durationStr}</span>` : ""}
        ${hash ? `<span class="tag" title="${escapeHtml(hash)}">sha256:${escapeHtml(hash.substring(0, 12))}…</span>` : ""}
        ${hashtreeRoot ? `<span class="tag hashtree" title="Chunked via Hashtree for P2P streaming">🌲 chunked</span>` : ""}
        <span data-ots="${event.id}">${hasOts ? '<span class="tag ots" title="Bitcoin-timestamped via OpenTimestamps (NIP-03)">₿ timestamped</span>' : ""}</span>
      </div>
      ${hashtags.length > 0 ? `<div class="archive-meta">${hashtags.slice(0, 8).map((t) => `<span class="tag hashtag">#${escapeHtml(t)}</span>`).join("")}</div>` : ""}
      ${allUrls.length > 0 || hashtreeRoot ? `
        <div class="archive-links">
          ${allUrls.map((u) => { try { return `<a href="${escapeHtml(u)}" target="_blank">📦 ${new URL(u).hostname}</a>`; } catch { return `<a href="${escapeHtml(u)}" target="_blank">📦 mirror</a>`; } }).join("")}
          ${hashtreeRoot ? `<a href="https://files.iris.to/#/${escapeHtml(hashtreeRoot)}/${escapeHtml(videoUrl.split('/').pop() || hash + '.mp4')}" target="_blank">🌲 Stream via Hashtree</a>` : ""}
        </div>` : ""}
      ${origin ? `<div class="archive-origin">via ${escapeHtml(origin[1])}${origin[3] ? ` · <a href="${escapeHtml(origin[3])}" target="_blank">original</a>` : ""}</div>` : ""}
      <div class="archive-pubkey" data-pubkey="${event.pubkey}">by ${escapeHtml(profileName)}</div>
    </div>`;
  }

  const blossomUrls = getAllTags(event, "url");
  const format = getTag(event, "format");
  const size = getTag(event, "size");
  const mime = getTag(event, "m");
  const tool = getTag(event, "tool");
  const hash = getTag(event, "x");
  const hashtreeRoot = getTag(event, "hashtree");
  const archivedAt = getTag(event, "archived-at");
  const displayDate = archivedAt ? formatDate(parseInt(archivedAt)) : formatDate(event.created_at);
  const displayTitle = escapeHtml(title || originalUrl || "Untitled Archive");

  return `
  <div class="archive-card">
    <div class="archive-title">
      ${blossomUrls.length > 0
        ? `<a href="${escapeHtml(blossomUrls[0])}" target="_blank">${displayTitle}</a>`
        : displayTitle}
    </div>
    ${originalUrl ? `<a class="archive-url" href="${escapeHtml(originalUrl)}" target="_blank">${escapeHtml(originalUrl)}</a>` : ""}
    <div class="archive-meta">
      <span class="tag">${displayDate}</span>
      ${format ? `<span class="tag format">${escapeHtml(format.toUpperCase())}</span>` : ""}
      ${mime ? `<span class="tag">${escapeHtml(mime)}</span>` : ""}
      ${size ? `<span class="tag">${formatBytes(size)}</span>` : ""}
      ${tool ? `<span class="tag tool">${escapeHtml(tool)}</span>` : ""}
      ${hash ? `<span class="tag" title="${escapeHtml(hash)}">sha256:${escapeHtml(hash.substring(0, 12))}…</span>` : ""}
      ${hashtreeRoot ? `<span class="tag hashtree" title="Chunked via Hashtree for streaming">🌲 chunked</span>` : ""}
      <span data-ots="${event.id}">${hasOts ? '<span class="tag ots" title="Bitcoin-timestamped via OpenTimestamps (NIP-03)">₿ timestamped</span>' : ""}</span>
    </div>
    ${blossomUrls.length > 0 || hashtreeRoot ? `
      <div class="archive-links">
        ${blossomUrls.map((u) => { try { return `<a href="${escapeHtml(u)}" target="_blank">📦 ${new URL(u).hostname}</a>`; } catch { return `<a href="${escapeHtml(u)}" target="_blank">📦 mirror</a>`; } }).join("")}
        ${hashtreeRoot ? (() => { const fn = blossomUrls.length > 0 ? blossomUrls[0].split('/').pop() : (hash ? hash + '.' + (format || 'bin') : ''); return `<a href="https://files.iris.to/#/${escapeHtml(hashtreeRoot)}/${escapeHtml(fn)}" target="_blank">🌲 Hashtree viewer</a>`; })() : ""}
      </div>` : ""}
    <div class="archive-pubkey" data-pubkey="${event.pubkey}">by ${escapeHtml(profileName)}</div>
  </div>`;
}

// ===================================================
// LOOKUP / CALENDAR VIEW
// ===================================================

function normalizeUrl(url) {
  let u = url.trim();
  if (!u.match(/^https?:\/\//)) u = "https://" + u;
  try {
    const parsed = new URL(u);
    let norm = parsed.origin + parsed.pathname.replace(/\/+$/, "") + parsed.search + parsed.hash;
    return norm;
  } catch {
    return u;
  }
}

function performLookup(url) {
  if (!url) return;
  lookupUrl = url;
  const normalized = normalizeUrl(url);
  lookupEvents = [];
  selectedDate = null;

  setMode("lookup");

  // Show loading
  document.getElementById("lookupLoading").classList.remove("hidden");
  document.getElementById("lookupEmpty").classList.add("hidden");
  document.getElementById("lookupResults").classList.add("hidden");

  // Try multiple URL variants
  const variants = new Set();
  variants.add(normalized);
  variants.add(normalized + "/");
  if (normalized.endsWith("/")) variants.add(normalized.slice(0, -1));
  if (normalized.startsWith("https://")) {
    variants.add(normalized.replace("https://", "http://"));
  } else if (normalized.startsWith("http://")) {
    variants.add(normalized.replace("http://", "https://"));
  }

  const allRelays = [...SEED_RELAYS, ...Array.from(queriedRelays).filter((r) => !SEED_RELAYS.includes(r))];
  const relaysToUse = allRelays.slice(0, 15);
  const collected = [];
  const seenIds = new Set();
  let completedQueries = 0;
  const totalQueries = variants.size;

  variants.forEach((variant) => {
    pool
      .subscription(relaysToUse, { kinds: ALL_KINDS, "#r": [variant], limit: 200 })
      .pipe(onlyEvents(), timeout(10000), catchError(() => EMPTY))
      .subscribe({
        next: (event) => {
          if (!seenIds.has(event.id)) {
            seenIds.add(event.id);
            collected.push(event);
          }
        },
        complete: () => {
          completedQueries++;
          if (completedQueries >= totalQueries) {
            finishLookup(normalized, collected);
          }
        },
        error: () => {
          completedQueries++;
          if (completedQueries >= totalQueries) {
            finishLookup(normalized, collected);
          }
        },
      });
  });

  setTimeout(() => {
    if (completedQueries < totalQueries) {
      finishLookup(normalized, collected);
    }
  }, 12000);
}

function finishLookup(url, events) {
  document.getElementById("lookupLoading").classList.add("hidden");

  events.sort((a, b) => getEventTimestamp(a) - getEventTimestamp(b));
  lookupEvents = events;

  // Apply type filter
  const filtered = applyTypeFilter(events);

  if (filtered.length === 0) {
    document.getElementById("lookupEmpty").classList.remove("hidden");
    document.getElementById("lookupResults").classList.add("hidden");
    return;
  }

  document.getElementById("lookupEmpty").classList.add("hidden");
  document.getElementById("lookupResults").classList.remove("hidden");

  const pubkeys = new Set(filtered.map((e) => e.pubkey));
  pubkeys.forEach((pk) => subscribeToProfile(pk));

  queryOtsProofs(SEED_RELAYS, filtered.map((e) => e.id));

  const latestDate = getEventDate(filtered[filtered.length - 1]);
  calendarYear = latestDate.getFullYear();

  document.getElementById("lookupUrl").innerHTML = `<a href="${escapeHtml(url)}" target="_blank">${escapeHtml(url)}</a>`;

  renderLookupSummary(filtered);
  renderTimeline(filtered);
  renderCalendar(filtered);
  renderSnapshotList(null, filtered);
}

function renderLookupSummary(events) {
  const el = document.getElementById("lookupSummary");
  if (!events || events.length === 0) {
    el.textContent = "";
    return;
  }
  const count = events.length;
  const firstDate = formatDateShort(getEventTimestamp(events[0]));
  const lastDate = formatDateShort(getEventTimestamp(events[events.length - 1]));
  const archivers = new Set(events.map((e) => e.pubkey)).size;

  let text = `${count} snapshot${count !== 1 ? "s" : ""}`;
  if (count > 1) {
    text += ` from ${firstDate} to ${lastDate}`;
  } else {
    text += ` on ${firstDate}`;
  }
  if (archivers > 1) {
    text += ` by ${archivers} archivers`;
  }
  el.textContent = text;
}

// --- Timeline bar chart ---
function renderTimeline(events) {
  const el = document.getElementById("timeline");
  if (!events || events.length < 2) {
    el.innerHTML = "";
    return;
  }

  const monthCounts = new Map();
  events.forEach((event) => {
    const d = getEventDate(event);
    const key = monthKey(d);
    monthCounts.set(key, (monthCounts.get(key) || 0) + 1);
  });

  const firstDate = getEventDate(events[0]);
  const lastDate = getEventDate(events[events.length - 1]);
  const months = [];
  let current = new Date(firstDate.getFullYear(), firstDate.getMonth(), 1);
  const end = new Date(lastDate.getFullYear(), lastDate.getMonth(), 1);

  while (current <= end) {
    const key = monthKey(current);
    months.push({
      key,
      label: MONTH_NAMES[current.getMonth()] + " " + current.getFullYear(),
      shortLabel: MONTH_NAMES[current.getMonth()] + " '" + String(current.getFullYear()).slice(2),
      year: current.getFullYear(),
      count: monthCounts.get(key) || 0,
    });
    current.setMonth(current.getMonth() + 1);
  }

  const maxCount = Math.max(...months.map((m) => m.count));
  const useShort = months.length > 12;

  el.innerHTML = `
    <div class="timeline-title">Archive density over time</div>
    <div class="timeline-bars">
      ${months
        .map(
          (m) => `
        <div class="timeline-bar-col" title="${m.label}: ${m.count} snapshot${m.count !== 1 ? "s" : ""}" data-year="${m.year}">
          <div class="timeline-bar" style="height: ${m.count > 0 ? Math.max(4, (m.count / maxCount) * 80) : 0}px"></div>
          <div class="timeline-label">${useShort ? m.shortLabel : m.label}</div>
        </div>`
        )
        .join("")}
    </div>`;

  el.querySelectorAll(".timeline-bar-col").forEach((col) => {
    col.addEventListener("click", () => {
      const year = parseInt(col.dataset.year);
      if (year && year !== calendarYear) {
        calendarYear = year;
        renderCalendar(applyTypeFilter(lookupEvents));
      }
    });
  });
}

// --- Calendar grid ---
function renderCalendar(events) {
  const grid = document.getElementById("calendarGrid");
  const yearLabel = document.getElementById("calYear");
  yearLabel.textContent = calendarYear;

  if (!events) events = applyTypeFilter(lookupEvents);

  const dayCounts = new Map();
  events.forEach((event) => {
    const d = getEventDate(event);
    if (d.getFullYear() !== calendarYear) return;
    const key = dateKey(d);
    dayCounts.set(key, (dayCounts.get(key) || 0) + 1);
  });

  const maxDayCount = Math.max(1, ...Array.from(dayCounts.values()));

  let html = "";

  for (let month = 0; month < 12; month++) {
    const firstDay = new Date(calendarYear, month, 1);
    const daysInMonth = new Date(calendarYear, month + 1, 0).getDate();
    let startDow = firstDay.getDay() - 1;
    if (startDow < 0) startDow = 6;

    html += `<div class="cal-month">`;
    html += `<div class="cal-month-name">${MONTH_NAMES[month]}</div>`;
    html += `<div class="cal-day-headers">${DAY_NAMES.map((d) => `<span>${d[0]}</span>`).join("")}</div>`;
    html += `<div class="cal-days">`;

    for (let i = 0; i < startDow; i++) {
      html += `<span class="cal-day empty"></span>`;
    }

    for (let day = 1; day <= daysInMonth; day++) {
      const key = `${calendarYear}-${String(month + 1).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
      const count = dayCounts.get(key) || 0;
      const intensity = count > 0 ? Math.max(0.3, count / maxDayCount) : 0;
      const classes = ["cal-day"];
      if (count > 0) classes.push("has-snapshots");
      if (selectedDate === key) classes.push("selected");

      html += `<span class="${classes.join(" ")}" data-date="${key}" data-count="${count}" style="${count > 0 ? `--intensity: ${intensity}` : ""}" title="${count > 0 ? `${count} snapshot${count !== 1 ? "s" : ""} on ${MONTH_NAMES[month]} ${day}` : ""}">${day}</span>`;
    }

    html += `</div></div>`;
  }

  grid.innerHTML = html;

  grid.querySelectorAll(".cal-day.has-snapshots").forEach((el) => {
    el.addEventListener("click", () => {
      const date = el.dataset.date;
      if (selectedDate === date) {
        selectedDate = null;
        grid.querySelectorAll(".cal-day.selected").forEach((s) => s.classList.remove("selected"));
        renderSnapshotList(null, applyTypeFilter(lookupEvents));
      } else {
        selectedDate = date;
        grid.querySelectorAll(".cal-day.selected").forEach((s) => s.classList.remove("selected"));
        el.classList.add("selected");
        renderSnapshotList(date, applyTypeFilter(lookupEvents));
      }
    });
  });
}

// --- Snapshot list ---
function renderSnapshotList(filterDate, events) {
  const el = document.getElementById("snapshotList");

  if (!events) events = applyTypeFilter(lookupEvents);

  if (filterDate) {
    events = events.filter((e) => dateKey(getEventDate(e)) === filterDate);
  }

  if (events.length === 0) {
    el.innerHTML = '<div class="empty">No snapshots for this date</div>';
    return;
  }

  const sorted = [...events].sort((a, b) => getEventTimestamp(b) - getEventTimestamp(a));

  const header = filterDate
    ? `<div class="snapshot-header">Snapshots from ${new Date(filterDate + "T00:00:00").toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" })}</div>`
    : `<div class="snapshot-header">All ${sorted.length} snapshot${sorted.length !== 1 ? "s" : ""}</div>`;

  el.innerHTML = header + sorted.map((event) => {
    const isVideo = isVideoEvent(event);
    const title = getTag(event, "title");
    const profileName = getProfileName(event.pubkey);
    const hasOts = otsProofs.has(event.id);
    const ts = getEventTimestamp(event);
    const displayDate = formatDate(ts);

    if (isVideo) {
      const imeta = parseImeta(event);
      const videoMeta = imeta.find((m) => m.m && m.m.startsWith("video/")) || imeta[0] || {};
      const videoUrl = videoMeta.url || "";
      const size = videoMeta.size || "";
      const mime = videoMeta.m || "";
      const hash = videoMeta.x || "";
      const htRoot = videoMeta.hashtree || getTag(event, "hashtree") || "";
      const duration = getTag(event, "duration");
      const durationStr = formatDuration(duration);
      const fallbacks = videoMeta.fallbacks || [];
      const allUrls = [videoUrl, ...fallbacks].filter(Boolean);
      const displayTitle = escapeHtml(title || "Video snapshot");

      return `
      <div class="archive-card snapshot-card">
        <div class="archive-title">${videoUrl ? `<a href="${escapeHtml(videoUrl)}" target="_blank">${displayTitle}</a>` : displayTitle}</div>
        <div class="archive-meta">
          <span class="tag">${displayDate}</span>
          <span class="tag format">🎬 VIDEO</span>
          ${mime ? `<span class="tag">${escapeHtml(mime)}</span>` : ""}
          ${size ? `<span class="tag">${formatBytes(size)}</span>` : ""}
          ${durationStr ? `<span class="tag">⏱ ${durationStr}</span>` : ""}
          ${hash ? `<span class="tag" title="${escapeHtml(hash)}">sha256:${escapeHtml(hash.substring(0, 12))}…</span>` : ""}
          ${htRoot ? `<span class="tag hashtree" title="Chunked via Hashtree">🌲 chunked</span>` : ""}
          <span data-ots="${event.id}">${hasOts ? '<span class="tag ots" title="Bitcoin-timestamped via OpenTimestamps (NIP-03)">₿ timestamped</span>' : ""}</span>
        </div>
        ${allUrls.length > 0 || htRoot ? `<div class="archive-links">${allUrls.map((u) => { try { return `<a href="${escapeHtml(u)}" target="_blank">📦 ${new URL(u).hostname}</a>`; } catch { return `<a href="${escapeHtml(u)}" target="_blank">📦 mirror</a>`; } }).join("")}${htRoot ? ` <a href="https://files.iris.to/#/${escapeHtml(htRoot)}/${escapeHtml(videoUrl.split('/').pop() || hash + '.mp4')}" target="_blank">🌲 Stream</a>` : ""}</div>` : ""}
        <div class="archive-pubkey" data-pubkey="${event.pubkey}">by ${escapeHtml(profileName)}</div>
      </div>`;
    }

    const blossomUrls = getAllTags(event, "url");
    const format = getTag(event, "format");
    const size = getTag(event, "size");
    const mime = getTag(event, "m");
    const tool = getTag(event, "tool");
    const hash = getTag(event, "x");
    const htRoot = getTag(event, "hashtree");
    const displayTitle = escapeHtml(title || "Snapshot");

    return `
    <div class="archive-card snapshot-card">
      <div class="archive-title">${blossomUrls.length > 0 ? `<a href="${escapeHtml(blossomUrls[0])}" target="_blank">${displayTitle}</a>` : displayTitle}</div>
      <div class="archive-meta">
        <span class="tag">${displayDate}</span>
        ${format ? `<span class="tag format">${escapeHtml(format.toUpperCase())}</span>` : ""}
        ${mime ? `<span class="tag">${escapeHtml(mime)}</span>` : ""}
        ${size ? `<span class="tag">${formatBytes(size)}</span>` : ""}
        ${tool ? `<span class="tag tool">${escapeHtml(tool)}</span>` : ""}
        ${hash ? `<span class="tag" title="${escapeHtml(hash)}">sha256:${escapeHtml(hash.substring(0, 12))}…</span>` : ""}
        ${htRoot ? `<span class="tag hashtree" title="Chunked via Hashtree">🌲 chunked</span>` : ""}
        <span data-ots="${event.id}">${hasOts ? '<span class="tag ots" title="Bitcoin-timestamped via OpenTimestamps (NIP-03)">₿ timestamped</span>' : ""}</span>
      </div>
      ${blossomUrls.length > 0 || htRoot ? `<div class="archive-links">${blossomUrls.map((u) => { try { return `<a href="${escapeHtml(u)}" target="_blank">📦 ${new URL(u).hostname}</a>`; } catch { return `<a href="${escapeHtml(u)}" target="_blank">📦 mirror</a>`; } }).join("")}${htRoot ? ` <a href="https://files.iris.to/#/${escapeHtml(htRoot)}/${escapeHtml(blossomUrls.length > 0 ? blossomUrls[0].split('/').pop() : (hash || '') + '.' + (format || 'bin'))}" target="_blank">🌲 Hashtree</a>` : ""}</div>` : ""}
      <div class="archive-pubkey" data-pubkey="${event.pubkey}">by ${escapeHtml(profileName)}</div>
    </div>`;
  }).join("");
}

// ===================================================
// RELAY DISCOVERY (NIP-66)
// ===================================================

function discoverRelays(seedRelays) {
  return new Promise((resolve) => {
    const discovered = new Set();
    let resolved = false;

    function finish() {
      if (resolved) return;
      resolved = true;
      sub.unsubscribe();
      seedRelays.forEach((r) => discovered.delete(r));
      resolve(Array.from(discovered).slice(0, MAX_DISCOVERED_RELAYS));
    }

    const sub = pool
      .subscription(seedRelays, { kinds: [RELAY_DISCOVERY_KIND], limit: 500 })
      .pipe(onlyEvents(), timeout(3000), catchError(() => EMPTY))
      .subscribe({
        next: (event) => {
          const relayUrl = getTag(event, "d");
          if (relayUrl && relayUrl.startsWith("wss://")) {
            const requiresPayment = event.tags.some((t) => t[0] === "R" && t[1] === "payment");
            const requiresAuth = event.tags.some((t) => t[0] === "R" && t[1] === "auth");
            if (!requiresPayment && !requiresAuth) discovered.add(relayUrl);
          }
        },
        complete: () => finish(),
        error: () => finish(),
      });

    setTimeout(finish, 4000);
  });
}

// ===================================================
// MAIN / BOOT
// ===================================================

function fetchArchives() {
  const btn = document.getElementById("refreshBtn");
  btn.disabled = true;
  btn.textContent = "Querying relays...";

  discoveredRelayCount = 0;
  queriedRelayCount = 0;
  queriedRelays.clear();

  eventStore.timeline(ARCHIVE_FILTER).subscribe((events) => {
    if (currentMode === "browse") {
      renderArchives(events);
    }
  });

  function queryRelays(relays) {
    relays.forEach((r) => {
      if (queriedRelays.has(r)) return;
      queriedRelays.add(r);
      queriedRelayCount++;
    });

    return pool
      .subscription(relays, { kinds: ALL_KINDS, limit: 200 })
      .pipe(
        toEventStore(eventStore),
        timeout(10000),
        catchError(() => EMPTY)
      )
      .subscribe({
        complete: () => updateStats(),
      });
  }

  queryRelays(SEED_RELAYS);

  discoverRelays(SEED_RELAYS).then((newRelays) => {
    discoveredRelayCount = newRelays.length;
    if (newRelays.length > 0) {
      btn.textContent = `Querying ${newRelays.length + SEED_RELAYS.length} relays...`;
      queryRelays(newRelays);
    }
    updateStats();
  });

  setTimeout(() => {
    btn.disabled = false;
    btn.textContent = "Refresh";
  }, 10000);
}

// --- Handle input changes ---
function handleInput() {
  const value = searchInput.value.trim();

  if (!value) {
    // Empty: show browse feed
    if (currentMode !== "browse") setMode("browse");
    else {
      const events = eventStore.database.getTimeline(ARCHIVE_FILTER);
      renderArchives(events);
    }
    return;
  }

  if (!looksLikeUrl(value)) {
    // Text filter: show browse feed filtered
    if (currentMode !== "browse") setMode("browse");
    else {
      const events = eventStore.database.getTimeline(ARCHIVE_FILTER);
      renderArchives(events);
    }
  }
  // If it looks like a URL, don't do anything on input -- wait for Enter
}

// Re-render current view with new filter
function rerender() {
  if (currentMode === "browse") {
    const events = eventStore.database.getTimeline(ARCHIVE_FILTER);
    renderArchives(events);
  } else {
    // Re-filter lookup results
    const filtered = applyTypeFilter(lookupEvents);
    if (filtered.length === 0) {
      document.getElementById("lookupEmpty").classList.remove("hidden");
      document.getElementById("lookupResults").classList.add("hidden");
    } else {
      document.getElementById("lookupEmpty").classList.add("hidden");
      document.getElementById("lookupResults").classList.remove("hidden");
      renderLookupSummary(filtered);
      renderTimeline(filtered);
      renderCalendar(filtered);
      renderSnapshotList(selectedDate, filtered);
    }
  }
}

// --- Event Listeners ---
const searchInput = document.getElementById("searchInput");

searchInput.addEventListener("input", handleInput);

searchInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") {
    const value = searchInput.value.trim();
    if (looksLikeUrl(value)) {
      performLookup(value);
    }
  }
});

document.getElementById("refreshBtn").addEventListener("click", () => {
  const value = searchInput.value.trim();
  if (looksLikeUrl(value)) {
    performLookup(value);
  } else {
    if (currentMode !== "browse") setMode("browse");
    fetchArchives();
  }
});

// Filter buttons
document.querySelectorAll(".filter-btn").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".filter-btn").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    activeFilter = btn.dataset.filter;
    rerender();
  });
});

// Calendar navigation
document.getElementById("calPrev").addEventListener("click", () => {
  calendarYear--;
  const filtered = applyTypeFilter(lookupEvents);
  renderCalendar(filtered);
});

document.getElementById("calNext").addEventListener("click", () => {
  calendarYear++;
  const filtered = applyTypeFilter(lookupEvents);
  renderCalendar(filtered);
});

// --- Boot ---
fetchArchives();
