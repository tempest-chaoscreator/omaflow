import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "CcMap.js" as Cc
import "Marks.js" as Marks
import "RepoPath.js" as Repo
import "Model.js" as Model
import "Nav.js" as Nav
import "Wheel.js" as Wheel

// Omaflow Plugin. Monitoring and the selected mode. Curve edits stay in
// Omaflow. Choosing a mode does not run it. Apply does.
// omarchy-shell omaflow <command> reaches the handler further down.
// Those calls are the ones a deck key can bind later.
Panel {
  id: root
  moduleName: "tempest-chaoscreator.omaflow"
  ipcTarget: "omaflow"
  manageIpc: false

  readonly property var service: (bar && bar.shell && typeof bar.shell.serviceFor === "function")
    ? bar.shell.serviceFor(root.moduleName) : null
  readonly property string connection: service ? String(service.connection || "down") : "down"
  readonly property bool ready: connection === "ready"
  readonly property string daemonGate: service ? String(service.daemonGate || "unknown") : "unknown"
  readonly property bool showPair: daemonGate === "up" && (connection === "need-token" || connection === "unauthorized")
  readonly property var modes: service && service.modes ? service.modes : []
  readonly property string activeModeUid: service ? String(service.activeModeUid || "") : ""
  readonly property string activeModeName: service ? String(service.activeModeName || "") : ""
  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color accent: Commons.Color.accent
  readonly property color line: Qt.rgba(fg.r, fg.g, fg.b, 0.22)
  readonly property color rule: Qt.rgba(fg.r, fg.g, fg.b, 0.16)
  readonly property real hottest: {
    var sample = service && service.temps ? service.temps : null
    // Number(null) is 0. A missing sensor must stay missing, while a real 0° stays 0.
    if (!sample || sample.hottest === null || sample.hottest === undefined || sample.hottest === "") return NaN
    var n = Number(sample.hottest)
    return isFinite(n) ? n : NaN
  }
  readonly property string alertLine: ready && service ? Cc.activeAlertLine(service.alerts) : ""
  readonly property string alertTip: {
    if (!ready || !service) return ""
    var names = Cc.activeAlertNames(service.alerts)
    return names.length ? (" · " + names.join(" · ")) : ""
  }
  readonly property string openPath: Repo.rootFile("scripts/open_app.sh")
  // Same side inset as Network, Bluetooth, and Display. The temperature
  // keeps this chip wider. The gap to the next chip stays that inset.
  readonly property real chipPad: Math.max(0, (Style.bar.iconSlot - Style.bar.iconCanvas) / 2)
  readonly property real chipMargin: {
    var scale = Style.spacing.scale
    return scale > 0 ? chipPad / scale : 0
  }

  property string tab: "monitor"
  property string modeUid: ""
  // A click previews a mode. Until that happens, the row follows the running one.
  property bool modePicked: false
  property int navIndex: 0

  readonly property var mode: {
    for (var i = 0; i < modes.length; i++) if (modes[i].uid === modeUid) return modes[i]
    return null
  }
  readonly property bool modeApplied: mode && mode.uid === activeModeUid
  readonly property bool calibrationBusy: !!(service && service.calibrationBusy)
  readonly property int modeH: Style.space(32)
  readonly property var navItems: {
    var out = []
    if (!ready) {
      if (showPair) out.push({ kind: "pair", x: 0, y: 0 })
      else if (daemonGate === "install") out.push({ kind: "install", x: 0, y: 0 })
      else if (daemonGate === "start") out.push({ kind: "start", x: 0, y: 0 })
      out.push({ kind: "open", x: 0, y: out.length })
      return out
    }
    out = [
      { kind: "tab", id: "monitor", x: 0, y: 0 },
      { kind: "tab", id: "mode", x: 1, y: 0 }
    ]
    for (var i = 0; i < modes.length; i++) out.push({ kind: "mode", uid: modes[i].uid, x: i, y: 1 })
    if (mode) out.push({ kind: "apply", x: modes.length, y: 1 })
    out.push({ kind: "open", x: 0, y: 2 })
    return out
  }

  function tempText(value) {
    if (value === null || value === undefined || value === "") return "—"
    var n = Number(value)
    return isFinite(n) ? Math.round(n) + "°" : "—"
  }

  // Own process. Summoning the panel loads it inside the bar, which
  // rescales the shell and closes the window on `omarchy restart shell`.
  // Close the chip first so the app takes the keyboard as soon as it focuses.
  function openStandalone() {
    root.close()
    if (launchWindow.running) return
    launchWindow.running = true
  }

  function ensureMode() {
    if (modePicked && modeUid && mode) return
    if (activeModeUid) modeUid = activeModeUid
    else if (!modeUid && modes.length) modeUid = modes[0].uid
  }

  function pickMode(uid) {
    modePicked = true
    modeUid = uid
  }

  function navAt() {
    return navItems.length ? navItems[Math.max(0, Math.min(navItems.length - 1, navIndex))] : null
  }

  function moveNav(dx, dy) {
    navIndex = Nav.step(navItems, navIndex, dx, dy)
  }

  function submitPair() {
    var password = pairPassword.text
    pairPassword.text = ""
    if (service) service.pair(password)
  }

  function activateNav() {
    var item = navAt()
    if (!item) return
    if (item.kind === "pair") submitPair()
    else if (item.kind === "tab") tab = item.id
    else if (item.kind === "mode") pickMode(item.uid)
    else if (item.kind === "apply") applySelected()
    else if (item.kind === "install" && service) service.installDaemon()
    else if (item.kind === "start" && service) service.startDaemon()
    else if (item.kind === "open") openStandalone()
  }

  function aim(kind, id) {
    var item = navAt()
    if (!popup.open || !item || item.kind !== kind) return false
    if (kind === "tab") return item.id === id
    if (kind === "mode") return item.uid === id
    return true
  }

  // Null when the mode has no channels. An empty list still runs the mode.
  function jobsFor(mode) {
    var members = Cc.modeMembers(mode, service.channels, service.profiles)
    if (!members.length) return null
    var jobs = []
    var seen = ({})
    var i
    for (i = 0; i < members.length; i++) {
      var row = members[i]
      if (!row.profileUid || seen[row.profileUid]) continue
      if (!row.points || row.points.length < 2) continue
      seen[row.profileUid] = true
      jobs.push({ profileUid: row.profileUid, points: row.points, minDuty: row.minDuty || 0 })
    }
    return jobs
  }

  function applySelected() {
    if (!service || !mode) return
    var jobs = jobsFor(mode)
    if (!jobs) {
      service.lastError = mode.name + " has no channels. Add one in Omaflow before applying."
      return
    }
    service.lastError = ""
    service.applyModeCurves(mode.uid, jobs)
  }

  // Deck commands. Each one is zero-argument. An action prints ok, or one
  // line when it cannot run. A status command prints one line.
  function runMode(mode) {
    if (!service || connection !== "ready") return "coolercontrold is not connected."
    if (!mode) return "That mode is not on this cooler."
    if (service.calibrationBusy) return "A fan is being calibrated. Apply waits until that sweep finishes."
    if (String(mode.uid || "") === activeModeUid) return "ok"
    var jobs = jobsFor(mode)
    if (!jobs) return String(mode.name || "This mode") + " has no channels. Add one in Omaflow before applying."
    service.lastError = ""
    service.applyModeCurves(mode.uid, jobs)
    return "ok"
  }

  function runNamed(label) {
    if (!service || connection !== "ready") return "coolercontrold is not connected."
    var mode = Cc.modeNamed(modes, label)
    if (!mode) return label + " is not on this cooler."
    return runMode(mode)
  }

  // The one mode besides Silent, Performance, Fixed, and Hell.
  function runCustom() {
    if (!service || connection !== "ready") return "coolercontrold is not connected."
    var defaults = { silent: true, performance: true, fixed: true, hell: true }
    var found = []
    var list = modes || []
    var i
    for (i = 0; i < list.length; i++) {
      var item = list[i]
      if (!item) continue
      var key = String(item.name || "").replace(/^\s+|\s+$/g, "").toLowerCase()
      if (!key || defaults[key]) continue
      found.push(item)
    }
    if (!found.length) return "No custom mode."
    if (found.length > 1) return "More than one custom mode."
    return runMode(found[0])
  }

  function showFace(face) {
    if (!service || !service.showLcd) return "coolercontrold is not connected."
    return service.showLcd(face)
  }

  function lcdLabel(face) {
    if (face === "cpu") return "CPU"
    if (face === "cpu-gpu") return "CPU | GPU"
    if (face === "cpu-liquid") return "CPU | Liquid"
    if (face === "omarchy") return "Omarchy"
    if (face === "omarchy-time") return "Omarchy | Time"
    if (face === "picture") return "Picture"
    return "Liquid"
  }

  function modeLine() {
    if (!ready) return "coolercontrold is not connected."
    return activeModeName || "No mode"
  }

  function lcdLine() {
    if (!ready) return "coolercontrold is not connected."
    var screens = service && service.lcdChannels ? service.lcdChannels : []
    if (!screens.length) return "No AIO LCD."
    if (service.lcdLive === false) return "LCD off"
    return lcdLabel(service.lcdFace)
  }

  function tempLine() {
    if (!ready) return "coolercontrold is not connected."
    if (!isFinite(hottest)) return "No temperature"
    return Math.round(hottest) + "°"
  }

  function pumpLine() {
    if (!ready) return "coolercontrold is not connected."
    var sample = service && service.temps ? service.temps : ({})
    var duty = Cc.finiteNum(sample.pumpDuty)
    var rpm = Cc.finiteNum(sample.pumpRpm)
    if (duty === null && rpm === null) return "No pump"
    var dutyText = duty === null ? "—" : Math.round(duty) + "%"
    var rpmText = rpm === null ? "— rpm" : Math.round(rpm) + " rpm"
    return "Pump " + dutyText + " · " + rpmText
  }

  function alertsLine() {
    if (!ready) return "coolercontrold is not connected."
    var names = Cc.activeAlertNames(service.alerts)
    if (!names.length) return "No alerts"
    return names.join(" · ")
  }

  function selectAt(index) {
    if (index < 0 || index >= modes.length) return
    pickMode(modes[index].uid)
  }

  component TabFace: Rectangle {
    id: face
    property string tabId: ""
    property string label: ""
    property string mark: ""
    width: parent ? (parent.width - parent.spacing) / 2 : 0
    height: root.modeH
    radius: 0
    color: root.tab === tabId
      ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
      : (faceHit.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06) : "transparent")
    border.width: 1
    border.color: root.aim("tab", tabId) || root.tab === tabId ? root.accent : root.line

    Row {
      anchors.centerIn: parent
      spacing: Style.space(6)

      OpticalGlyph {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(16)
        height: Style.space(16)
        text: face.mark
        fontFamily: root.fontFamily
        fontSize: Style.space(14)
        color: root.tab === face.tabId ? root.accent : root.fg
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: face.label
        textFormat: Text.PlainText
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.space(13)
        font.bold: root.tab === face.tabId
      }
    }

    MouseArea {
      id: faceHit
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.tab = face.tabId
    }
  }

  onModesChanged: ensureMode()
  onActiveModeUidChanged: ensureMode()
  onOpenedChanged: {
    if (opened) popoutBar.refreshTargets()
    if (!opened) return
    modePicked = false
    tab = "monitor"
    ensureMode()
    navIndex = 0
  }

  // The plugin bar only lists this chip's button. KeyboardPanel forwards a
  // bar click through bar.clickTargets, so a click on Network or Bluetooth
  // closed this popup and never reached that icon. Stock panels receive
  // every icon. This object is that list for this screen. Open and close
  // still go through the plugin bar. A click on this chip still toggles it.
  QtObject {
    id: popoutBar

    property string position: root.bar ? root.bar.position : "top"
    property int barSize: root.bar ? root.bar.barSize : 0
    property var activePopout: root.bar ? root.bar.activePopout : null
    property var clickTargets: []

    function requestPopout(owner) {
      if (root.bar) root.bar.requestPopout(owner)
    }

    function releasePopout(owner) {
      if (root.bar) root.bar.releasePopout(owner)
    }

    // KeyboardPanel asks the bar where the open card is, so a switch morphs
    // from that card. The plugin facade has both calls. This stand-in has
    // to forward them or the next card grows in on its own.
    function notePopoutCard(card) {
      if (root.bar && typeof root.bar.notePopoutCard === "function") root.bar.notePopoutCard(card)
    }

    function popoutCardFor(owner) {
      if (root.bar && typeof root.bar.popoutCardFor === "function") return root.bar.popoutCardFor(owner)
      return null
    }

    // A button on another screen is not a click on this one. A target
    // with no window still counts, matching the shell's own filter.
    function targetBelongsToWindow(target, window) {
      if (!target || !window) return false
      var attached = target.QsWindow
      if (!attached || !attached.window) return true
      return attached.window === window
    }

    function collect(item, out, seen) {
      if (!item || typeof item !== "object") return
      var n
      for (n = 0; n < seen.length; n++) if (seen[n] === item) return
      seen.push(item)
      if (typeof item.triggerPress === "function" && item.registeredBar) out.push(item)
      var kids = item.children
      var i
      if (kids) for (i = 0; i < kids.length; i++) collect(kids[i], out, seen)
      var loaded = item.item
      if (loaded && loaded !== item) collect(loaded, out, seen)
    }

    function refreshTargets() {
      // QsWindow is an attached type from the Quickshell module. This file
      // has to import that module or the walk below sees no window and every
      // bar click only closes this chip.
      var attached = button.QsWindow
      var win = attached ? attached.window : null
      var out = []
      if (win && win.contentItem) collect(win.contentItem, out, [])
      var cur = clickTargets || []
      if (cur.length === out.length) {
        var same = true
        var i
        for (i = 0; i < out.length; i++) if (cur[i] !== out[i]) { same = false; break }
        if (same) return
      }
      clickTargets = out
    }
  }

  Timer {
    interval: 400
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: popoutBar.refreshTargets()
  }

  Process {
    id: launchWindow
    command: ["bash", root.openPath]
  }

  // manageIpc stays off so this is the one handler for target "omaflow".
  // Actions run a mode or a face. Status calls only print.
  ShellIpc {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    function silent(): string { return root.runNamed("Silent") }
    function performance(): string { return root.runNamed("Performance") }
    function fixed(): string { return root.runNamed("Fixed") }
    function hell(): string { return root.runNamed("Hell") }
    function custom(): string { return root.runCustom() }

    function lcdLiquid(): string { return root.showFace("liquid") }
    function lcdCpu(): string { return root.showFace("cpu") }
    function lcdCpuGpu(): string { return root.showFace("cpu-gpu") }
    function lcdCpuLiquid(): string { return root.showFace("cpu-liquid") }
    function lcdOmarchy(): string { return root.showFace("omarchy") }
    function lcdOmarchyTime(): string { return root.showFace("omarchy-time") }
    function lcdPicture(): string { return root.showFace("picture") }
    function lcdOff(): string { return root.showFace("off") }

    function mode(): string { return root.modeLine() }
    function lcd(): string { return root.lcdLine() }
    function temp(): string { return root.tempLine() }
    function pump(): string { return root.pumpLine() }
    function alerts(): string { return root.alertsLine() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The slot is the label plus the stock icon inset on each side.
    // horizontalMargin is scaled again, so the width is set directly.
    fixedWidth: vertical || labelWidth <= 0 ? -1 : Math.ceil(labelWidth + root.chipPad * 2)
    horizontalMargin: root.chipMargin
    verticalPadding: root.chipMargin
    text: Marks.fan + " " + (root.ready ? root.tempText(root.hottest) : "…") + (root.alertLine ? ("  " + root.alertLine) : "")
    tooltipText: root.ready
      ? ("Omaflow Plugin · " + (root.activeModeName || "no mode") + root.alertTip)
      : "Omaflow Plugin · " + root.connection
    foreground: root.accent
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: root
    bar: popoutBar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(560))
    contentHeight: popup.fittedContentHeight(column.y + column.implicitHeight + Style.space(12))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: pairPassword.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { root.moveNav(dx, dy) }
      onActivateRequested: root.activateNav()
      onTextKey: function(t) {
        var n = parseInt(t, 10)
        if (n >= 1 && n <= 9) root.selectAt(n - 1)
        else if (t === "o" || t === "O") root.openStandalone()
        else if ((t === "r" || t === "R") && root.service) root.service.refresh()
      }

      Flickable {
        id: popupFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.y + column.implicitHeight + Style.space(12)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // Qt's own wheel follows a 1px delta and crawls. One notch is Wheel.NOTCH.
        interactive: false

        WheelHandler {
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          blocking: true
          onWheel: function(event) { Wheel.roll(popupFlick, event) }
        }

        Column {
          id: column
          x: Style.space(12)
          y: Style.space(12)
          width: parent.width - Style.space(24)
          spacing: Style.space(8)

          Item {
            width: parent.width
            height: Math.max(brand.implicitHeight, flavor.implicitHeight + Style.space(4))

            Text {
              id: brand
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "OMAFLOW"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.space(16)
              font.bold: true
            }

            // The phrase sizes the frame. The frame does not size the phrase,
            // or the chip collapses and the line disappears.
            Rectangle {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: flavor.implicitWidth + Style.space(10)
              height: flavor.implicitHeight + Style.space(4)
              radius: 0
              color: "transparent"
              border.width: 1
              border.color: root.line
            }

            Text {
              id: flavor
              anchors.right: parent.right
              anchors.rightMargin: Style.space(5)
              anchors.verticalCenter: parent.verticalCenter
              text: Model.flavorText(
                root.mode ? root.mode.name : root.activeModeName,
                root.hottest
              )
              textFormat: Text.PlainText
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.space(13)
              font.bold: true
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: root.alertLine !== ""
            text: root.alertTip.substring(3)
            textFormat: Text.PlainText
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
            font.bold: true
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: root.showPair
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
            text: "Enter the CoolerControl password once. Omaflow uses 127.0.0.1:11987 and does not ask for an address. The token is saved and the password is not."
          }

          DaemonPrompt {
            width: parent.width
            visible: !root.ready && !root.showPair
            service: root.service
            aimedInstall: root.aim("install", "")
            aimedStart: root.aim("start", "")
            fg: root.fg
            accent: root.accent
            fontFamily: root.fontFamily
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.showPair
            Rectangle {
              width: parent.width - pairButton.width - parent.spacing
              height: Style.space(32)
              radius: 0
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
              TextInput {
                id: pairPassword
                anchors.fill: parent
                anchors.margins: Style.space(8)
                echoMode: TextInput.Password
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.space(13)
                clip: true
                onAccepted: root.submitPair()
              }
            }
            Rectangle {
              id: pairButton
              width: Style.space(64)
              height: Style.space(32)
              radius: 0
              color: root.accent
              Text {
                anchors.centerIn: parent
                text: "Pair"
                color: Commons.Color.background
                font.family: root.fontFamily
                font.pixelSize: Style.space(12)
              }
              MouseArea {
                anchors.fill: parent
                onClicked: root.submitPair()
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)
            visible: root.ready

            TabFace { tabId: "monitor"; label: "Monitoring"; mark: Marks.monitor }
            TabFace { tabId: "mode"; label: "Mode"; mark: Marks.modes }
          }

          Item {
            id: modeRow
            width: parent.width
            height: root.modeH
            visible: root.ready && root.modes.length > 0

            Button {
              id: applyBtn
              anchors.right: parent.right
              visible: root.mode !== null
              width: root.modeH
              height: root.modeH
              opacity: root.calibrationBusy ? 0.45 : 1
              iconText: root.modeApplied ? "\uf058" : "\uf05d"
              iconSize: Style.space(15)
              bordered: true
              hasCursor: root.aim("apply", "")
              selected: false
              background: root.modeApplied ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22) : "transparent"
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              horizontalPadding: 0
              verticalPadding: 0
              tooltipText: root.calibrationBusy
                ? "A fan is being calibrated. Apply waits until that sweep finishes."
                : (root.modeApplied
                  ? (root.mode.name + " is running")
                  : ("Run " + (root.mode ? root.mode.name : "")))
              onClicked: root.applySelected()
            }

            Rectangle {
              id: modeSep
              anchors.right: applyBtn.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              width: 1
              height: parent.height
              visible: root.mode !== null
              color: root.rule
            }

            Row {
              id: modeButtons
              anchors.left: parent.left
              anchors.right: modeSep.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              height: parent.height
              spacing: Style.space(6)

              Repeater {
                model: root.modes
                delegate: Button {
                  required property var modelData
                  required property int index
                  readonly property bool chosen: modelData.uid === root.modeUid
                  readonly property bool running: modelData.uid === root.activeModeUid
                  readonly property bool hell: /hell/i.test(String(modelData.name || ""))
                  readonly property int slot: {
                    var count = root.modes.length
                    if (count < 1) return 0
                    var gaps = modeButtons.spacing * Math.max(0, count - 1)
                    var base = Math.floor((modeButtons.width - gaps) / count)
                    if (index === count - 1)
                      return Math.max(1, modeButtons.width - gaps - base * Math.max(0, count - 1))
                    return Math.max(1, base)
                  }
                  width: slot
                  height: root.modeH
                  verticalPadding: Style.space(2)
                  text: modelData.name
                  iconText: Marks.modeMark(modelData.name)
                  iconSize: Style.space(13)
                  selected: chosen
                  hasCursor: root.aim("mode", modelData.uid)
                  bordered: true
                  foreground: running ? (hell ? Commons.Color.urgent : root.accent) : root.fg
                  accent: hell ? Commons.Color.urgent : root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(4)
                  tooltipText: running ? "Running" : "Select this mode"
                  onClicked: root.pickMode(modelData.uid)
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.ready && root.service && root.service.lastError !== ""
            wrapMode: Text.WordWrap
            text: root.service ? root.service.lastError : ""
            textFormat: Text.PlainText
            color: Commons.Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          MonitoringPage {
            width: parent.width
            visible: root.opened && root.ready && root.tab === "monitor"
            service: root.service
            fg: root.fg
            accent: root.accent
            fontFamily: root.fontFamily
            chartHeight: Style.space(140)
            processLimit: 2
            meterSquares: 8
          }

          PluginCurves {
            width: parent.width
            visible: root.ready && root.tab === "mode"
            service: root.service
            modeUid: root.modeUid
            fg: root.fg
            accent: root.accent
            fontFamily: root.fontFamily
          }

          Rectangle {
            width: parent.width
            height: Style.space(32)
            radius: 0
            color: root.aim("open", "")
              ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22)
              : Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)
            border.width: 1
            border.color: root.aim("open", "") ? root.accent : root.line
            Row {
              anchors.centerIn: parent
              spacing: Style.space(8)

              OpticalGlyph {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(14)
                height: Style.space(14)
                text: Marks.open
                fontFamily: root.fontFamily
                fontSize: Style.space(14)
                color: root.fg
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.ready ? "OMAFLOW" : "Open Omaflow"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.space(13)
                font.bold: true
              }
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openStandalone()
            }
          }
        }
      }

      HoverScroll {
        flick: popupFlick
        ink: root.fg
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: parent.right
      }
    }
  }
}
