import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Nav.js" as Nav

// Daemon options, curve response, and alerts. The window does not change them on its own.
Column {
  id: root

  property var service: null
  property bool keyed: false
  property int navIndex: 0
  property color fg: Color.foreground
  property color accent: Color.accent
  property color muted: Qt.darker(fg, 1.4)
  property string fontFamily: Style.font.family

  width: parent ? parent.width : 0
  spacing: Style.space(12)

  readonly property var switches: [
    { key: "apply_on_boot", label: "Apply on boot" },
    { key: "hide_duplicate_devices", label: "Hide duplicate devices" },
    { key: "liquidctl_integration", label: "USB coolers through liquidctl" },
    { key: "compress", label: "Compress API responses" },
    { key: "sensors_conf_enabled", label: "Use sensors.conf labels" }
  ]
  property string barScript: Qt.resolvedUrl("scripts/bar_plugin.py").toString().replace(/^file:\/\//, "")
  property bool barOn: false
  property bool barBusy: false
  property string barNote: ""

  readonly property var navItems: {
    var out = []
    var i
    function place(item) {
      item.x = 0
      item.y = out.length
      out.push(item)
    }
    place({ kind: "bar", index: 0 })
    for (i = 0; i < switches.length; i++) place({ kind: "daemon", index: i })
    var fns = service && service.functions ? service.functions : []
    for (i = 0; i < fns.length; i++) place({ kind: "function", index: i })
    var alerts = service && service.alerts ? service.alerts : []
    for (i = 0; i < alerts.length; i++) place({ kind: "alert", index: i })
    return out
  }

  function patch(key, value) {
    if (!service || !service.daemonSettings) return
    var next = ({})
    var current = service.daemonSettings
    for (var k in current) next[k] = current[k]
    next[key] = value
    service.saveDaemon(next)
  }

  function copy(obj) {
    return JSON.parse(JSON.stringify(obj))
  }

  function moveNav(dx, dy) {
    navIndex = Nav.step(navItems, navIndex, dx, dy)
  }

  function aimed(kind, index) {
    if (!keyed || !navItems.length) return false
    var item = navItems[Math.max(0, Math.min(navItems.length - 1, navIndex))]
    return item && item.kind === kind && item.index === index
  }

  function runBar(action) {
    if (barBusy || barProc.running) return
    barBusy = true
    barProc.command = ["python3", "-u", barScript, action]
    barProc.running = true
  }

  function takeBar(line) {
    var obj
    try { obj = JSON.parse(String(line || "")) } catch (e) { return }
    if (!obj) return
    if (obj.enabled !== undefined) barOn = obj.enabled === true
    barNote = obj.error ? String(obj.error) : ""
  }

  function activateNav() {
    var item = navItems[navIndex]
    if (!item) return
    if (item.kind === "bar") {
      runBar(barOn ? "disable" : "enable")
      return
    }
    if (!service) return
    if (item.kind === "daemon") {
      var row = switches[item.index]
      var current = service.daemonSettings ? service.daemonSettings[row.key] === true : false
      patch(row.key, !current)
    } else if (item.kind === "function") {
      var fn = service.functions[item.index]
      if (!fn) return
      var next = copy(fn)
      next.threshold_hopping = !fn.threshold_hopping
      service.saveFunction(next)
    } else if (item.kind === "alert") {
      var alert = service.alerts[item.index]
      if (!alert) return
      var copyAlert = copy(alert)
      copyAlert.enabled = alert.enabled === false
      service.saveAlert(copyAlert)
    }
  }

  Text {
    text: "Bar"
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.space(14)
    font.bold: true
  }

  Row {
    spacing: Style.space(10)
    SquareSwitch {
      anchors.verticalCenter: parent.verticalCenter
      on: root.barOn
      switchEnabled: !root.barBusy
      foreground: root.fg
      accent: root.aimed("bar", 0) ? root.accent : root.fg
      onClicked: root.runBar(root.barOn ? "disable" : "enable")
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "Show Omaflow Plugin on the bar"
      color: root.aimed("bar", 0) ? root.accent : root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.space(13)
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: root.barNote !== ""
      ? root.barNote
      : "Turning this on copies this 2.0.0 build into the plugin and shows the chip. The chip uses coolercontrold. A 1.3.0 copy is saved once before it is replaced."
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Fan writes and sensor polls stay on coolercontrold. These are the daemon's own options."
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.space(13)
  }

  Process {
    id: barProc
    stdout: SplitParser {
      onRead: function(line) { root.takeBar(line) }
    }
    stderr: SplitParser {
      onRead: function(line) { root.barNote = String(line) }
    }
    onExited: root.barBusy = false
  }

  Component.onCompleted: root.runBar("status")

  Repeater {
    model: root.switches
    delegate: Row {
      required property var modelData
      required property int index
      spacing: Style.space(10)
      SquareSwitch {
        anchors.verticalCenter: parent.verticalCenter
        on: root.service && root.service.daemonSettings ? root.service.daemonSettings[modelData.key] === true : false
        foreground: root.fg
        accent: root.aimed("daemon", index) ? root.accent : root.fg
        onClicked: root.patch(modelData.key, !(root.service.daemonSettings[modelData.key] === true))
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: modelData.label
        color: root.aimed("daemon", index) ? root.accent : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.space(13)
      }
    }
  }

  Text {
    text: "Poll interval"
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Flow {
    width: parent.width
    spacing: Style.space(6)
    Repeater {
      model: [0.5, 1, 2, 5]
      delegate: Button {
        required property var modelData
        text: modelData + " s"
        bordered: true
        selected: root.service && Number(root.service.daemonSettings.poll_rate) === Number(modelData)
        foreground: root.fg
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        onClicked: root.patch("poll_rate", Number(modelData))
      }
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Pump curves stay at or above 50%."
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.space(13)
  }

  Text {
    text: "Curve response"
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.space(14)
    font.bold: true
    topPadding: Style.space(8)
  }

  Repeater {
    model: root.service ? root.service.functions : []
    delegate: Row {
      required property var modelData
      required property int index
      spacing: Style.space(10)
      SquareSwitch {
        anchors.verticalCenter: parent.verticalCenter
        on: modelData.threshold_hopping === true
        foreground: root.fg
        accent: root.aimed("function", index) ? root.accent : root.fg
        onClicked: {
          var next = root.copy(modelData)
          next.threshold_hopping = !modelData.threshold_hopping
          root.service.saveFunction(next)
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: modelData.name + "  hop"
        color: root.aimed("function", index) ? root.accent : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.space(13)
      }
    }
  }

  Text {
    text: "Alerts"
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.space(14)
    font.bold: true
  }

  Text {
    visible: !root.service || !root.service.alerts || root.service.alerts.length === 0
    text: "No alerts yet."
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.space(12)
  }

  Repeater {
    model: root.service ? root.service.alerts : []
    delegate: Row {
      required property var modelData
      required property int index
      spacing: Style.space(10)
      SquareSwitch {
        anchors.verticalCenter: parent.verticalCenter
        on: modelData.enabled !== false
        foreground: root.fg
        accent: root.aimed("alert", index) ? root.accent : root.fg
        onClicked: {
          var next = root.copy(modelData)
          next.enabled = modelData.enabled === false
          root.service.saveAlert(next)
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: modelData.name + "  " + modelData.min + "–" + modelData.max
        color: root.aimed("alert", index) ? root.accent : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.space(13)
      }
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: root.service && (root.service.connection === "need-token" || root.service.connection === "unauthorized")
    text: "Enter the CoolerControl password once. Omaflow uses 127.0.0.1:11987 and does not ask for an address. The token is saved and the password is not."
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.space(13)
  }

  Row {
    spacing: Style.space(8)
    visible: root.service && (root.service.connection === "need-token" || root.service.connection === "unauthorized")
    TextField {
      id: pairField
      width: Style.space(240)
      password: true
      placeholderText: "Password"
      foreground: root.fg
      accent: root.accent
    }
    Button {
      text: "Pair"
      bordered: true
      selected: true
      foreground: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      onClicked: {
        var password = pairField.text
        pairField.text = ""
        if (root.service) root.service.pair(password)
      }
    }
  }
}
