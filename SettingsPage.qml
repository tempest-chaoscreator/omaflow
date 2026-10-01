import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "CcMap.js" as Cc
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
  property color line: Qt.rgba(fg.r, fg.g, fg.b, 0.35)
  property string fontFamily: Style.font.family
  property int shellTextPx: 12
  property string curvePath: ""
  property string curveNote: ""
  property string bootState: ""
  property string bootNote: ""
  property bool bootBusy: false
  property string bootLine: ""
  readonly property var textStops: [9, 10, 11, 12, 14, 16, 20]

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
  property bool barOn: true
  property bool barLive: false
  property bool barStatusKnown: false
  property bool barBusy: false
  property string barPending: ""
  property int barKickTries: 0
  property string barNote: ""
  // U+F0210 plus the hottest CPU or GPU temperature. Same string the bar draws.
  readonly property string barPreview: {
    var hot = service && service.temps ? Number(service.temps.hottest) : NaN
    var temp = isFinite(hot) ? Math.round(hot) + "°" : "…"
    return "\uDB80\uDE10 " + temp
  }

  readonly property var navItems: {
    var out = []
    var i
    function place(item) {
      item.x = 0
      item.y = out.length
      out.push(item)
    }
    if (bootState !== "enabled") place({ kind: "boot", index: 0 })
    place({ kind: "fill", index: 0 })
    place({ kind: "textFollow", index: 0 })
    place({ kind: "textSize", index: 0 })
    place({ kind: "export", index: 0 })
    place({ kind: "import", index: 0 })
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

  function nearestStop(px) {
    var best = 0
    var diff = 1000
    var i
    for (i = 0; i < textStops.length; i++) {
      var d = Math.abs(textStops[i] - Number(px))
      if (d < diff) {
        diff = d
        best = i
      }
    }
    return best
  }

  function shownTextIndex() {
    var follow = !service || service.textFollow !== false
    var px = follow ? shellTextPx : (service ? service.textSize : shellTextPx)
    return nearestStop(px)
  }

  function stepText(dx) {
    if (!service) return
    var index = shownTextIndex() + dx
    if (index < 0) index = 0
    if (index > textStops.length - 1) index = textStops.length - 1
    service.setUi({ textFollow: false, textSize: textStops[index] })
  }

  function pickText(x) {
    if (!service || textTrack.width <= 0) return
    var span = Math.max(1, textStops.length - 1)
    var usable = Math.max(1, textTrack.width - textTrack.inset * 2)
    var index = Math.round(((Number(x) - textTrack.inset) / usable) * span)
    if (index < 0) index = 0
    if (index > span) index = span
    service.setUi({ textFollow: false, textSize: textStops[index] })
  }

  function enableBoot() {
    if (bootState === "enabled" || bootBusy || bootEnable.running) return
    bootBusy = true
    bootNote = ""
    bootEnable.running = true
  }

  function refreshBoot() {
    if (bootQuery.running) return
    bootLine = ""
    bootQuery.running = true
  }

  function exportPack() {
    if (!service || !service.writeUserFile) return
    var pack = Cc.buildCurvePack(service.modes, service.channels, service.profiles, service.groups)
    curveNote = ""
    service.writeUserFile(curvePath, pack, function(res) {
      root.curveNote = res && res.ok ? ("Wrote " + root.curvePath) : ((res && res.error) || "Export failed")
    })
  }

  function mergeImportedGroups(imported) {
    var current = service.groups || []
    var next = []
    var i
    for (i = 0; i < current.length; i++) next.push(current[i])
    for (i = 0; i < imported.length; i++) {
      var incoming = imported[i]
      var name = String(incoming.name || "").toLowerCase()
      var found = -1
      var g
      for (g = 0; g < next.length; g++) {
        if (String(next[g].name || "").toLowerCase() === name) {
          found = g
          break
        }
      }
      if (found >= 0) {
        var kept = next[found]
        next[found] = {
          id: kept.id || incoming.id,
          name: incoming.name || kept.name,
          profileUid: kept.profileUid || "",
          members: incoming.members
        }
      } else next.push(incoming)
    }
    return next
  }

  function importPack() {
    if (!service || !service.readUserFile) return
    curveNote = ""
    service.readUserFile(curvePath, function(res) {
      if (!res || !res.ok) {
        root.curveNote = (res && res.error) || "Import failed"
        return
      }
      var pack = res.body
      if (!Cc.validCurvePack(pack)) {
        root.curveNote = "That file is not an Omaflow curve pack"
        return
      }
      service.setCurvePack(pack)
      var groups = Cc.remapGroups(pack, service.channels, function() { return service.newUid() })
      if (groups.length) service.saveGroups(root.mergeImportedGroups(groups))
      var count = (pack.modes || []).length
      root.curveNote = groups.length
        ? ("Loaded " + count + " modes and updated groups. Apply each mode to write its curves.")
        : ("Loaded " + count + " modes. Apply each mode to write its curves.")
    })
  }

  function moveNav(dx, dy) {
    var item = navItems.length ? navItems[Math.max(0, Math.min(navItems.length - 1, navIndex))] : null
    if (item && item.kind === "textSize" && dx && !dy) {
      stepText(dx)
      return
    }
    navIndex = Nav.step(navItems, navIndex, dx, dy)
  }

  function aimed(kind, index) {
    if (!keyed || !navItems.length) return false
    var item = navItems[Math.max(0, Math.min(navItems.length - 1, navIndex))]
    return item && item.kind === kind && item.index === index
  }

  function runBar(action) {
    if (barProc.running) {
      barPending = action
      return
    }
    barPending = ""
    barBusy = true
    barProc.command = ["python3", "-u", barScript, action]
    barProc.running = true
  }

  function takeBar(line) {
    var obj
    try { obj = JSON.parse(String(line || "")) } catch (e) { return }
    if (!obj) return
    if (obj.enabled !== undefined) {
      barLive = obj.enabled === true
      barStatusKnown = true
      // A click already queued the next action. Keep that preview until it finishes.
      if (barPending === "") barOn = barLive
    }
    barNote = obj.error ? String(obj.error) : ""
  }

  // Fresh installs show the chip. A saved off stays off, and a chip that is
  // already on is left alone.
  function reconcileBar() {
    if (!barStatusKnown || !service || service.uiReady !== true) return
    if (barProc.running || barPending !== "") return
    if (service.showBar === false || barLive) return
    runBar("enable")
  }

  function setBar(on) {
    barOn = on === true
    if (service) service.setUi({ showBar: barOn })
    runBar(barOn ? "enable" : "disable")
  }

  function continueBar() {
    if (barProc.running && barKickTries < 4) {
      barKickTries = barKickTries + 1
      barKick.restart()
      return
    }
    barKickTries = 0
    var next = barPending
    barPending = ""
    if (next) {
      runBar(next)
      return
    }
    barBusy = false
    reconcileBar()
  }

  function activateNav() {
    var item = navItems[navIndex]
    if (!item) return
    if (item.kind === "boot") {
      enableBoot()
      return
    }
    if (item.kind === "fill") {
      if (service) service.setUi({ dynamicScale: !(service.dynamicScale === true) })
      return
    }
    if (item.kind === "textFollow") {
      if (!service) return
      if (service.textFollow === false) service.setUi({ textFollow: true })
      else service.setUi({ textFollow: false, textSize: textStops[nearestStop(shellTextPx)] })
      return
    }
    if (item.kind === "export") {
      exportPack()
      return
    }
    if (item.kind === "import") {
      importPack()
      return
    }
    if (item.kind === "bar") {
      setBar(!barOn)
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

  Process {
    id: barProc
    stdout: SplitParser {
      onRead: function(line) { root.takeBar(line) }
    }
    stderr: SplitParser {
      onRead: function(line) { root.barNote = String(line) }
    }
    onExited: Qt.callLater(root.continueBar)
  }

  Timer {
    id: barKick
    interval: 0
    repeat: false
    onTriggered: root.continueBar()
  }

  Connections {
    target: root.service
    function onUiReadyChanged() {
      if (root.service && root.service.uiReady) root.reconcileBar()
    }
  }

  Component.onCompleted: {
    if (!curvePath) curvePath = Quickshell.env("HOME") + "/Documents/omaflow-curves.json"
    root.runBar("status")
    root.refreshBoot()
  }

  Timer {
    interval: 4000
    repeat: true
    running: root.visible
    onTriggered: root.refreshBoot()
  }

  Process {
    id: bootQuery
    command: ["systemctl", "is-enabled", "coolercontrold"]
    stdout: SplitParser {
      onRead: function(line) { root.bootLine = String(line || "").replace(/^\s+|\s+$/g, "") }
    }
    onExited: function() {
      root.bootState = root.bootLine || "disabled"
    }
  }

  Process {
    id: bootEnable
    command: ["pkexec", "systemctl", "enable", "--now", "coolercontrold"]
    stderr: SplitParser {
      onRead: function(line) { root.bootNote = String(line || "") }
    }
    onExited: function(code) {
      root.bootBusy = false
      if (code !== 0 && !root.bootNote)
        root.bootNote = "Omaflow could not enable the daemon. In a terminal: sudo systemctl enable --now coolercontrold"
      root.refreshBoot()
    }
  }

  Text {
    text: "coolercontrold"
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.space(14)
    font.bold: true
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: root.bootState === "enabled"
      ? "The daemon starts with the PC. Omaflow connects when it is up, including a window or bar chip that opened first."
      : "The daemon is not enabled at boot. One approval turns it on now and at the next start. If the prompt does not appear, run: sudo systemctl enable --now coolercontrold"
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Row {
    spacing: Style.space(10)
    visible: root.bootState !== "enabled"
    Button {
      text: root.bootBusy ? "Waiting" : "Start with the PC"
      bordered: true
      selected: root.aimed("boot", 0)
      foreground: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.enableBoot()
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: root.bootNote !== ""
    text: root.bootNote
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    text: "Window"
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.space(14)
    font.bold: true
    topPadding: Style.space(8)
  }

  Row {
    spacing: Style.space(10)
    SquareSwitch {
      anchors.verticalCenter: parent.verticalCenter
      on: root.service && root.service.dynamicScale === true
      foreground: root.fg
      accent: root.aimed("fill", 0) ? root.accent : root.fg
      onClicked: if (root.service) root.service.setUi({ dynamicScale: !(root.service.dynamicScale === true) })
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "Fill this window"
      color: root.aimed("fill", 0) ? root.accent : root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.space(13)
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "The chart and the mode curve use the spare height. Speedometers and their titles grow a little. The rail, the LCD, and the text size stay as they are."
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Row {
    spacing: Style.space(8)
    Button {
      text: "Follow Omarchy"
      bordered: true
      selected: !root.service || root.service.textFollow !== false
      foreground: root.fg
      accent: root.aimed("textFollow", 0) ? root.accent : root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: if (root.service) root.service.setUi({ textFollow: true })
    }
    Button {
      text: "Override"
      bordered: true
      selected: root.service && root.service.textFollow === false
      foreground: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: {
        if (!root.service || root.service.textFollow === false) return
        root.service.setUi({ textFollow: false, textSize: root.textStops[root.nearestStop(root.shellTextPx)] })
      }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.textStops[root.shownTextIndex()] + " px"
        + (root.service && root.service.textFollow === false ? "  your override" : "  follows Omarchy")
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Item {
    id: textTrack
    width: Math.min(parent.width, Style.space(420))
    height: Style.space(52)
    readonly property real inset: Style.space(14)
    readonly property real span: Math.max(1, width - inset * 2)

    Rectangle {
      x: textTrack.inset
      width: textTrack.span
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: -Style.space(6)
      height: 1
      color: root.aimed("textSize", 0) ? root.accent : root.line
    }

    Repeater {
      model: root.textStops
      delegate: Item {
        required property var modelData
        required property int index
        x: textTrack.inset + index * (textTrack.span / Math.max(1, root.textStops.length - 1))
        width: 0
        height: parent.height

        Rectangle {
          width: index === root.shownTextIndex() ? Style.space(9) : Style.space(6)
          height: width
          radius: width / 2
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: -Style.space(6)
          color: index === root.shownTextIndex() ? root.accent : root.fg
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          text: modelData
          color: index === root.shownTextIndex() ? root.accent : root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      onPressed: function(mouse) { root.pickText(mouse.x) }
      onPositionChanged: function(mouse) { if (pressed) root.pickText(mouse.x) }
    }
  }

  Text {
    text: "Curves"
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.space(14)
    font.bold: true
    topPadding: Style.space(8)
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Export writes every mode's curves and the shared groups. Import keeps them until you Apply a mode, so the other modes stay put. Groups that match this PC are saved immediately."
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  TextField {
    width: Math.min(parent.width, Style.space(520))
    text: root.curvePath
    placeholderText: "Path to a .json file"
    foreground: root.fg
    accent: root.accent
    font.pixelSize: Style.font.caption
    onTextEdited: root.curvePath = text
  }

  Row {
    spacing: Style.space(8)
    Button {
      text: "Export"
      bordered: true
      selected: root.aimed("export", 0)
      foreground: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.exportPack()
    }
    Button {
      text: "Import"
      bordered: true
      selected: root.aimed("import", 0)
      foreground: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.importPack()
    }
    Button {
      visible: root.service && root.service.curvePack && root.service.curvePack.kind === "omaflow-curves"
      text: "Clear pack"
      bordered: true
      foreground: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: if (root.service) root.service.clearCurvePack()
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: root.curveNote !== ""
    text: root.curveNote
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    text: "Bar"
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.space(14)
    font.bold: true
    topPadding: Style.space(8)
  }

  Row {
    spacing: Style.space(10)
    SquareSwitch {
      anchors.verticalCenter: parent.verticalCenter
      on: root.barOn
      switchEnabled: !root.barBusy
      foreground: root.fg
      accent: root.aimed("bar", 0) ? root.accent : root.fg
      onClicked: root.setBar(!root.barOn)
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.barPreview
      textFormat: Text.PlainText
      renderType: Text.NativeRendering
      color: root.barOn ? root.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.38)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
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
    visible: root.barNote !== ""
    text: root.barNote
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
