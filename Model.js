// Pure JS behind the Sail Proxy widget: argv builders, the setup-state
// contract, status parsing, validation and formatting. No QML imports, so
// every function here is testable on its own.
//
// The threat model: service names, hosts, container names and directories all
// come out of Docker labels, which any project on this machine can set. They
// are never interpolated into a shell string — commands are built as argv
// arrays and validated before they leave this file.

// Portions of this file — the bounded-capture subprocess wrapper and the setup
// lock/launch contract — are copied or adapted from the HEY Omarchy plugin,
// MIT licensed, Copyright (c) 2026 37signals LLC. See THIRD_PARTY_NOTICES.md.

// ---------------------------------------------------------------------------
// Setup: the CLI is installed and kept current by mise.
//
// This mirrors 37signals.hey's setup contract — a private flock so two windows
// cannot race the same install, traps that map HUP/INT/TERM to 129/130/143 so
// Ctrl-C is honored, and an EXIT trap that calls back over IPC with the fix's
// real exit status preserved.
var setupLockDirectoryName = "setup-lock"
var setupLockShell = "uid=$(id -u) || exit 76; "
  + "runtime=${XDG_RUNTIME_DIR:-/run/user/$uid}; "
  + "[ -d \"$runtime\" ] && [ ! -L \"$runtime\" ] "
  + "&& [ \"$(stat -c %u -- \"$runtime\" 2>/dev/null)\" = \"$uid\" ] "
  + "&& [ \"$(stat -c %a -- \"$runtime\" 2>/dev/null)\" = 700 ] || exit 76; "
  + "ensure_private_dir() { path=$1; "
  + "if mkdir -m 700 -- \"$path\" 2>/dev/null; then return 0; fi; "
  + "[ -d \"$path\" ] && [ ! -L \"$path\" ] "
  + "&& [ \"$(stat -c %u -- \"$path\" 2>/dev/null)\" = \"$uid\" ] "
  + "&& chmod 700 -- \"$path\"; }; "
  + "umask 077; base=\"$runtime/tonysm.sail-proxy-$uid\"; "
  + "ensure_private_dir \"$base\" || exit 76; "
  + "lock=\"$base/" + setupLockDirectoryName + "\"; "
  + "ensure_private_dir \"$lock\" || exit 76; "

function setupLockCheckCommand() {
  return ["bash", "-c", setupLockShell + "exec 9<\"$lock\"; flock -n 9"]
}

