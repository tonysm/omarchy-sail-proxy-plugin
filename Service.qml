import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The plugin's engine, instantiated once per shell as its `service` entry
// point. Every bar widget — one per monitor — reads this one instance, so the
// CLI is polled once however many bars there are.
Item {
  id: root

  property var shell: null
  // The shell injects settings into *widgets*, not services, so Panel.qml
  // pushes them across. Until one does, the defaults below apply.
  property var settings: ({})
  // A widget-local instance, built only under a shell without service support,
  // must stay inert once a shared one exists — otherwise every bar polls.
  property bool active: true

  // ---- CLI readiness -------------------------------------------------------
  property bool cliInstalled: true
  property bool cliOutdated: false
  property bool setupRunning: false
  readonly property bool setupChecking: setupLockProcess.running
  readonly property bool setupNeeded: !cliInstalled || cliOutdated

  // ---- proxy state ---------------------------------------------------------
  property bool installed: true
  // The real, last-observed proxy state.
  property bool _active: false
  // Optimistic override so the switch throws the instant it is clicked rather
  // than a poll later: -1 follows reality, 0/1 while a toggle catches up.
  property int _desired: -1
  readonly property bool proxyOn: _desired === -1 ? _active : (_desired === 1)
  readonly property bool toggling: _desired !== -1

  property var projects: []
  property bool refreshing: false
  property bool refreshPending: false
  // The service name of an unregister in flight, or "" — drives per-row
  // disabled states in the Panel.
  property string pendingAction: ""
  property string lastError: ""
  property bool probed: false

  // A refcount, not a bool: there is one Panel per monitor, and two open
  // popups must not have the second close drop the first back to slow polling.
  property int fastPollers: 0

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  readonly property int openRefreshIntervalSec: intSetting("openRefreshIntervalSec", 5, 2, 60)
  readonly property int refreshIntervalMs:
    1000 * (fastPollers > 0 ? openRefreshIntervalSec : refreshIntervalSec)
  readonly property string folderAction: folderActionSetting()

  readonly property bool busy: statusProcess.running || actionProcess.running
  readonly property int stoppedCount: Model.stoppedCount(projects)

  // StdioCollector.text is not reliably populated by the time onExited runs,
  // so each stream is cached in onStreamFinished and read back as a fallback.
  property string _statusOutput: ""
  property string _statusError: ""
  property string _actionOutput: ""
  property string _actionError: ""
  property string _actionKind: ""

  function setting(name, fallback) {
    if (!settings || settings[name] === undefined || settings[name] === null) return fallback
    return settings[name]
  }

  function intSetting(name, fallback, min, max) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    if (value < min) value = min
    if (value > max) value = max
    return value
  }

  function folderActionSetting() {
    var value = String(setting("folderAction", "files"))
    return value === "editor" || value === "terminal" ? value : "files"
  }

  function binaryArgv() {
    return Model.binaryArgv(settings)
  }

  // ---- refresh -------------------------------------------------------------

  function refresh() {
    if (!active) return
    // Re-entering while a command is in flight would either race the collectors
    // or spawn a second CLI; the request is remembered and replayed instead.
    if (busy) {
      refreshPending = true
      return
    }
    refreshing = true
    _statusOutput = ""
    _statusError = ""
    statusProcess.command = Model.statusCommand(binaryArgv())
    statusProcess.running = true
  }

  function finishStatus(exitCode, stdout, stderr) {
    refreshing = false
    probed = true

    // bash reports 127 for a binary that is not on PATH. This is the one thing
    // the exit code says: `status --json` exits 0 even with the proxy off.
    if (exitCode === 127) {
      cliInstalled = false
      cliOutdated = false
      lastError = ""
      return
    }
    cliInstalled = true

    var parsed = Model.parseStatus(stdout)
    if (!parsed.ok) {
      // Unparseable output from a CLI that *is* there means it is too old to
      // speak `status --json` at all.
      cliOutdated = true
      lastError = Model.cleanText(stderr, 512) || parsed.error
      return
    }
    if (Model.cliOutdated(parsed)) {
      cliOutdated = true
      lastError = ""
      return
    }

    cliOutdated = false
    lastError = ""
    installed = parsed.installed
    _active = parsed.active
    projects = parsed.projects
    // Reality has caught up with — or contradicted — the optimistic toggle.
    if (_desired !== -1 && _active === (_desired === 1)) _desired = -1
  }

  // ---- actions -------------------------------------------------------------
  //
  // Commands serialize through one Process, so two fast clicks cannot race.

  function runAction(kind, command) {
    if (!active || command.length === 0) return false
    if (actionProcess.running) return false
    _actionKind = kind
    _actionOutput = ""
    _actionError = ""
    actionProcess.command = command
    actionProcess.running = true
    return true
  }

  function start() {
    if (!installed || setupNeeded) return
    _desired = 1
    if (!runAction("start", Model.startCommand(binaryArgv()))) _desired = -1
  }

  function stop() {
    if (!installed || setupNeeded) return
    _desired = 0
    if (!runAction("stop", Model.stopCommand(binaryArgv()))) _desired = -1
  }

  function toggle() {
    if (proxyOn) stop()
    else start()
  }

  function unregister(service) {
    if (!Model.isSafeServiceName(service) || pendingAction !== "") return
    var command = Model.unregisterCommand(binaryArgv(), service)
    if (command.length === 0) return
    pendingAction = service
    if (!runAction("unregister", command)) pendingAction = ""
  }

  function finishAction(exitCode, stdout, stderr) {
    var kind = _actionKind
    _actionKind = ""
    pendingAction = ""

    if (exitCode !== 0) {
      // A toggle that failed must not keep pretending: drop back to reality.
      if (kind === "start" || kind === "stop") _desired = -1
      var text = Model.cleanText(stderr, 512) || Model.cleanText(stdout, 512)
      // Backstop for a CLI that answers an action but not a status.
      if (Model.notInstalledError(text)) installed = false
      lastError = text || ("sail-proxy " + kind + " failed")
    } else {
      lastError = ""
    }

    refresh()
    // docker start/stop returns before kamal-proxy's view of the world catches
    // up, so one more look shortly after is what makes the list settle.
    settleTimer.restart()
  }

  // ---- setup ---------------------------------------------------------------

  function setupPlan(ipcTarget) {
    return Model.setupPlan(cliInstalled, cliOutdated, ipcTarget)
  }

  // Lets the Panel tell "setup is already running in another window" from
  // "not installed", so its button can disable itself instead of racing.
  function checkSetupLock() {
    if (!active || setupLockProcess.running) return
    setupLockProcess.command = Model.setupLockCheckCommand()
    setupLockProcess.running = true
  }

  // Called over IPC by the setup terminal's EXIT trap.
  function setupFinished() {
    setupRunning = false
    refresh()
  }

  // ---- fast-poll refcount --------------------------------------------------

  function retainFastPoll() {
    fastPollers += 1
    refresh()
  }

  function releaseFastPoll() {
    if (fastPollers > 0) fastPollers -= 1
  }

  onRefreshIntervalMsChanged: refreshTimer.restart()

  onActiveChanged: {
    if (active) refresh()
  }

  // Firing the replay inside the change handler would re-enter refresh() from
  // within its own busy transition; a zero-interval timer defers it a tick.
  onBusyChanged: {
    if (busy || !refreshPending) return
    refreshPending = false
    refreshSoon.restart()
  }

  Component.onCompleted: if (active) refresh()

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalMs
    running: root.active
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: refreshSoon
    interval: 0
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: settleTimer
    interval: 1200
    repeat: false
    onTriggered: root.refresh()
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
      onStreamFinished: root._statusOutput = text
    }
    stderr: StdioCollector {
      id: statusStderr
      waitForEnd: true
      onStreamFinished: root._statusError = text
    }
    onExited: function (exitCode) {
      root.finishStatus(
        exitCode,
        String(statusStdout.text || root._statusOutput || ""),
        String(statusStderr.text || root._statusError || ""))
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: actionStdout
      waitForEnd: true
      onStreamFinished: root._actionOutput = text
    }
    stderr: StdioCollector {
      id: actionStderr
      waitForEnd: true
      onStreamFinished: root._actionError = text
    }
    onExited: function (exitCode) {
      root.finishAction(
        exitCode,
        String(actionStdout.text || root._actionOutput || ""),
        String(actionStderr.text || root._actionError || ""))
    }
  }

  // flock -n exits nonzero when another window already holds the setup lock.
  Process {
    id: setupLockProcess
    running: false
    command: []
    onExited: function (exitCode) {
      root.setupRunning = exitCode !== 0
    }
  }
}
