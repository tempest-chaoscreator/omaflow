import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "CcMap.js" as Cc
import "Model.js" as Model
import "Nav.js" as Nav

// Omaflow Plugin. Telemetry and the selected mode. Curve edits stay in
// Omaflow. Choosing a mode does not run it. Apply does.
Panel {
  id: root
  moduleName: "tempest-chaoscreator.omaflow"
  ipcTarget: "omaflow"
  manageIpc: false

  readonly property var service: (bar && bar.shell && typeof bar.shell.serviceFor === "function")
    ? bar.shell.serviceFor(root.moduleName) : null
  readonly property string connection: service ? String(service.connection || "down") : "down"
  readonly property bool ready: connection === "ready"
  readonly property var temps: service && service.temps ? service.temps : ({})
  readonly property var modes: service && service.modes ? service.modes : []
  readonly property string activeModeUid: service ? String(service.activeModeUid || "") : ""
  readonly property string activeModeName: service ? String(service.activeModeName || "") : ""
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color accent: Color.accent
  readonly property color line: Qt.rgba(fg.r, fg.g, fg.b, 0.16)
  readonly property real hottest: temps && isFinite(Number(temps.hottest)) ? Number(temps.hottest) : NaN

  property string tab: "telemetry"
  property string modeUid: ""
  property int navIndex: 0

  readonly property var mode: {
    for (var i = 0; i < modes.length; i++) if (modes[i].uid === modeUid) return modes[i]
    return null
  }
  readonly property bool modeApplied: mode && mode.uid === activeModeUid
  readonly property int modeH: Style.space(28)
  readonly property var navItems: {
    var out = [
      { kind: "tab", id: "telemetry", x: 0, y: 0 },
      { kind: "tab", id: "mode", x: 1, y: 0 }
    ]
    for (var i = 0; i < modes.length; i++) out.push({ kind: "mode", uid: modes[i].uid, x: i, y: 1 })
    if (mode) out.push({ kind: "apply", x: modes.length, y: 1 })
    out.push({ kind: "open", x: 0, y: 2 })
    return out
  }

  function tempText(value) {
    return isFinite(Number(value)) ? Math.round(Number(value)) + "°" : "—"
  }

  function openStandalone() {
    var shell = root.bar && root.bar.shell
    if (shell && typeof shell.summon === "function") {
      shell.summon(root.moduleName, "")
      return
    }
    launchWindow.running = true
  }

  function ensureMode() {
    if (modeUid && mode) return
    if (activeModeUid) modeUid = activeModeUid
    else if (modes.length) modeUid = modes[0].uid
  }

  function navAt() {
    return navItems.length ? navItems[Math.max(0, Math.min(navItems.length - 1, navIndex))] : null
  }

  function moveNav(dx, dy) {
    navIndex = Nav.step(navItems, navIndex, dx, dy)
  }

  function activateNav() {
    var item = navAt()
    if (!item) return
    if (item.kind === "tab") tab = item.id
    else if (item.kind === "mode") modeUid = item.uid
    else if (item.kind === "apply") applySelected()
    else if (item.kind === "open") openStandalone()
  }

  function aim(kind, id) {
    var item = navAt()
    if (!popup.open || !item || item.kind !== kind) return false
    if (kind === "tab") return item.id === id
    if (kind === "mode") return item.uid === id
    return true
  }

  function applySelected() {
    if (!service || !mode) return
    var members = Cc.modeMembers(mode, service.channels, service.profiles)
    if (!members.length) {
      service.lastError = mode.name + " has no channels. Add one in Omaflow before applying."
      return
    }
    var jobs = []
    var seen = ({})
    for (var i = 0; i < members.length; i++) {
      var row = members[i]
      if (!row.profileUid || seen[row.profileUid]) continue
      if (!row.points || row.points.length < 2) continue
      seen[row.profileUid] = true
      jobs.push({ profileUid: row.profileUid, points: row.points, minDuty: row.minDuty || 0 })
    }
    service.lastError = ""
    service.applyModeCurves(mode.uid, jobs)
  }

  function selectAt(index) {
    if (index < 0 || index >= modes.length) return
    modeUid = modes[index].uid
  }

  onModesChanged: ensureMode()
  onOpenedChanged: {
    if (!opened) return
    tab = "telemetry"
    ensureMode()
    navIndex = 0
  }

  Process {
    id: launchWindow
    command: ["gtk-launch", "omaflow-standalone"]
  }

  IpcHandler {
    target: "omaflow"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰈐 " + (root.ready ? root.tempText(root.hottest) : "…")
    tooltipText: root.ready
      ? ("Omaflow Plugin · " + (root.activeModeName || "no mode"))
      : "Omaflow Plugin · " + root.connection
    foreground: root.accent
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(560))
    contentHeight: popup.fittedContentHeight(column.y + column.implicitHeight + Style.space(12))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
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
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.y + column.implicitHeight + Style.space(12)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

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
              border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.35)
            }

            Text {
              id: flavor
              anchors.right: parent.right
              anchors.rightMargin: Style.space(5)
              anchors.verticalCenter: parent.verticalCenter
              text: Model.flavorText(
                root.mode ? root.mode.name : root.activeModeName,
                Model.hottest(root.temps)
              )
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.space(13)
              font.bold: true
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: !root.ready
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
            text: root.connection === "need-token" || root.connection === "unauthorized"
              ? "Enter the CoolerControl password once. Omaflow uses 127.0.0.1:11987 and does not ask for an address. The token is saved and the password is not."
              : (root.service && root.service.lastError ? root.service.lastError : "coolercontrold is not running.")
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.connection === "need-token" || root.connection === "unauthorized"
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
                color: Color.background
                font.family: root.fontFamily
                font.pixelSize: Style.space(12)
              }
              MouseArea {
                anchors.fill: parent
                onClicked: {
                  var password = pairPassword.text
                  pairPassword.text = ""
                  if (root.service) root.service.pair(password)
                }
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)
            visible: root.ready

            Rectangle {
              width: (parent.width - parent.spacing) / 2
              height: root.modeH
              radius: 0
              color: root.tab === "telemetry"
                ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                : "transparent"
              border.width: 1
              border.color: root.aim("tab", "telemetry") || root.tab === "telemetry" ? root.accent : root.line
              Text {
                anchors.centerIn: parent
                text: "Telemetry"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.space(12)
                font.bold: root.tab === "telemetry"
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.tab = "telemetry"
              }
            }

            Rectangle {
              width: (parent.width - parent.spacing) / 2
              height: root.modeH
              radius: 0
              color: root.tab === "mode"
                ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                : "transparent"
              border.width: 1
              border.color: root.aim("tab", "mode") || root.tab === "mode" ? root.accent : root.line
              Text {
                anchors.centerIn: parent
                text: "Mode"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.space(12)
                font.bold: root.tab === "mode"
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.tab = "mode"
              }
            }
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
              iconText: root.modeApplied ? "\uf058" : "\uf05d"
              iconSize: Style.space(14)
              bordered: true
              hasCursor: root.aim("apply", "")
              selected: false
              background: root.modeApplied ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22) : "transparent"
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              horizontalPadding: 0
              verticalPadding: 0
              tooltipText: root.modeApplied
                ? (root.mode.name + " is running")
                : ("Run " + (root.mode ? root.mode.name : ""))
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
              color: root.line
            }

            Row {
              id: modeButtons
              anchors.left: parent.left
              anchors.right: modeSep.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              height: parent.height
              spacing: Style.space(4)
              clip: true

              Repeater {
                model: root.modes
                delegate: Button {
                  required property var modelData
                  required property int index
                  readonly property bool chosen: modelData.uid === root.modeUid
                  readonly property int slot: {
                    var count = root.modes.length
                    if (count < 1) return 0
                    var gaps = modeButtons.spacing * Math.max(0, count - 1)
                    return Math.max(1, Math.floor((modeButtons.width - gaps) / count))
                  }
                  width: slot
                  height: root.modeH
                  clip: true
                  verticalPadding: Style.space(2)
                  text: ""
                  selected: chosen
                  hasCursor: root.aim("mode", modelData.uid)
                  bordered: true
                  foreground: root.fg
                  accent: /hell/i.test(modelData.name) ? Color.urgent : root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(2)
                  tooltipText: modelData.uid === root.activeModeUid ? "Running" : "Select this mode"
                  onClicked: root.modeUid = modelData.uid

                  Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(4)
                    anchors.rightMargin: Style.space(4)
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: modelData.name
                    color: parent.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: parent.chosen
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.ready && root.service && root.service.lastError !== ""
            wrapMode: Text.WordWrap
            text: root.service ? root.service.lastError : ""
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          MonitoringPage {
            width: parent.width
            visible: root.ready && root.tab === "telemetry"
            service: root.service
            fg: root.fg
            accent: root.accent
            fontFamily: root.fontFamily
            chartHeight: Style.space(140)
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
            Text {
              anchors.centerIn: parent
              text: "OMAFLOW"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.space(13)
              font.bold: true
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openStandalone()
            }
          }
        }
      }
    }
  }
}