function shellQuote(value) {
  return "'" + String(value || "").replace(/'/g, "'\\''") + "'"
}

function setupLaunchCommand(fix, ipcTarget) {
  var target = shellQuote(ipcTarget)
  var completion = "omarchy-shell -q \"$target\" setupFinished"
  return "target=" + target + "; " + setupLockShell
    + "( flock -n 9 || { printf '%s\\n' 'Sail Proxy setup is already running.'; exit 75; }; "
    + "trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM; "
    + "trap 'rc=$?; trap - EXIT; flock -u 9; " + completion + "; exit $rc' EXIT; "
    + String(fix || "") + " ) 9<\"$lock\""
}

// omarchy-mise-install writes a wrapper to ~/.local/bin/sail-proxy; it does not
// install anything itself. The chained `sail-proxy --version` is what triggers
// the actual mise install, and it has to happen here — inside the visible
// terminal — because on the widget's next poll the capture deadline would kill
// it mid-download. hey chains `&& hey setup --silent-success` for the same
// reason.
var setupFix = "omarchy-mise-install github:tonysm/sail-proxy sail-proxy && sail-proxy --version"

function setupPlan(installed, outdated, ipcTarget) {
  var missing = installed !== true
  var plan = {
    needed: missing || outdated === true,
    title: missing ? "Install the sail-proxy CLI" : "Update the sail-proxy CLI",
    detail: missing
      ? "The widget reads its state from the sail-proxy CLI, which mise installs and updates."
      : "This sail-proxy is too old to report its status. Updating replaces it with the current release.",
    buttonLabel: missing ? "Install sail-proxy…" : "Update sail-proxy…",
    command: setupFix,
    fix: setupFix
  }
  plan.launchCommand = setupLaunchCommand(plan.fix, ipcTarget)
  return plan
}

// ---------------------------------------------------------------------------
// Limits. Every captured process gets its own byte ceiling on each stream, so
// a CLI that runs away cannot grow the shell's heap. The extra byte lets the
// consumer tell a response exactly at the limit from one that was truncated.

var cliResponseByteLimit = 1024 * 1024
var cliErrorByteLimit = 64 * 1024
var maximumProjectCount = 200
var statusTimeoutSec = 20
var actionTimeoutSec = 60
var finiteCommandTimeoutSec = 30
var finiteCommandKillGraceSec = 2

var serviceNameCharacterLimit = 128
var hostCharacterLimit = 253
var directoryCharacterLimit = 4096
var errorCharacterLimit = 512

function positiveInteger(value, fallback) {
  var number = parseInt(value, 10)
  return isFinite(number) && number > 0 ? number : fallback
}

var boundedCaptureScript = "stdout_limit=$1; stderr_limit=$2; deadline=$3; grace=$4; shift 4; child_pid=; timer_pid=; killer_pid=; timed_out=0; "
  + "stop_timer() { if [ -n \"$timer_pid\" ]; then kill -TERM -- \"-$timer_pid\" 2>/dev/null || true; kill -TERM \"$timer_pid\" 2>/dev/null || true; wait \"$timer_pid\" 2>/dev/null || true; timer_pid=; fi; }; "
  + "start_group_killer() { setpriv --pdeathsig KILL setsid bash -c 'end=$((SECONDS + $1)); while kill -0 -- \"-$2\" 2>/dev/null && [ \"$SECONDS\" -lt \"$end\" ]; do sleep 0.1; done; kill -KILL -- \"-$2\" 2>/dev/null || true' sail-proxy-output-killer \"$grace\" \"$child_pid\" & killer_pid=$!; }; "
  + "wait_group_killer() { if [ -n \"$killer_pid\" ]; then wait \"$killer_pid\" 2>/dev/null || true; killer_pid=; fi; }; "
  + "cleanup_group() { if [ -n \"$child_pid\" ] && kill -0 -- \"-$child_pid\" 2>/dev/null; then kill -TERM -- \"-$child_pid\" 2>/dev/null || true; start_group_killer; wait_group_killer; fi; }; "
  + "terminate_child() { if [ -n \"$child_pid\" ]; then kill -TERM -- \"-$child_pid\" 2>/dev/null || true; kill -TERM \"$child_pid\" 2>/dev/null || true; start_group_killer; wait \"$child_pid\" 2>/dev/null || true; wait_group_killer; child_pid=; fi; }; "
  + "stop_child() { trap - HUP INT TERM USR1; stop_timer; terminate_child; exit 143; }; "
  + "trap 'timed_out=1' USR1; trap stop_child HUP INT TERM; "
  + "setpriv --pdeathsig KILL setsid \"$@\" "
  + "> >(head -c \"$((stdout_limit + 1))\") "
  + "2> >(head -c \"$((stderr_limit + 1))\" >&2) & child_pid=$!; "
  + "if [ \"$deadline\" -gt 0 ]; then parent_pid=$BASHPID; "
  + "setpriv --pdeathsig KILL setsid bash -c 'sleep \"$1\" || exit 0; kill -USR1 \"$2\" 2>/dev/null || exit 0; kill -TERM -- \"-$3\" 2>/dev/null || true; kill -TERM \"$3\" 2>/dev/null || true; end=$((SECONDS + $4)); while kill -0 -- \"-$3\" 2>/dev/null && [ \"$SECONDS\" -lt \"$end\" ]; do sleep 0.1; done; if kill -0 -- \"-$3\" 2>/dev/null; then kill -KILL -- \"-$3\" 2>/dev/null || true; fi' "
  + "sail-proxy-output-timeout \"$deadline\" \"$parent_pid\" \"$child_pid\" \"$grace\" & timer_pid=$!; fi; "
  + "wait \"$child_pid\"; status=$?; "
  + "if [ \"$timed_out\" -eq 1 ]; then wait \"$child_pid\" 2>/dev/null || true; status=124; wait \"$timer_pid\" 2>/dev/null || true; timer_pid=; "
  + "else stop_timer; cleanup_group; fi; child_pid=; exit \"$status\""

function boundedCaptureCommand(command, stdoutLimit, stderrLimit, timeoutSeconds, killGraceSeconds) {
  var source = Array.isArray(command) ? command : []
  var stdoutBytes = positiveInteger(stdoutLimit, cliResponseByteLimit)
  var stderrBytes = positiveInteger(stderrLimit, cliErrorByteLimit)
  var deadline = timeoutSeconds === 0 ? 0 : positiveInteger(timeoutSeconds, finiteCommandTimeoutSec)
  var grace = positiveInteger(killGraceSeconds, finiteCommandKillGraceSec)
  return ["setpriv", "--pdeathsig", "TERM", "bash", "-o", "pipefail", "-c",
    boundedCaptureScript, "sail-proxy-output-guard", String(stdoutBytes), String(stderrBytes),
    String(deadline), String(grace)].concat(source)
}

// The argv a captured command actually runs, with the guard stripped back off.
// Only used for logging and tests.
function capturedCommandPayload(command) {
  var source = Array.isArray(command) ? command : []
  if (source.length < 13 || source[0] !== "setpriv" || source[1] !== "--pdeathsig"
      || source[2] !== "TERM" || source[3] !== "bash" || source[4] !== "-o"
      || source[5] !== "pipefail" || source[6] !== "-c"
      || source[7] !== boundedCaptureScript || source[8] !== "sail-proxy-output-guard") return source.slice()
  return source.slice(13)
}

function exceedsUtf8ByteLimit(value, limit) {
  var text = String(value || "")
  var maximum = positiveInteger(limit, cliResponseByteLimit)
  var bytes = 0
  for (var i = 0; i < text.length; i++) {
    var code = text.charCodeAt(i)
    if (code <= 0x7f) bytes += 1
    else if (code <= 0x7ff) bytes += 2
    else if (code >= 0xd800 && code <= 0xdbff
        && i + 1 < text.length
        && text.charCodeAt(i + 1) >= 0xdc00
        && text.charCodeAt(i + 1) <= 0xdfff) {
      bytes += 4
      i += 1
    } else bytes += 3
    if (bytes > maximum) return true
  }
  return false
}

function boundedString(value, limit) {
  if (value === undefined || value === null || typeof value === "object") return ""
  var text = String(value)
  var maximum = positiveInteger(limit, errorCharacterLimit)
  if (text.length <= maximum) return text
  text = text.substring(0, maximum)
  // Never cut a surrogate pair in half.
  var last = text.charCodeAt(text.length - 1)
  return last >= 0xd800 && last <= 0xdbff ? text.substring(0, text.length - 1) : text
}

// Control characters are stripped rather than escaped: this text lands in QML
// Text elements, where a stray carriage return or escape byte is a rendering
// bug, not data.
function cleanText(value, limit) {
  var text = boundedString(value, limit)
  return text.replace(/[\x00-\x1f\x7f]+/g, " ").trim()
}

// ---------------------------------------------------------------------------
// Validation. Everything below originates in Docker labels — treat it as
// hostile input. Builders return [] rather than an unsafe argv, so a bad name
// produces a command that is never run, not a command that does the wrong
// thing.

function isSafeServiceName(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > serviceNameCharacterLimit) return false
  return /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value)
}

