function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return defaultStatus()
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return defaultStatus()
    parsed.runs = Array.isArray(parsed.runs) ? parsed.runs : []
    parsed.changes = Array.isArray(parsed.changes) ? parsed.changes : []
    parsed.errors = Array.isArray(parsed.errors) ? parsed.errors : []
    return parsed
  } catch (e) {
    var failed = defaultStatus()
    failed.ok = false
    failed.lastError = "Failed to parse bisync status"
    return failed
  }
}

function defaultStatus() {
  return {
    ok: true,
    state: "unknown",
    local: "",
    remote: "",
    timerActive: false,
    timerEnabled: false,
    nextTs: null,
    runningSinceTs: null,
    lastSuccessTs: null,
    listing: null,
    quota: null,
    runs: [],
    changes: [],
    errors: []
  }
}

// Nerd Font glyphs: sync, sync-alert, sync-off.
function stateGlyph(state) {
  if (state === "failed" || state === "missing") return "󰓧"
  if (state === "paused") return "󰓨"
  return "󰓦"
}

function stateText(status, nowMs) {
  var state = status.state
  if (state === "missing") return "Unit not found"
  if (state === "syncing") {
    return status.runningSinceTs ? "Syncing for " + duration(nowSec(nowMs) - status.runningSinceTs) : "Syncing"
  }
  if (state === "failed") return "Last sync failed"
  if (state === "paused") return "Paused"
  if (status.lastSuccessTs) return "Synced " + relativeTime(status.lastSuccessTs, nowMs)
  return "Waiting for first run"
}

function nowSec(nowMs) {
  return (nowMs === undefined ? Date.now() : Number(nowMs)) / 1000
}

function duration(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds || 0)))
  if (s < 60) return s + "s"
  var m = Math.floor(s / 60)
  if (m < 60) return m + "m"
  var h = Math.floor(m / 60)
  return h + "h " + (m % 60) + "m"
}

function relativeTime(timestampSec, nowMs) {
  var ts = Number(timestampSec || 0)
  if (!isFinite(ts) || ts <= 0) return "unknown"
  var diff = Math.floor(nowSec(nowMs) - ts)
  if (diff < 0) return "in " + duration(-diff)
  if (diff < 60) return "just now"
  return duration(diff).split(" ")[0] + " ago"
}

function clockTime(timestampSec) {
  var ts = Number(timestampSec || 0)
  if (!isFinite(ts) || ts <= 0) return ""
  var d = new Date(ts * 1000)
  var pad = function(n) { return n < 10 ? "0" + n : String(n) }
  return pad(d.getHours()) + ":" + pad(d.getMinutes())
}

function nextRunText(status, nowMs) {
  if (status.state === "syncing") return "After this run"
  if (!status.timerActive) return "Timer stopped"
  if (!status.nextTs) return "Unknown"
  return clockTime(status.nextTs) + " (" + relativeTime(status.nextTs, nowMs) + ")"
}

function formatBytes(bytes) {
  var value = Number(bytes || 0)
  if (!isFinite(value) || value <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB"]
  var index = 0
  while (value >= 1000 && index < units.length - 1) {
    value = value / 1000
    index++
  }
  var decimals = value >= 100 || index === 0 ? 0 : 1
  return value.toFixed(decimals).replace(/\.0$/, "") + " " + units[index]
}

function formatCount(n) {
  return String(Math.round(Number(n || 0))).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

function listingText(listing) {
  if (!listing) return "No listing yet"
  return formatCount(listing.files) + " files · " + formatBytes(listing.bytes)
}

function quotaText(quota) {
  if (!quota || !quota.total) return ""
  return formatBytes(quota.used) + " of " + formatBytes(quota.total)
}

function runGlyph(run) {
  if (run.result === "failed") return "󰅚"
  if (run.result === "running") return "󰑓"
  return "󰄬"
}

function runCounts(run) {
  if (run.result === "running") return "in progress"
  var parts = ["↑" + (run.up || 0), "↓" + (run.down || 0)]
  var deleted = (run.deletedLocal || 0) + (run.deletedRemote || 0)
  if (deleted) parts.push("✕" + deleted)
  if (run.conflicts) parts.push("⚠" + run.conflicts)
  return parts.join(" ")
}

// What bisync detected on each side, e.g. "local 19 new, 2 changed".
function runDetected(run) {
  if (run.result === "failed") return run.errors ? run.errors + " error" + (run.errors === 1 ? "" : "s") : "failed"
  var sides = []
  var names = { path1: "local", path2: "remote" }
  for (var key in names) {
    var c = run.changes ? run.changes[key] : null
    if (!c) continue
    var bits = []
    if (c[0]) bits.push(c[0] + " new")
    if (c[1]) bits.push(c[1] + " changed")
    if (c[2]) bits.push(c[2] + " deleted")
    if (bits.length) sides.push(names[key] + " " + bits.join(", "))
  }
  return sides.join(" · ")
}

function actionGlyph(kind) {
  if (kind === "up") return "󰕒"
  if (kind === "down") return "󰇚"
  if (kind === "delLocal" || kind === "delRemote") return "󰆴"
  if (kind === "conflict") return "󰀦"
  return "󰈔"
}

function actionLabel(kind) {
  if (kind === "up") return "Uploaded"
  if (kind === "down") return "Downloaded"
  if (kind === "delLocal") return "Deleted here"
  if (kind === "delRemote") return "Deleted remotely"
  if (kind === "conflict") return "Conflict"
  return ""
}

function baseName(path) {
  var value = String(path || "")
  var index = value.lastIndexOf("/")
  return index >= 0 ? value.substring(index + 1) : value
}

function dirName(path) {
  var value = String(path || "")
  var index = value.lastIndexOf("/")
  return index >= 0 ? value.substring(0, index) : ""
}

function changeTitle(group) {
  if (!group) return ""
  if (group.count === 1 && group.files.length === 1 && !group.files[0].folded) return baseName(group.files[0].path)
  return group.count + " files"
}

function changeMeta(group, nowMs) {
  var parts = [actionLabel(group.kind), relativeTime(group.ts, nowMs)]
  if (group.folder !== "") parts.push(group.folder)
  return parts.join(" · ")
}

function fileTitle(group, file) {
  var path = String(file.path || "")
  var folder = String(group.folder || "")
  var rel = folder !== "" && path.indexOf(folder + "/") === 0 ? path.substring(folder.length + 1) : path
  return file.folded ? rel + "/  (" + file.count + " files)" : rel
}

if (typeof module !== "undefined") {
  module.exports = {
    parseStatus: parseStatus,
    defaultStatus: defaultStatus,
    stateGlyph: stateGlyph,
    stateText: stateText,
    duration: duration,
    relativeTime: relativeTime,
    clockTime: clockTime,
    nextRunText: nextRunText,
    formatBytes: formatBytes,
    formatCount: formatCount,
    listingText: listingText,
    quotaText: quotaText,
    runGlyph: runGlyph,
    runCounts: runCounts,
    runDetected: runDetected,
    actionGlyph: actionGlyph,
    actionLabel: actionLabel,
    baseName: baseName,
    dirName: dirName,
    changeTitle: changeTitle,
    changeMeta: changeMeta,
    fileTitle: fileTitle
  }
}
