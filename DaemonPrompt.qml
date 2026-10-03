import QtQuick
import qs.Commons
import qs.Ui
import "Nav.js" as Nav

// Shown instead of a connection error. Install and start each ask for the
// password once. Neither one enables the daemon at boot.
Column {
  id: root

  property var service: null
  property bool showOpen: false
  property bool keyed: false
  property bool aimedInstall: false
  property bool aimedStart: false
  property int navIndex: 0
  property color fg: Color.foreground
  property color accent: Color.accent
  property color muted: Qt.darker(fg, 1.4)
  property string fontFamily: Style.font.family

  signal openRequested()

  width: parent ? parent.width : 0
  spacing: Style.space(8)

  readonly property string gate: service ? String(service.daemonGate || "unknown") : "unknown"
  readonly property bool busy: service && service.daemonBusy === true
  readonly property string headline: {
    if (gate === "install") return "coolercontrold is not installed."
    if (gate === "start") return "coolercontrold is installed and not running."
    if (gate === "starting") return "Starting coolercontrold."
    if (gate === "up") {
      var err = service && service.lastError ? String(service.lastError) : ""
      if (err.indexOf("not coolercontrold") >= 0) return err
      return "Waiting for coolercontrold."
    }
    return "Checking coolercontrold."
  }
  readonly property var navItems: {
    var out = []
    if (gate === "install") out.push({ kind: "install", x: 0, y: 0 })
    else if (gate === "start") out.push({ kind: "start", x: 0, y: 0 })
    if (showOpen) out.push({ kind: "open", x: 0, y: out.length })
    return out
  }

  function navAt() {
    return navItems.length ? navItems[Math.max(0, Math.min(navItems.length - 1, navIndex))] : null
  }

  function aimed(kind) {
    if (!keyed) return false
    var item = navAt()
    return !!(item && item.kind === kind)
  }

  function moveNav(dx, dy) {
    navIndex = Nav.step(navItems, navIndex, dx, dy)
  }

  function activateNav() {
    var item = navAt()
    if (!item || !service) return
    if (item.kind === "install") service.installDaemon()
    else if (item.kind === "start") service.startDaemon()
    else if (item.kind === "open") openRequested()
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: root.headline
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.space(13)
  }

  Button {
    visible: root.gate === "install"
    text: root.busy ? "Waiting" : "Install coolercontrold"
    bordered: true
    selected: root.aimedInstall || root.aimed("install")
    foreground: root.fg
    accent: root.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    onClicked: if (root.service) root.service.installDaemon()
  }

  Button {
    visible: root.gate === "start"
    text: root.busy ? "Waiting" : "Start coolercontrold"
    bordered: true
    selected: root.aimedStart || root.aimed("start")
    foreground: root.fg
    accent: root.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    onClicked: if (root.service) root.service.startDaemon()
  }

  Button {
    visible: root.showOpen && (root.gate === "install" || root.gate === "start")
    text: "Open Omaflow"
    bordered: true
    selected: root.aimed("open")
    foreground: root.fg
    accent: root.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    onClicked: root.openRequested()
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: root.gate === "start"
    text: "This starts it for this session and asks for your password. It does not start with the PC. Turn on Start with the PC in Omaflow Settings. That switch stays off until you turn it on."
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: root.service && root.service.daemonNote !== ""
    text: root.service ? root.service.daemonNote : ""
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