function isSafeHost(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > hostCharacterLimit) return false
  return /^[A-Za-z0-9][A-Za-z0-9.-]*$/.test(value)
}

function isSafeDirectory(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > directoryCharacterLimit) return false
  if (value.charAt(0) !== "/") return false
  return !/[\x00\n]/.test(value)
}

// A custom binary need not be absolute — a user may point this at a relative
// build path — but it must still be a single tidy argument.
function isSafeBinaryPath(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > directoryCharacterLimit) return false
  return !/[\x00\n]/.test(value)
}

// ---------------------------------------------------------------------------
// Command builders.

function binaryArgv(settings) {
  var custom = settings && settings.binaryPath !== undefined && settings.binaryPath !== null
    ? String(settings.binaryPath).trim() : ""
  return custom !== "" && isSafeBinaryPath(custom) ? [custom] : ["sail-proxy"]
}

// `status --json` exits 0 even when the proxy is off, so state always comes
// from the parsed `active` field and never from an exit code. A missing binary
// is the one thing the exit code does say: the guard runs argv through bash,
// which reports 127.
function statusCommand(argv) {
  var base = Array.isArray(argv) && argv.length > 0 ? argv : ["sail-proxy"]
  return boundedCaptureCommand(base.concat(["status", "--json"]),
    cliResponseByteLimit, cliErrorByteLimit, statusTimeoutSec)
}

