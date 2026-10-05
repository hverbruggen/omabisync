import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})

  property var status: Model.defaultStatus()
  property bool refreshing: false
  property string actionStatus: ""
  property string lastError: ""
  // Bumped every refresh so relative times ("5m ago") re-evaluate.
  property double nowMs: Date.now()

  // Optimistic timer state while a pause/resume is in flight: -1 follows reality.
  property int _desiredTimer: -1
  readonly property bool timerOn: _desiredTimer === -1 ? status.timerActive === true : _desiredTimer === 1

  readonly property string unit: validUnit(setting("unit", "rclone-bisync-sync"))
  // The unit actually watched: the configured one, or the one status.py auto-detected.
  readonly property string activeUnit: status.unit ? validUnit(status.unit) : unit
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 10, 3600)
  readonly property int historyDays: intSetting("historyDays", 3, 1, 30)
  readonly property int maxRuns: intSetting("maxRuns", 4, 1, 20)
  readonly property int maxChanges: intSetting("maxChanges", 8, 1, 30)
  readonly property bool busy: statusProcess.running || controlProcess.running
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("status.py")).replace(/^file:\/\//, ""))

  property string _statusOutput: ""
  property string _statusError: ""
  property string _controlError: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null || value === "" ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // The unit name ends up in a terminal command line, so keep it to systemd's
  // own character set.
  function validUnit(name) {
    var value = String(name || "").replace(/\.(service|timer)$/, "")
    return /^[A-Za-z0-9@._-]+$/.test(value) ? value : "rclone-bisync-sync"
  }

  function refresh() {
    if (statusProcess.running) return
    _statusOutput = ""
    _statusError = ""
    refreshing = true
    statusProcess.command = ["python3", helperPath, unit, String(historyDays), String(maxRuns), String(maxChanges)]
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      lastError = parsed.lastError || "Failed to read bisync status"
      return
    }
    status = parsed
    if (_desiredTimer !== -1 && status.timerActive === (_desiredTimer === 1)) _desiredTimer = -1
    lastError = ""
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 160 ? value.substring(0, 157) + "…" : value
  }

  function syncNow() {
    if (status.state === "syncing") return
    runControl(["systemctl", "--user", "start", "--no-block", activeUnit + ".service"], "Sync started")
  }

  function toggleTimer() {
    if (controlProcess.running) return
    // Decide once: setting _desiredTimer below changes timerOn.
    var pause = timerOn
    _desiredTimer = pause ? 0 : 1
    runControl(["systemctl", "--user", pause ? "stop" : "start", activeUnit + ".timer"],
               pause ? "Timer paused until next login" : "Timer resumed")
  }

  function runControl(command, message) {
    if (controlProcess.running) return
    _controlError = ""
    controlProcess.message = message
    controlProcess.command = command
    controlProcess.running = true
  }

  function openJournal() {
    // Follow the unit's journal, minus rclone's per-symlink warnings.
    var cmd = "journalctl --user -u " + activeUnit + ".service -n 300 -f -g '^(?!.*follow symlink)'"
    Quickshell.execDetached(["setsid", "uwsm-app", "--", "xdg-terminal-exec",
                             "--app-id=org.omarchy.terminal", "--title=omabisync journal",
                             "-e", "bash", "-c", cmd])
  }

  function openFolder() {
    if (!status.local) return
    Quickshell.execDetached(["uwsm-app", "--", "nautilus", status.local])
  }

  // Opens Nautilus with the file (or folded folder) selected. Files deleted
  // here no longer exist, so their parent folder opens instead.
  function openPath(relPath, kind) {
    if (!status.local || !relPath) return
    var base = status.local.replace(/\/$/, "") + "/"
    if (kind === "delLocal") {
      var parent = String(relPath).replace(/\/[^\/]*$/, "")
      Quickshell.execDetached(["uwsm-app", "--", "nautilus", base + parent])
      return
    }
    Quickshell.execDetached(["uwsm-app", "--", "nautilus", "--select", base + relPath])
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: { root.nowMs = Date.now(); root.refresh() }
  }

  Timer {
    // Keeps "Syncing for 12m" and "5m ago" ticking between refreshes.
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: delayedRefresh
    interval: 1500
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2500
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function(exitCode) {
      root.refreshing = false
      root.nowMs = Date.now()
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0) root.applyStatus(stdout)
      else root.lastError = root.elide(stderr || stdout || "Could not read bisync status")
    }
  }

  Process {
    id: controlProcess
    property string message: ""
    running: false
    command: []
    stderr: StdioCollector { id: controlStderr; waitForEnd: true; onStreamFinished: root._controlError = text }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root._desiredTimer = -1
        root.lastError = root.elide(controlStderr.text || root._controlError || "systemctl failed")
        root.actionStatus = ""
      } else {
        root.lastError = ""
        root.actionStatus = controlProcess.message
        actionStatusTimer.restart()
      }
      delayedRefresh.restart()
    }
  }
}
