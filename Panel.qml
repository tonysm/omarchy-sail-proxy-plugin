import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "tonysm.sail-proxy"
  ipcTarget: "tonysm.sail-proxy"
  manageIpc: false

  // ---- cursor state --------------------------------------------------------
  //
  // Per the CursorSurface contract, rows never read their own containsMouse
  // for color. Hover writes these, and every visual derives from them, so the
  // keyboard and the mouse share one highlight.
  property int selectedIndex: 0
  property bool cursorActive: false
  // 0 = the row itself, then its buttons left to right:
  // 1 folder, 2 terminal, 3 copy, 4 unregister.
  property int actionColumn: 0
  readonly property int lastActionColumn: 4
  readonly property bool actionFocused: actionColumn !== 0

  // The row whose path was just copied, so its button can acknowledge.
  property string copiedService: ""

  // The armed unregister lives here, not on the row: rows are recreated on
  // every refresh, so row-local state would be lost between the arming click
  // and the confirming one.
  property string armedService: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Color.accent)
    : Style.hoverFillFor(Color.foreground, Color.accent)
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Color.accent)
    : Style.selectedFillFor(Color.foreground, Color.accent)

  // One service per shell: the shell instantiates Service.qml once and every
  // bar widget — one per monitor — reads that instance, so the CLI is polled
  // once however many bars there are. A shell without service support gets a
  // widget-local instance instead.
  readonly property var sharedService: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  readonly property var service: sharedService || localService

  readonly property var rows: Model.sortProjects(service.projects)
  readonly property int rowCount: rows.length

  readonly property var setupPlan: Model.setupPlan(service.cliInstalled, service.cliOutdated, ipcTarget)
  // Nothing is claimed about the CLI until the first status has actually run.
  readonly property bool needsSetup: service.probed && setupPlan.needed
  readonly property string body: Model.bodyState(needsSetup, service.installed, service.proxyOn, rowCount)

  readonly property var heroState: ({
    cliInstalled: service.cliInstalled,
    cliOutdated: service.cliOutdated,
    installed: service.installed,
    proxyOn: service.proxyOn,
    rowCount: rowCount,
    stoppedCount: service.stoppedCount
  })

  // The shell injects settings into widgets, not services: push them across.
  function pushSettings() { if (service) service.settings = settings }
  onSettingsChanged: pushSettings()
  onServiceChanged: pushSettings()
  Component.onCompleted: pushSettings()

  function refreshService() { service.refresh() }

  // With the service shared, one refresh is the refresh. Under a shell without
  // service support each monitor's bar holds its own, so a refresh asked for
  // over IPC is fanned out to every live one.
  function broadcastRefresh() {
    if (sharedService) {
      sharedService.refresh()
      return
    }
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) {
      if (items[i] && typeof items[i].refreshService === "function") items[i].refreshService()
    }
  }

  function broadcastSetupFinished() {
    if (sharedService) {
      sharedService.setupFinished()
      return
    }
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i].service) items[i].service.setupFinished()
    }
  }

  // ---- the armed unregister ------------------------------------------------

  function disarm() {
    armedService = ""
    disarmTimer.stop()
  }

  function armOrConfirm(name) {
    if (!Model.isSafeServiceName(name)) return
    if (armedService === name) {
      disarm()
      service.unregister(name)
      return
    }
    armedService = name
    disarmTimer.restart()
  }

  // A refresh that removes the armed row takes the arming with it, so a
  // confirming click can never land on a row that has become something else.
  function syncArmed() {
    if (armedService === "") return
    if (Model.indexOfService(rows, armedService) === -1) disarm()
  }

  onRowsChanged: {
    syncArmed()
    if (selectedIndex >= rowCount) selectedIndex = Math.max(0, rowCount - 1)
  }

  // Moving the cursor to a *different* row disarms. Moving between a row and
  // its own buttons changes only actionColumn, which is not watched here, so
  // the second click cannot be lost that way.
  onSelectedIndexChanged: {
    if (armedService === "") return
    var current = rows[selectedIndex]
    if (!current || current.service !== armedService) disarm()
  }

  // ---- row actions ---------------------------------------------------------

  function openRow(project) {
    var command = Model.browserCommand(project)
    if (command.length === 0) return
    Quickshell.execDetached(command)
    close()
  }

  function openFolder(project) {
    if (!project || !project.hasDir) return
    var command = Model.openDirectoryCommand(service.folderAction, project.dir)
    if (command.length === 0) return
    Quickshell.execDetached(command)
    close()
  }

  function openTerminal(project) {
    if (!project || !project.hasDir) return
    var command = Model.terminalCommand(project.dir)
    if (command.length === 0) return
    Quickshell.execDetached(command)
    close()
  }

  // Copying is a glance-and-go action — the popup stays open, and the button
  // acknowledges with a check so there is some sign it happened.
  function copyDirectory(project) {
    if (!project || !project.hasDir) return
    var command = Model.copyDirectoryCommand(project.dir)
    if (command.length === 0) return
    Quickshell.execDetached(command)
    copiedService = project.service
    copiedTimer.restart()
  }

  // ---- launching a visible terminal ---------------------------------------

  function launchSetup() {
    if (!bar || service.setupRunning) return
    bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(setupPlan.launchCommand))
    close()
  }

  // `install` creates the network and pulls the proxy image — slower than any
  // sane capture deadline, and worth watching.
  //
  // The launcher re-parses its argument as a shell command, so each element is
  // quoted before joining: a custom binaryPath containing a space is a path,
  // not two words.
  function launchInstall() {
    if (!bar) return
    var command = Model.installCommand(service.binaryArgv())
    var line = []
    for (var i = 0; i < command.length; i++) line.push(Util.shellQuote(command[i]))
    bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(line.join(" ")))
    close()
  }

  // ---- keyboard ------------------------------------------------------------

  function moveSelection(delta) {
    if (rowCount === 0) return
    if (!cursorActive) {
      cursorActive = true
      actionColumn = 0
      return
    }
    var next = selectedIndex + delta
    if (next < 0) next = rowCount - 1
    if (next >= rowCount) next = 0
    selectedIndex = next
    actionColumn = 0
  }

  // Folder, terminal and copy all need a directory; the row and the unregister
  // button work regardless.
  function columnEnabled(column, project) {
    if (column === 0 || column === lastActionColumn) return true
    return !!project && project.hasDir === true
  }

  function moveColumn(delta) {
    if (rowCount === 0 || !cursorActive || delta === 0) return
    var current = rows[selectedIndex]
    var next = actionColumn
    // Step over the directory buttons on a row that has no directory, rather
    // than landing on one that cannot be activated.
    for (var i = 0; i <= lastActionColumn; i++) {
      next += delta
      if (next < 0 || next > lastActionColumn) return
      if (columnEnabled(next, current)) {
        actionColumn = next
        return
      }
    }
  }

  function activateSelection() {
    if (rowCount === 0 || !cursorActive) return
    var current = rows[selectedIndex]
    if (!current) return
    if (actionColumn === 4) armOrConfirm(current.service)
    else if (actionColumn === 3) copyDirectory(current)
    else if (actionColumn === 2) openTerminal(current)
    else if (actionColumn === 1) openFolder(current)
    else openRow(current)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (!opened) {
      disarm()
      copiedService = ""
      copiedTimer.stop()
      cursorActive = false
      actionColumn = 0
      // Two open popups must not have the second close drop the first back to
      // slow polling, so the service counts holders rather than flipping a bool.
      service.releaseFastPoll()
      return
    }
    cursorActive = false
    actionColumn = 0
    selectedIndex = 0
    pointerGate.reset()
    if (listFlick) listFlick.contentY = 0
    service.retainFastPoll()
    service.checkSetupLock()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  Timer {
    id: disarmTimer
    interval: 4000
    repeat: false
    onTriggered: root.disarm()
  }

  Timer {
    id: copiedTimer
    interval: 1400
    repeat: false
    onTriggered: root.copiedService = ""
  }

  // Filters the synthetic hover events Qt delivers when the list re-layouts
  // under a pointer that never moved.
  PointerMoveGate {
    id: pointerGate
    referenceItem: listFlick
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        SailIcon {
          id: barIcon
          anchors.centerIn: parent
          iconSize: Style.space(12)
          // Off is dim rather than hidden: still visible, still clickable, so
          // the popup can be opened to start the proxy.
          color: service.proxyOn ? root.foreground : root.dim
        }

        Rectangle {
          // Something is registered but its container is gone.
          visible: service.proxyOn && service.stoppedCount > 0
          width: Style.space(5)
          height: width
          radius: width / 2
          color: root.urgent
          anchors.right: barIcon.right
          anchors.top: barIcon.top
          anchors.rightMargin: -Style.space(1)
          anchors.topMargin: -Style.space(1)
        }
      }
    }
    tooltipText: Model.barTooltip(root.heroState)
    onPressed: function (code) {
      if (code === Qt.RightButton || code === Qt.MiddleButton) service.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function (dx, dy) {
        if (dx !== 0) root.moveColumn(dx)
        else if (dy !== 0) root.moveSelection(dy)
      }
      onActivateRequested: root.activateSelection()
      onCloseRequested: {
        // Escape backs out of an armed unregister before it closes the popup.
        if (root.armedService !== "") root.disarm()
        else root.close()
      }
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (text) {
        var key = String(text || "").toLowerCase()
        if (key === "j") root.moveSelection(1)
        else if (key === "k") root.moveSelection(-1)
        else if (key === "h") root.moveColumn(-1)
        else if (key === "l") root.moveColumn(1)
        else if (key === "r") service.refresh()
        else if (key === "s") { if (service.installed && !root.needsSetup) service.toggle() }
        else if (key === "o") {
          if (root.cursorActive && root.rowCount > 0) root.openFolder(root.rows[root.selectedIndex])
        } else if (key === "t") {
          if (root.cursorActive && root.rowCount > 0) root.openTerminal(root.rows[root.selectedIndex])
        } else if (key === "c") {
          if (root.cursorActive && root.rowCount > 0) root.copyDirectory(root.rows[root.selectedIndex])
        } else if (key === "x") {
          if (root.cursorActive && root.rowCount > 0) {
            var current = root.rows[root.selectedIndex]
            if (current) root.armOrConfirm(current.service)
          }
        }
      }

      ColumnLayout {
        id: content
        anchors.fill: parent
        spacing: Style.space(12)

        PanelHero {
          id: hero
          Layout.fillWidth: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          title: "Sail Proxy"
          meta: Model.heroMeta(root.heroState)
          detail: service.lastError
          iconOpacity: service.proxyOn ? 1.0 : 0.45
          iconComponent: Component {
            SailIcon {
              iconSize: Style.font.display
              color: root.foreground
            }
          }
          trailingControl: Component {
            Row {
              spacing: Style.space(8)

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰑐"
                tooltipText: "Refresh"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !service.refreshing
                onClicked: service.refresh()
              }

              ToggleSwitch {
                anchors.verticalCenter: parent.verticalCenter
                checked: service.proxyOn
                busy: service.toggling
                foreground: root.foreground
                // The proxy has to exist before it can be started, and the CLI
                // has to work before either.
                enabled: service.installed && !root.needsSetup
                onToggled: service.toggle()
              }
            }
          }
        }

        // -- setup: the CLI is missing or too old to answer -------------------
        ColumnLayout {
          Layout.fillWidth: true
          visible: root.body === "setup"
          spacing: Style.space(10)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: root.setupPlan.title
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: root.setupPlan.detail
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          // The exact command, so it can be read and copied rather than taken
          // on faith before it runs.
          TextEdit {
            Layout.fillWidth: true
            text: root.setupPlan.command
            color: root.dim
            font.family: "monospace"
            font.pixelSize: Style.font.bodySmall
            wrapMode: TextEdit.WrapAnywhere
            readOnly: true
            selectByMouse: true
          }

          Button {
            Layout.fillWidth: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            text: service.setupRunning ? "Setup is already running" : root.setupPlan.buttonLabel
            enabled: !service.setupRunning && !service.setupChecking
            onClicked: root.launchSetup()
          }
        }

        // -- the proxy itself was never installed -----------------------------
        ColumnLayout {
          Layout.fillWidth: true
          visible: root.body === "not-installed"
          spacing: Style.space(10)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: "The proxy is not installed"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: "Installing creates the proxy network and container. Your Sail apps register with it afterwards."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Button {
            Layout.fillWidth: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            text: "Install the proxy…"
            onClicked: root.launchInstall()
          }
        }

        // -- installed, but stopped -------------------------------------------
        ColumnLayout {
          Layout.fillWidth: true
          visible: root.body === "stopped"
          spacing: Style.space(6)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: "The proxy is stopped"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: "Registrations are kept while it is off. Use the switch above to start it."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
        }

        // -- running, nothing registered --------------------------------------
        ColumnLayout {
          Layout.fillWidth: true
          visible: root.body === "empty"
          spacing: Style.space(6)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: "No apps registered"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: "Run sail-proxy register in a Sail project to serve it at its own hostname."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
        }

        // -- the list ----------------------------------------------------------
        Flickable {
          id: listFlick
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: root.body === "list"
          implicitHeight: rowColumn.implicitHeight
          contentHeight: rowColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: rowColumn
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.rows

              ProjectRow {
                required property var modelData
                required property int index
                width: rowColumn.width
                project: modelData
                rowIndex: index
              }
            }
          }
        }
      }
    }
  }

  component ProjectRow: CursorSurface {
    id: row
    required property var project
    required property int rowIndex

    readonly property bool rowSelected: root.cursorActive && root.selectedIndex === rowIndex
    readonly property bool armed: root.armedService === project.service
    readonly property bool copied: root.copiedService === project.service
    readonly property bool acting: root.service.pendingAction === project.service

    // The row surface highlights only when the cursor is on the row itself,
    // not when it has moved onto one of the row's buttons.
    hasCursor: rowSelected && !root.actionFocused
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor

      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.selectedIndex = row.rowIndex
        root.actionColumn = 0
      }
      onClicked: root.openRow(row.project)
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(statusDot.implicitHeight, info.implicitHeight, actions.implicitHeight)

      Rectangle {
        id: statusDot
        width: Style.space(7)
        height: width
        radius: width / 2
        // Running is the affirmative state, so it gets the affirmative color:
        // the theme's accent, which is what the shell uses everywhere else to
        // mean active. Gone is the same dot, muted.
        //
        // Deliberately not `urgent` for the gone state. A theme is free to map
        // urgent to anything — this one defines `red` as #50f872, a green — and
        // an alert color that reads as "healthy" would put the loudest mark on
        // the broken row. Brightness is the signal instead, so it holds up on
        // any palette.
        color: row.project.running ? Color.accent : root.dim
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        implicitHeight: width
      }

      Column {
        id: info
        spacing: Style.space(1)
        anchors.left: statusDot.right
        anchors.leftMargin: Style.space(10)
        anchors.right: actions.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: row.project.host
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: row.armed
            ? "Unregister " + row.project.service + "? Click again."
            : Model.rowSubtitle(row.project, root.service.home)
          color: row.armed ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          // The reason a folder button is dead reads as an aside, not as data.
          font.italic: !row.armed && !row.project.hasDir
          elide: Text.ElideRight
        }
      }

      Row {
        id: actions
        spacing: Style.space(2)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        PanelActionButton {
          iconText: "󰉋"
          tooltipText: row.project.hasDir ? "Open folder" : "No directory for this container"
          foreground: root.foreground
          fontFamily: root.fontFamily
          // Disabled rather than hidden, so the row layout does not shift
          // between a row that has a directory and one that does not.
          enabled: row.project.hasDir
          hasCursor: row.rowSelected && root.actionColumn === 1
          onClicked: root.openFolder(row.project)
          onHovered: function (isHovered) {
            if (!isHovered) return
            root.cursorActive = true
            root.selectedIndex = row.rowIndex
            root.actionColumn = 1
          }
        }

        PanelActionButton {
          iconText: "󰆍"
          tooltipText: row.project.hasDir ? "Open in terminal" : "No directory for this container"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: row.project.hasDir
          hasCursor: row.rowSelected && root.actionColumn === 2
          onClicked: root.openTerminal(row.project)
          onHovered: function (isHovered) {
            if (!isHovered) return
            root.cursorActive = true
            root.selectedIndex = row.rowIndex
            root.actionColumn = 2
          }
        }

        PanelActionButton {
          iconText: row.copied ? "󰄬" : "󰆏"
          tooltipText: row.project.hasDir
            ? (row.copied ? "Copied" : "Copy path")
            : "No directory for this container"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: row.project.hasDir
          hasCursor: row.rowSelected && root.actionColumn === 3
          onClicked: root.copyDirectory(row.project)
          onHovered: function (isHovered) {
            if (!isHovered) return
            root.cursorActive = true
            root.selectedIndex = row.rowIndex
            root.actionColumn = 3
          }
        }

        PanelActionButton {
          // The square stays the same size in the same place between the
          // arming click and the confirming one — only the glyph changes.
          iconText: row.armed ? "󰄬" : "󰩹"
          tooltipText: row.armed ? "Confirm unregister" : "Unregister"
          foreground: row.armed ? root.urgent : root.foreground
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          enabled: !row.acting
          hasCursor: row.rowSelected && root.actionColumn === 4
          onClicked: root.armOrConfirm(row.project.service)
          onHovered: function (isHovered) {
            if (!isHovered) return
            root.cursorActive = true
            root.selectedIndex = row.rowIndex
            root.actionColumn = 4
          }
        }
      }
    }
  }

  // Only one handler per target is permitted, so with one Panel per monitor
  // the extras are inert; refresh and setupFinished fan out to every instance.
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.broadcastRefresh(); return "ok" }
    // Called by the setup terminal's EXIT trap, so it has to work with the
    // popup closed and on whichever monitor happens to own the handler.
    function setupFinished(): void { root.broadcastSetupFinished() }
    function status(): string {
      return JSON.stringify({
        cliInstalled: service.cliInstalled,
        cliOutdated: service.cliOutdated,
        installed: service.installed,
        proxyOn: service.proxyOn,
        body: root.body,
        projects: root.rowCount,
        stopped: service.stoppedCount,
        refreshing: service.refreshing,
        error: service.lastError
      })
    }
  }

  Service {
    id: localService
    active: root.sharedService === null
  }
}
