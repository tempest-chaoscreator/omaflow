import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Nav.js" as Nav

// Omaflow. Monitoring opens first.
// Settings sits at the bottom of the rail. The info glyph is on that same row, at the right edge.
// Tab moves between the rail and the page. Arrows move to the neighboring control.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property bool ownsProcess: false
  property bool closingFromHost: false
  property bool readyToQuit: false
  property string page: "monitor"
  property string zone: "rail"
  property int railIndex: 0

  readonly property bool opened: window.visible
  readonly property color fg: Color.foreground
  readonly property color accent: Color.accent
  property color accent2: Color.accent
  property string shellRaw: ""
  property bool uiCaptured: false
  property real shellSpacing: 1
  property int shellText: 12
  readonly property color bg: Color.background
  readonly property color line: Qt.rgba(fg.r, fg.g, fg.b, 0.16)
  readonly property color muted: Qt.rgba(fg.r, fg.g, fg.b, 0.55)
  readonly property string fontFamily: Style.font.family
  readonly property var mainPages: [
    { id: "monitor", name: "Monitoring", mark: "\uf201" },
    { id: "modes", name: "Modes", mark: "\uf1fe" },
    { id: "devices", name: "Devices", mark: "\uf233" },
    { id: "lcd", name: "LCD", mark: "\uf108" }
  ]
  readonly property var infoPageInfo: ({ id: "info", name: "Info", mark: "\uf05a" })
  readonly property var settingsPageInfo: ({ id: "settings", name: "Settings", mark: "\uf013" })
  readonly property var pages: mainPages.concat([settingsPageInfo, infoPageInfo])
  readonly property var railItems: {
    var out = []
    var i
    for (i = 0; i < mainPages.length; i++) out.push({ id: mainPages[i].id, x: 0, y: i })
    out.push({ id: "settings", x: 0, y: mainPages.length })
    out.push({ id: "info", x: 1, y: mainPages.length })
    return out
  }
  readonly property bool pageKeyed: zone === "page"
  readonly property bool promptKeyed: {
    if (!service || service.connection === "ready") return false
    if (service.daemonGate === "up" && (service.connection === "need-token" || service.connection === "unauthorized"))
      return false
    return page === "monitor" || page === "modes" || page === "devices" || page === "lcd"
  }
  readonly property string pageTitle: {
    for (var i = 0; i < pages.length; i++) if (pages[i].id === page) return pages[i].name
    return "Omaflow"
  }

  function open(payloadJson) {
    closingFromHost = false
    window.visible = true
    zone = "rail"
    railIndex = pageIndex(page)
  }

  function close() {
    // Do not set closingFromHost. A hidden standalone process stays in
    // the background, and quickshell -n then refuses the launcher and the
    // chip. Dropping the surface quits this process.
    window.visible = false
  }

  function dismiss() {
    if (!ownsProcess && shell && typeof shell.hide === "function")
      shell.hide((manifest && manifest.id) || "tempest-chaoscreator.omaflow")
    else close()
  }

  function pageIndex(id) {
    for (var i = 0; i < railItems.length; i++) if (railItems[i].id === id) return i
    return 0
  }

  function showPage(index) {
    var i = Math.max(0, Math.min(railItems.length - 1, index))
    railIndex = i
    page = railItems[i].id
  }

  function railMove(dx, dy) {
    var next = Nav.step(railItems, railIndex, dx, dy)
    showPage(next)
  }

  function pickPage(id) {
    page = id
    railIndex = pageIndex(id)
  }

  function activePage() {
    if (page === "monitor") return monitorPage
    if (page === "modes") return modesPage
    if (page === "devices") return devicesPage
    if (page === "lcd") return lcdPage
    if (page === "info") return infoPage
    return settingsPage
  }

  function hexOf(color) {
    function byte(part) {
      var n = Math.max(0, Math.min(255, Math.round(Number(part) * 255)))
      var text = n.toString(16)
      return text.length < 2 ? "0" + text : text
    }
    return ("#" + byte(color.r) + byte(color.g) + byte(color.b)).toLowerCase()
  }

  function paintColor(current, value) {
    if (!value || String(value).length < 7) return current
    var next = String(value).toLowerCase()
    return hexOf(current) === next ? current : next
  }

  // The shell recolors itself over IPC. This process never hears that, so it
  // re-reads the theme file and writes the singleton the pages already bind.
  function applyThemeColors(raw) {
    // Inside the bar this singleton is the shell's. Leave it alone.
    if (!ownsProcess) return
    var lines = String(raw || "").split("\n")
    var foundAccent = false
    var foundMuted = false
    var loadedForeground = false
    var loadedBackground = false
    var palette = ({})
    var color0 = ""
    var color4 = ""
    var color7 = ""
    var color8 = ""
    var fg = ""
    var bg = ""
    var accent = ""
    var urgent = ""
    var muted = ""
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (!match) continue
      palette[match[1]] = match[2]
      if (match[1] === "foreground") { fg = match[2]; loadedForeground = true }
      else if (match[1] === "background") { bg = match[2]; loadedBackground = true }
      else if (match[1] === "accent") { accent = match[2]; foundAccent = true }
      else if (match[1] === "muted") { muted = match[2]; foundMuted = true }
      else if (match[1] === "color0") color0 = match[2]
      else if (match[1] === "color4") color4 = match[2]
      else if (match[1] === "color7") color7 = match[2]
      else if (match[1] === "color8") color8 = match[2]
      else if (match[1] === "red" || match[1] === "color1") urgent = match[2]
    }
    if (!loadedBackground && color0) bg = color0
    if (!loadedForeground && color7) fg = color7
    if (!foundAccent && color4) accent = color4
    if (!foundMuted) muted = color8 || fg
    if (fg) Color.foreground = paintColor(Color.foreground, fg)
    if (bg) Color.background = paintColor(Color.background, bg)
    if (accent) Color.accent = paintColor(Color.accent, accent)
    if (urgent) Color.urgent = paintColor(Color.urgent, urgent)
    if (muted) Color.muted = paintColor(Color.muted, muted)
    var second = palette.green || palette.cyan || palette.magenta || ""
    if (second) accent2 = paintColor(accent2, second)
  }

  function applyShell(raw) {
    if (!ownsProcess) return
    var next = String(raw || "")
    if (next !== shellRaw) {
      shellRaw = next
      Color.loadShell(next)
      shellSpacing = Style.spacingScale
      shellText = Style.font.baseSize
      uiCaptured = true
    }
    applyWindowPrefs()
  }

  // Text size is this window only. Fill does not change the rail, the LCD,
  // or this font. The chart, the mode curve, and the speedometers read it.
  function applyWindowPrefs() {
    if (!ownsProcess || !uiCaptured) return
    var follow = !service || service.textFollow !== false
    var chosen = follow ? shellText : Math.max(1, Number(service && service.textSize) || shellText)
    if (Math.abs(Style.spacingScale - shellSpacing) > 0.01) Style.spacingScale = shellSpacing
    if (Style.fontBaseSize !== chosen) Style.fontBaseSize = chosen
  }

  Connections {
    target: root.service
    function onDynamicScaleChanged() { root.applyWindowPrefs() }
    function onTextFollowChanged() { root.applyWindowPrefs() }
    function onTextSizeChanged() { root.applyWindowPrefs() }
  }

  function reloadTheme() {
    colorsFile.reload()
    shellFile.reload()
  }

  function handleKey(event) {
    var item = window.activeFocusItem
    var typing = item && (String(item).indexOf("TextField") >= 0 || String(item).indexOf("TextInput") >= 0)
    if (event.key === Qt.Key_Escape) {
      if (!typing && zone === "page" && activePage() && activePage().takeEscape && activePage().takeEscape()) {
        event.accepted = true
        return
      }
      dismiss()
      event.accepted = true
      return
    }
    if (typing) return
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      zone = zone === "rail" ? "page" : "rail"
      event.accepted = true
      return
    }
    var down = event.key === Qt.Key_Down
    var up = event.key === Qt.Key_Up
    var left = event.key === Qt.Key_Left
    var right = event.key === Qt.Key_Right
    if (zone === "rail") {
      if (down) railMove(0, 1)
      else if (up) railMove(0, -1)
      else if (right) railMove(1, 0)
      else if (left) railMove(-1, 0)
      if (down || up || left || right) event.accepted = true
      return
    }
    var host = promptKeyed ? daemonPrompt : activePage()
    if (!host) return
    var dx = right ? 1 : (left ? -1 : 0)
    var dy = down ? 1 : (up ? -1 : 0)
    if ((dx || dy) && host.moveNav) {
      host.moveNav(dx, dy)
      event.accepted = true
      return
    }
    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && host.activateNav) {
      host.activateNav()
      event.accepted = true
    }
  }

  FileView {
    id: colorsFile
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyThemeColors(text())
    onFileChanged: reload()
  }

  FileView {
    id: themeNameFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: root.reloadTheme()
  }

  FileView {
    id: shellFile
    path: Color.currentThemePath + "/shell.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyShell(text())
    onFileChanged: reload()
    onLoadFailed: root.applyShell("")
  }

  Timer {
    interval: 1500
    repeat: true
    running: true
    onTriggered: root.reloadTheme()
  }

  Component.onCompleted: {
    if (ownsProcess) open("{}")
    readyToQuit = true
  }

  FloatingWindow {
    id: window
    title: "Omaflow"
    color: root.bg
    implicitWidth: 980
    implicitHeight: 680
    minimumSize: Qt.size(760, 520)
    visible: false
    onWidthChanged: root.applyWindowPrefs()
    onHeightChanged: root.applyWindowPrefs()

    onVisibleChanged: {
      if (visible || root.closingFromHost) return
      if (!root.ownsProcess && root.shell && typeof root.shell.hide === "function")
        root.shell.hide((root.manifest && root.manifest.id) || "tempest-chaoscreator.omaflow")
      else if (root.ownsProcess && root.readyToQuit) Qt.quit()
    }

    FocusScope {
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) { root.handleKey(event) }

      Row {
        anchors.fill: parent
        spacing: 0

        Rectangle {
          id: rail
          width: Style.space(184)
          height: parent.height
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)

          Text {
            id: wordmark
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: Style.space(12)
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            leftPadding: Style.space(8) + Style.space(16) + Style.space(10)
            text: "OMAFLOW"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
            font.bold: true
            font.letterSpacing: 1.3
          }

          Column {
            anchors.top: wordmark.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Style.space(12)
            anchors.topMargin: Style.space(8)
            spacing: Style.space(6)

            Repeater {
              model: root.mainPages
              delegate: NavRow {
                required property var modelData
                required property int index
                label: modelData.name
                mark: modelData.mark
                on: root.page === modelData.id
                armed: root.zone === "rail" && root.railIndex === index
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                onPicked: root.pickPage(modelData.id)
              }
            }
          }

          Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            Rectangle {
              width: parent.width
              height: 1
              color: root.line
            }

            Row {
              id: foot
              width: parent.width
              spacing: Style.space(6)

              NavRow {
                width: foot.width - infoBtn.width - foot.spacing
                label: root.settingsPageInfo.name
                mark: root.settingsPageInfo.mark
                on: root.page === "settings"
                armed: root.zone === "rail" && root.railItems[root.railIndex] && root.railItems[root.railIndex].id === "settings"
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                onPicked: root.pickPage("settings")
              }

              Rectangle {
                id: infoBtn
                width: Style.space(36)
                height: Style.space(36)
                radius: 0
                color: root.page === "info"
                  ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.14)
                  : ((root.zone === "rail" && root.railItems[root.railIndex] && root.railItems[root.railIndex].id === "info")
                    ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06) : "transparent")

                Rectangle {
                  width: 2
                  height: parent.height
                  visible: root.zone === "rail" && root.railItems[root.railIndex] && root.railItems[root.railIndex].id === "info"
                  color: root.accent
                }

                OpticalGlyph {
                  anchors.centerIn: parent
                  width: Style.space(16)
                  height: Style.space(16)
                  text: root.infoPageInfo.mark
                  fontFamily: root.fontFamily
                  fontSize: Style.space(14)
                  color: root.page === "info" || (root.zone === "rail" && root.railItems[root.railIndex] && root.railItems[root.railIndex].id === "info")
                    ? root.accent : root.fg
                }

                MouseArea {
                  id: infoMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.pickPage("info")
                }

                PanelToolTip {
                  visible: infoMouse.containsMouse
                  text: "Info"
                  panelBackground: root.bg
                  panelForeground: root.fg
                  panelBorder: root.accent
                  fontFamily: root.fontFamily
                }
              }
            }
          }
        }

        Rectangle {
          width: 1
          height: parent.height
          color: root.line
        }

        Item {
          width: parent.width - rail.width - 1
          height: parent.height

          Column {
            anchors.fill: parent
            anchors.margins: Style.space(16)
            spacing: Style.space(12)

            Item {
              width: parent.width
              height: Math.max(pageTitleText.implicitHeight, calibrateAll.height)

              Text {
                id: pageTitleText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.pageTitle
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.space(20)
                font.bold: true
              }

              CalGlyph {
                id: calibrateAll
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.page === "devices"
                  && devicesPage.jobsFor(devicesPage.everyActive()).length > 0
                selected: devicesPage.aimed("all", "")
                label: "Calibrate All"
                fg: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: devicesPage.calibrateRows(devicesPage.everyActive())
              }
            }

            DaemonPrompt {
              id: daemonPrompt
              width: parent.width
              visible: (!root.service || root.service.connection !== "ready")
                && !(root.service
                  && root.service.daemonGate === "up"
                  && (root.service.connection === "need-token" || root.service.connection === "unauthorized"))
              service: root.service
              keyed: root.zone === "page" && root.promptKeyed
              fg: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              visible: root.service && root.service.daemonGate === "up"
                && (root.service.connection === "need-token" || root.service.connection === "unauthorized")
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.space(13)
              text: "Enter the CoolerControl password once in Settings. Omaflow uses 127.0.0.1:11987. The token is saved and the password is not."
            }

            Flickable {
              id: pageFlick
              width: parent.width
              height: parent.height - y
              contentWidth: width
              contentHeight: body.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: body
                width: parent.width
                spacing: Style.space(8)
                MonitoringPage {
                  id: monitorPage
                  visible: root.page === "monitor" && root.service && root.service.connection === "ready"
                  width: parent.width
                  service: root.service
                  keyed: root.pageKeyed && root.page === "monitor"
                  fill: root.service && root.service.dynamicScale === true
                  viewHeight: pageFlick.height
                  fg: root.fg
                  accent: root.accent
                  fontFamily: root.fontFamily
                }

                ModesCurves {
                  id: modesPage
                  visible: root.page === "modes" && root.service && root.service.connection === "ready"
                  width: parent.width
                  service: root.service
                  keyed: root.pageKeyed && root.page === "modes"
                  fill: root.service && root.service.dynamicScale === true
                  viewHeight: pageFlick.height
                  fg: root.fg
                  accent: root.accent
                  fontFamily: root.fontFamily
                }

                DevicesPage {
                  id: devicesPage
                  visible: root.page === "devices" && root.service && root.service.connection === "ready"
                  width: parent.width
                  service: root.service
                  keyed: root.pageKeyed && root.page === "devices"
                  fg: root.fg
                  accent: root.accent
                  fontFamily: root.fontFamily
                }

                LcdPage {
                  id: lcdPage
                  visible: root.page === "lcd" && root.service && root.service.connection === "ready"
                  width: parent.width
                  height: visible ? pageFlick.height : 0
                  service: root.service
                  keyed: root.pageKeyed && root.page === "lcd"
                  fg: root.fg
                  accent: root.accent
                  accent2: root.accent2
                  fontFamily: root.fontFamily
                }

                InfoPage {
                  id: infoPage
                  visible: root.page === "info"
                  width: parent.width
                  fg: root.fg
                  fontFamily: root.fontFamily
                }

                SettingsPage {
                  id: settingsPage
                  visible: root.page === "settings"
                  width: parent.width
                  service: root.service
                  keyed: root.pageKeyed && root.page === "settings"
                  shellTextPx: root.shellText
                  fg: root.fg
                  accent: root.accent
                  fontFamily: root.fontFamily
                }
              }
            }
          }
        }
      }
    }
  }
}