function startCommand(argv) {
  var base = Array.isArray(argv) && argv.length > 0 ? argv : ["sail-proxy"]
  return boundedCaptureCommand(base.concat(["start"]),
    cliErrorByteLimit, cliErrorByteLimit, actionTimeoutSec)
}

function stopCommand(argv) {
  var base = Array.isArray(argv) && argv.length > 0 ? argv : ["sail-proxy"]
  return boundedCaptureCommand(base.concat(["stop", "--brief"]),
    cliErrorByteLimit, cliErrorByteLimit, actionTimeoutSec)
}

// Run in a visible terminal, not captured: `install` pulls an image, which is
// both slower than any sane deadline and worth watching.
function installCommand(argv) {
  var base = Array.isArray(argv) && argv.length > 0 ? argv : ["sail-proxy"]
  return base.concat(["install"])
}

// Always -n. An unregister that stops to ask a question in a subprocess with
// no terminal would hang until the deadline killed it.
function unregisterCommand(argv, service) {
  if (!isSafeServiceName(service)) return []
  var base = Array.isArray(argv) && argv.length > 0 ? argv : ["sail-proxy"]
  return boundedCaptureCommand(base.concat(["unregister", service, "-n"]),
    cliErrorByteLimit, cliErrorByteLimit, actionTimeoutSec)
}

// omarchy-launch-tui takes a command, not a directory, so the terminal case
// changes into the directory and hands over to the user's shell.
function openDirectoryCommand(action, dir) {
  if (!isSafeDirectory(dir)) return []
  if (action === "editor") return ["omarchy-launch-editor", dir]
  if (action === "terminal") return terminalCommand(dir)
  return ["xdg-open", dir]
}

// The directory is passed as an argument, never spliced into the script, so a
// path with a quote or a space in it is still one path.
function terminalCommand(dir) {
  if (!isSafeDirectory(dir)) return []
  return ["omarchy-launch-tui", "--app-id=org.omarchy.sail-proxy", "bash", "-lc",
    "cd -- \"$1\" || exit 1; exec \"${SHELL:-bash}\"", "sail-proxy", dir]
}

// printf rather than echo: a path beginning with -n or containing a backslash
// would otherwise be interpreted rather than copied. wl-copy is what the
// shell's own panels use.
function copyDirectoryCommand(dir) {
  if (!isSafeDirectory(dir)) return []
  return ["bash", "-c", "printf %s " + shellQuote(dir) + " | wl-copy"]
}

function browserUrl(project) {
  if (!project || !isSafeHost(project.host)) return ""
  return (project.tls === "yes" ? "https://" : "http://") + project.host
}

// omarchy-launch-browser opens the default browser *and* focuses its window,
// which a bare xdg-open does not.
function browserCommand(project) {
  var url = browserUrl(project)
  return url === "" ? [] : ["omarchy-launch-browser", url]
}

// ---------------------------------------------------------------------------
// Parsing.

function statusFailure(message) {
  return { ok: false, installed: false, active: false, projects: [],
    hasInstalledKey: false, error: message }
}

function parseStatus(stdout) {
  var raw = String(stdout || "")
  if (exceedsUtf8ByteLimit(raw, cliResponseByteLimit)) {
    return statusFailure("The sail-proxy response exceeded its size limit")
  }
  var text = raw.trim()
  if (text === "") return statusFailure("sail-proxy returned no data")

  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (error) {
    return statusFailure("Could not parse the sail-proxy response")
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return statusFailure("sail-proxy returned invalid data")
  }

  var rows = Array.isArray(parsed.projects) ? parsed.projects : []
  var projects = []
  for (var i = 0; i < rows.length && projects.length < maximumProjectCount; i++) {
    var project = normalizeProject(rows[i])
    if (project !== null) projects.push(project)
  }

  return {
    ok: true,
    // Read straight from the JSON. Never inferred from `active` — a proxy that
    // is installed but stopped is a different state from one never installed,
    // and they get different bodies.
    installed: parsed.installed === true,
    active: parsed.active === true,
    projects: projects,
    hasInstalledKey: Object.prototype.hasOwnProperty.call(parsed, "installed"),
    error: ""
  }
}

// Capability, not a version string, is the gate: a CLI old enough to lack the
// `installed` key cannot answer what the widget needs, whatever --version says.
function cliOutdated(parsed) {
  return !!parsed && parsed.ok === true && parsed.hasInstalledKey !== true
}

// Primitives only. QML bindings re-read these on every repaint, so nothing
// here may be a getter, a Date, or a reference back into the parsed JSON.
function normalizeProject(raw) {
  if (!raw || typeof raw !== "object") return null
  var service = cleanText(raw.service, serviceNameCharacterLimit)
  var host = cleanText(raw.host, hostCharacterLimit)
  if (!isSafeServiceName(service) || !isSafeHost(host)) return null

  var dir = typeof raw.dir === "string" && isSafeDirectory(raw.dir) ? raw.dir : ""
  var project = {
    service: service,
    host: host,
    container: cleanText(raw.container, serviceNameCharacterLimit),
    target: cleanText(raw.target, hostCharacterLimit),
    tls: raw.tls === "yes" ? "yes" : "no",
    exists: raw.exists === true,
    dir: dir,
    hasDir: dir !== "",
    running: containerRunning(raw)
  }
  project.url = browserUrl(project)
  return project
}

// `exists` is docker inspect succeeding, which is true for a stopped container
// too — so a stopped-but-present container reads as running. `state` cannot
// help: it is kamal-proxy's service pause state and outlives the container.
// A real `running` key is preferred if one ever appears, so the plugin
// sharpens itself with no UI change.
function containerRunning(project) {
  if (!project || typeof project !== "object") return false
  if (typeof project.running === "boolean") return project.running
  return project.exists === true
}

function homeRelative(dir, home) {
  var path = String(dir || "")
  var base = String(home || "")
  if (path === "" || base === "") return path
  if (path === base) return "~"
  if (path.indexOf(base + "/") === 0) return "~" + path.substring(base.length)
  return path
}

// Stable and alphabetical by host: rows must not jump under the cursor when a
// refresh lands mid-hover. The index tiebreak keeps equal hosts in input order
// without relying on the engine's sort being stable.
function sortProjects(rows) {
  var source = Array.isArray(rows) ? rows : []
  var decorated = []
  for (var i = 0; i < source.length; i++) {
    if (source[i]) decorated.push({ index: i, row: source[i] })
  }
  decorated.sort(function (left, right) {
    var a = String(left.row.host || "")
    var b = String(right.row.host || "")
    if (a < b) return -1
    if (a > b) return 1
    return left.index - right.index
  })
  var result = []
  for (var j = 0; j < decorated.length; j++) result.push(decorated[j].row)
  return result
}

function indexOfService(rows, service) {
  var source = Array.isArray(rows) ? rows : []
  for (var i = 0; i < source.length; i++) {
    if (source[i] && source[i].service === service) return i
  }
  return -1
}

// A failed `start` says this when the proxy was never installed. The status
// JSON's `installed` key is the real signal; this is the backstop for a CLI
// that answered an action but not a status.
function notInstalledError(text) {
  return /proxy is not installed/i.test(String(text || ""))
}

// ---------------------------------------------------------------------------
// Presentation.

function bodyState(setupNeeded, installed, proxyOn, rowCount) {
  if (setupNeeded === true) return "setup"
  if (installed !== true) return "not-installed"
  if (proxyOn !== true) return "stopped"
  return positiveInteger(rowCount, 0) > 0 ? "list" : "empty"
}

function heroMeta(state) {
  var view = state || {}
  if (view.cliInstalled === false || view.cliOutdated === true) return "CLI UNAVAILABLE"
  if (view.installed !== true) return "NOT INSTALLED"
  if (view.proxyOn !== true) return "STOPPED"
  var count = positiveInteger(view.rowCount, 0)
  if (count === 0) return "NO APPS REGISTERED"
  return count === 1 ? "1 APP REGISTERED" : String(count) + " APPS REGISTERED"
}

function barTooltip(state) {
  var view = state || {}
  if (view.cliInstalled === false) return "Sail Proxy — CLI not installed"
  if (view.cliOutdated === true) return "Sail Proxy — CLI needs updating"
  if (view.installed !== true) return "Sail Proxy — not installed"
  if (view.proxyOn !== true) return "Sail Proxy — stopped"
  var count = positiveInteger(view.rowCount, 0)
  if (count === 0) return "Sail Proxy — running, no apps registered"
  var suffix = count === 1 ? "1 app" : String(count) + " apps"
  var down = positiveInteger(view.stoppedCount, 0)
  return "Sail Proxy — running, " + suffix + (down > 0 ? ", " + String(down) + " not running" : "")
}

// The reason sits where the path would be when there is no path: a row that
// says nothing about why its folder button is dead is worse than no row.
function rowSubtitle(project, home) {
  if (!project) return ""
  var liveness = project.running ? "running" : "not running"
  if (!project.hasDir) {
    return project.running
      ? "Directory unknown · " + liveness
      : "Container is gone · " + liveness
  }
  return homeRelative(project.dir, home) + " · " + liveness
}

function stoppedCount(rows) {
  var source = Array.isArray(rows) ? rows : []
  var count = 0
  for (var i = 0; i < source.length; i++) {
    if (source[i] && source[i].running !== true) count++
  }
  return count
}

if (typeof module !== "undefined") {
  module.exports = {
    setupLockShell: setupLockShell,
    setupLockCheckCommand: setupLockCheckCommand,
    setupLaunchCommand: setupLaunchCommand,
    setupPlan: setupPlan,
    setupFix: setupFix,
    shellQuote: shellQuote,
    boundedCaptureScript: boundedCaptureScript,
    boundedCaptureCommand: boundedCaptureCommand,
    capturedCommandPayload: capturedCommandPayload,
    exceedsUtf8ByteLimit: exceedsUtf8ByteLimit,
    boundedString: boundedString,
    cleanText: cleanText,
    isSafeServiceName: isSafeServiceName,
    isSafeHost: isSafeHost,
    isSafeDirectory: isSafeDirectory,
    isSafeBinaryPath: isSafeBinaryPath,
    binaryArgv: binaryArgv,
    statusCommand: statusCommand,
    startCommand: startCommand,
    stopCommand: stopCommand,
    installCommand: installCommand,
    unregisterCommand: unregisterCommand,
    openDirectoryCommand: openDirectoryCommand,
    terminalCommand: terminalCommand,
    copyDirectoryCommand: copyDirectoryCommand,
    browserUrl: browserUrl,
    browserCommand: browserCommand,
    parseStatus: parseStatus,
    cliOutdated: cliOutdated,
    normalizeProject: normalizeProject,
    containerRunning: containerRunning,
    homeRelative: homeRelative,
    sortProjects: sortProjects,
    indexOfService: indexOfService,
    notInstalledError: notInstalledError,
    bodyState: bodyState,
    heroMeta: heroMeta,
    barTooltip: barTooltip,
    rowSubtitle: rowSubtitle,
    stoppedCount: stoppedCount,
    maximumProjectCount: maximumProjectCount
  }
}
