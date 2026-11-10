import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "CcMap.js" as Cc
import "Marks.js" as Marks
import "Nav.js" as Nav
import "RepoPath.js" as Repo

// Daemon, AIO LCD, window, curves, and alerts. Each subject is one bordered box.
Column {
  id: root

  property var service: null
  property bool keyed: false
  property int navIndex: 0
  property real followY: 0
  onKeyedChanged: if (keyed) revealNav()
  property color fg: Commons.Color.foreground
  property color accent: Commons.Color.accent
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
  // Buttons call into functions, so this key is what makes them repaint.
  readonly property string lcdSpeedKey: {
    var face = service && service.lcdFace ? service.lcdFace : "liquid"
    var seconds = service ? service.lcdSeconds : 5
    var theme = service && service.lcdThemeSync === true
    var keep = !service || service.lcdBackground !== false
    return face + "|" + seconds + "|" + theme + "|" + keep
  }

  width: parent ? parent.width : 0
  spacing: Style.space(12)

  readonly property var switches: [
    { key: "apply_on_boot", label: "Apply on boot", hint: "The saved mode is applied when the daemon starts." },
    { key: "hide_duplicate_devices", label: "Hide duplicate devices", hint: "A device reported twice is listed once." },
    { key: "liquidctl_integration", label: "USB coolers through liquidctl", hint: "USB coolers are read through liquidctl." },
    { key: "compress", label: "Compress API responses", hint: "Daemon replies are compressed." },
    { key: "sensors_conf_enabled", label: "Use sensors.conf labels", hint: "Sensor names come from sensors.conf." }
  ]
  property string barScript: Repo.rootFile("scripts/bar_plugin.py")
  property bool barOn: true
  property bool barLive: false
  property bool barStatusKnown: false
  property bool barBusy: false
  property string barPending: ""
  property int barKickTries: 0
  property string barNote: ""
  readonly property string barPreview: {
    var raw = service && service.temps ? service.temps.hottest : null
    var hot = (raw === null || raw === undefined || raw === "") ? NaN : Number(raw)
    var temp = isFinite(hot) ? Math.round(hot) + "°" : "…"
    return Marks.fan + " " + temp
  }

  readonly property var hopFunctions: {
    var list = service && service.functions ? service.functions : []
    var out = []
    var i
    for (i = 0; i < list.length; i++) {
      var fn = list[i]
      if (!fn || String(fn.name || "") === "Omaflow silent ramp") continue
      out.push(fn)
    }
    return out
  }

  readonly property var alertRows: {
    if (!service || service.connection !== "ready") return []
    var sensors = Cc.alertSensors(service.devices)
    var presets = [
      { name: "CPU 90°C", max: 90, source: sensors.cpu },
      { name: "GPU 88°C", max: 88, source: sensors.gpu },
      { name: "Coolant 50°C", max: 50, source: sensors.coolant }
    ]
    var out = []
    var i
    for (i = 0; i < presets.length; i++) {
      if (!presets[i].source) continue
      var existing = Cc.alertNamed(service.alerts, presets[i].name)
      out.push({
        kind: "preset",
        name: presets[i].name,
        max: presets[i].max,
        source: presets[i].source,
        alert: existing,
        on: !!(existing && existing.enabled !== false)
      })
    }
    var alerts = service.alerts || []
    for (i = 0; i < alerts.length; i++) {
      var alert = alerts[i]
      if (!alert) continue
      var name = String(alert.name || "")
      if (name === "CPU 90°C" || name === "GPU 88°C" || name === "Coolant 50°C") continue
      out.push({
        kind: "custom",
        name: name,
        max: Number(alert.max),
        source: null,
        alert: alert,
        on: alert.enabled !== false
      })
    }
    return out
  }

  readonly property var navItems: {
    var out = []
    var y = 0
    var i
    function place(item) {
      item.x = 0
      item.y = y
      y = y + 1
      out.push(item)
    }
    if (service && (service.connection === "need-token" || service.connection === "unauthorized"))
      place({ kind: "pair", index: 0 })
    if (bootState !== "enabled" && service && service.daemonGate !== "install" && service.daemonGate !== "unknown")
      place({ kind: "boot", index: 0 })
    if (service && service.connection === "ready") {
      for (i = 0; i < switches.length; i++) place({ kind: "daemon", index: i })
    }
    place({ kind: "lcd", index: 0 })
    if (!service || service.lcdBackground !== false) place({ kind: "lcdSpeed", index: 0 })
    place({ kind: "fill", index: 0 })
    place({ kind: "pinGroups", index: 0 })
    place({ kind: "textFollow", index: 0 })
    place({ kind: "textSize", index: 0 })
    place({ kind: "bar", index: 0 })
    place({ kind: "export", index: 0 })
    place({ kind: "import", index: 0 })
    place({ kind: "pumpFloor", index: 0 })
    place({ kind: "silentRamp", index: 0 })
    if (service && service.connection === "ready") {
      var fns = hopFunctions
      for (i = 0; i < fns.length; i++) place({ kind: "function", index: i })
    }
    if (service && service.connection === "ready") {
      var alerts = alertRows
      for (i = 0; i < alerts.length; i++) place({ kind: "alert", index: i })
    }
    return out
  }

  function alertCaption(row) {
    if (!row) return ""
    var state = row.alert ? Cc.alertStateLabel(row.alert) : "Off"
    if (row.kind === "custom" && row.alert)
      return row.name + "  " + row.alert.min + "–" + row.alert.max + "  " + state
    return row.name + "  " + state
  }

  function toggleAlertRow(row) {
    if (!service || !row) return
    if (row.alert) service.setAlertEnabled(row.alert, !(row.alert.enabled !== false))
    else if (row.source) service.createAlert(row.name, row.max, row.source)
  }

  function patch(key, value) {
    if (!service || !service.daemonSettings) return
    var next = Cc.copyMap(service.daemonSettings)
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

  function lcdFace() {
    return service && service.lcdFace ? String(service.lcdFace) : "liquid"
  }

  // One line for the interval that is actually selected.
  function lcdIntervalNote() {
    var face = lcdFace()
    if (!service || service.lcdBackground === false)
      return "Updating is off. The cooler keeps the last picture."
    if (face === "picture") return "Picture mode sends again only when its image changes."
    if (face === "omarchy" && service.lcdThemeSync === true)
      return "The Omarchy logo is sent when the theme changes."
    if (face === "omarchy-time") return "The logo and the time update about once a minute."
    var seconds = service.lcdSeconds
    if (seconds === 0) return "The cooler keeps the last picture."
    return "A new picture goes out every " + seconds + " seconds, including while this window is closed."
  }

  function secondsLookSelected(seconds) {
    if (!service) return seconds === 5
    if (lcdFace() === "picture") return seconds === 0
    if (lcdFace() === "omarchy-time") return seconds === 60
    if (lcdFace() === "omarchy" && service.lcdThemeSync === true) return false
    return service.lcdSeconds === seconds
  }

  function secondsDimmed(seconds) {
    if (lcdFace() === "picture") return seconds !== 0
    return lcdFace() === "omarchy-time" && seconds !== 60
  }

  function themeSyncDimmed() {
    if (!service || service.lcdBackground === false) return true
    return lcdFace() !== "omarchy"
  }

  function pickLcdSeconds(seconds) {
    if (!service || lcdFace() === "omarchy-time" || lcdFace() === "picture") return
    if (lcdFace() === "omarchy") service.setUi({ lcdSeconds: seconds, lcdThemeSync: false })
    else service.setUi({ lcdSeconds: seconds })
  }

  function pickThemeSync() {
    if (!service || themeSyncDimmed()) return
    service.setUi({ lcdThemeSync: true })
  }

  function stepLcd(dx) {
    if (!service || lcdFace() === "omarchy-time" || lcdFace() === "picture") return
    var theme = lcdFace() === "omarchy"
    var stops = theme ? [0, 2, 5, 10, 30, 60, "theme"] : [0, 2, 5, 10, 30, 60]
    var index = 0
    var i
    if (theme && service.lcdThemeSync === true) index = stops.length - 1
    else {
      var seconds = Number(service.lcdSeconds)
      var best = 0
      var diff = 100000
      for (i = 0; i < stops.length; i++) {
        if (stops[i] === "theme") continue
        if (stops[i] === seconds) { best = i; break }
        var apart = Math.abs(stops[i] - seconds)
        if (apart < diff) { diff = apart; best = i }
      }
      index = best
    }
    index = index + dx
    if (index < 0) index = 0
    if (index > stops.length - 1) index = stops.length - 1
    if (stops[index] === "theme") service.setUi({ lcdThemeSync: true })
    else if (theme) service.setUi({ lcdSeconds: stops[index], lcdThemeSync: false })
    else service.setUi({ lcdSeconds: stops[index] })
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
    var items = navItems
    var item = items.length ? items[Math.max(0, Math.min(items.length - 1, navIndex))] : null
    if (item && item.kind === "textSize" && dx && !dy) {
      stepText(dx)
      return
    }
    if (item && item.kind === "lcdSpeed" && dx && !dy) {
      stepLcd(dx)
      return
    }
    // Left and right step a slider. Up and down move to the next control.
    if (dx && !dy) return
    navIndex = Nav.step(items, navIndex, dx, dy)
    revealNav()
  }

  function reveal(kind) {
    if (kind === "pair") {
      followY = 0
      return
    }
    var item = daemonBox
    if (kind === "lcd" || kind === "lcdSpeed") item = lcdBox
    else if (kind === "fill" || kind === "pinGroups" || kind === "textFollow" || kind === "textSize" || kind === "bar") item = windowBox
    else if (kind === "export" || kind === "import" || kind === "pumpFloor" || kind === "silentRamp" || kind === "function") item = curvesBox
    else if (kind === "alert") item = alertsBox
    if (item) followY = item.y
  }

  function revealNav() {
    var items = navItems
    if (!items.length) return
    var item = items[Math.max(0, Math.min(items.length - 1, navIndex))]
    if (item) reveal(item.kind)
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

  function submitPair() {
    var password = pairField.text
    pairField.text = ""
    if (service) service.pair(password)
  }

  function activateNav() {
    var item = navItems[navIndex]
    if (!item) return
    if (item.kind === "pair") {
      submitPair()
      return
    }
    if (item.kind === "boot") {
      enableBoot()
      return
    }
    if (item.kind === "lcd") {
      if (service) service.setUi({ lcdBackground: !(service.lcdBackground !== false) })
      return
    }
    if (item.kind === "lcdSpeed") {
      stepLcd(1)
      return
    }
    if (item.kind === "fill") {
      if (service) service.setUi({ dynamicScale: !(service.dynamicScale === true) })
      return
    }
    if (item.kind === "pinGroups") {
      if (service) service.setUi({ pinGroups: !(service.pinGroups === true) })
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
    if (item.kind === "pumpFloor") {
      if (service.pumpFloor) service.requestPumpFloorOff()
      else service.enablePumpFloor()
      return
    }
    if (item.kind === "silentRamp") {
      service.setSilentRamp(!(service.silentRamp === true))
      return
    }
    if (item.kind === "daemon") {
      var row = switches[item.index]
      var current = service.daemonSettings ? service.daemonSettings[row.key] === true : false
      patch(row.key, !current)
    } else if (item.kind === "function") {
      var fn = hopFunctions[item.index]
      if (!fn) return
      var next = copy(fn)
      next.threshold_hopping = !fn.threshold_hopping
      service.saveFunction(next)
    } else if (item.kind === "alert") {
      toggleAlertRow(alertRows[item.index])
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

  component SectionBox: Rectangle {
    id: box
    property string heading: ""
    property string mark: ""
    default property alias body: bodyCol.data
    width: parent ? parent.width : 0
    implicitHeight: layout.implicitHeight + Style.space(20)
    color: "transparent"
    border.width: 1
    border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.22)

    Column {
      id: layout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      spacing: Style.space(8)

      Row {
        spacing: Style.space(8)
        visible: box.heading !== ""

        OpticalGlyph {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(16)
          height: Style.space(16)
          text: box.mark
          fontFamily: root.fontFamily
          fontSize: Style.space(14)
          color: root.accent
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: box.heading
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.space(13)
          font.bold: true
        }
      }

      Column {
        id: bodyCol
        width: parent.width
        spacing: Style.space(8)
      }
    }
  }

  component MutedNote: Text {
    property string page: ""
    property bool shown: true
    property color ink: root.muted
    property int px: Style.font.caption
    width: parent.width
    wrapMode: Text.WordWrap
    visible: shown
    textFormat: Text.PlainText
    color: ink
    font.family: root.fontFamily
    font.pixelSize: px
  }

  component ToggleRow: Row {
    id: toggleRow
    property string page: ""
    property string aimKind: ""
    property int aimIndex: 0
    property string label: ""
    property bool checked: false
    signal toggled()
    spacing: Style.space(10)
    SquareSwitch {
      anchors.verticalCenter: parent.verticalCenter
      on: toggleRow.checked
      foreground: root.fg
      accent: root.aimed(toggleRow.aimKind, toggleRow.aimIndex) ? root.accent : root.fg
      onClicked: toggleRow.toggled()
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: toggleRow.label
      color: root.aimed(toggleRow.aimKind, toggleRow.aimIndex) ? root.accent : root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.space(13)
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: root.service && root.service.lastError !== ""
    text: root.service ? root.service.lastError : ""
    textFormat: Text.PlainText
    color: Commons.Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
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
      onAccepted: root.submitPair()
    }
    Button {
      text: "Pair"
      bordered: true
      selected: root.aimed("pair", 0)
      foreground: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      onClicked: root.submitPair()
    }
  }

  SectionBox {
    id: daemonBox
    heading: "Daemon"
    mark: Marks.power

  MutedNote {
    page: "daemon"
    text: root.service && root.service.daemonGate === "install"
      ? "Install coolercontrold above. Start with the PC stays off until then."
      : root.bootState === "enabled"
        ? "Starts with the PC."
        : "Off at boot. Start with the PC turns it on now and at the next start."
  }

  Row {
    spacing: Style.space(10)
    visible: root.bootState !== "enabled" && root.service && root.service.daemonGate !== "install" && root.service.daemonGate !== "unknown"
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

  MutedNote {
    page: "daemon"
    shown: root.bootNote !== ""
    ink: root.fg
    text: root.bootNote
  }

    Repeater {
      model: root.service && root.service.connection === "ready" ? root.switches : []
      delegate: Column {
        required property var modelData
        required property int index
        width: parent.width
        spacing: Style.space(2)
        Row {
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
        MutedNote {
          page: "daemon"
          text: modelData.hint
        }
      }
    }

  }

  SectionBox {
    id: lcdBox
    heading: "AIO LCD"
    mark: Marks.lcd

  ToggleRow {
    page: "lcd"
    aimKind: "lcd"
    label: "Keep updating"
    checked: !root.service || root.service.lcdBackground !== false
    onToggled: if (root.service) root.service.setUi({ lcdBackground: !(root.service.lcdBackground !== false) })
  }

  Text {
    width: parent.width
    visible: !root.service || root.service.lcdBackground !== false
    text: "Update interval"
    color: root.aimed("lcdSpeed", 0) ? root.accent : root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.space(13)
    font.bold: true
  }

  Flow {
    width: parent.width
    spacing: Style.space(8)
    visible: !root.service || root.service.lcdBackground !== false
    Repeater {
      model: [0, 2, 5, 10, 30, 60]
      delegate: Button {
        required property var modelData
        text: modelData === 0 ? "Never" : modelData + "s"
        bordered: true
        selected: root.lcdSpeedKey.length > 0 && root.secondsLookSelected(modelData)
        opacity: root.lcdSpeedKey.length > 0 && root.secondsDimmed(modelData) ? 0.38 : 1
        foreground: root.fg
        accent: root.aimed("lcdSpeed", 0) ? root.accent : root.fg
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        onClicked: root.pickLcdSeconds(modelData)
      }
    }
    Button {
      text: "Only theme sync"
      bordered: true
      selected: root.lcdSpeedKey.length > 0 && root.service && root.service.lcdFace === "omarchy" && root.service.lcdThemeSync === true
      opacity: root.lcdSpeedKey.length > 0 && root.themeSyncDimmed() ? 0.38 : 1
      foreground: root.fg
      accent: root.aimed("lcdSpeed", 0) ? root.accent : root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.pickThemeSync()
    }
  }

  MutedNote {
    page: "lcd"
    text: root.lcdIntervalNote()
  }

  }

  SectionBox {
    id: windowBox
    heading: "Window"
    mark: Marks.frame

  ToggleRow {
    page: "window"
    aimKind: "fill"
    label: "Fill this window"
    checked: root.service && root.service.dynamicScale === true
    onToggled: if (root.service) root.service.setUi({ dynamicScale: !(root.service.dynamicScale === true) })
  }

  MutedNote {
    page: "window"
    text: "The chart and the mode curve use the spare height. The rail and the text size stay as they are."
  }

  ToggleRow {
    page: "window"
    aimKind: "pinGroups"
    label: "Pin groups on Devices"
    checked: root.service && root.service.pinGroups === true
    onToggled: if (root.service) root.service.setUi({ pinGroups: !(root.service.pinGroups === true) })
  }

  MutedNote {
    page: "window"
    text: "Groups stay above the device list."
  }

  Row {
    spacing: Style.space(8)
    OpticalGlyph {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(16)
      height: Style.space(16)
      text: "\uf031"
      fontFamily: root.fontFamily
      fontSize: Style.space(14)
      color: root.fg
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "Text"
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.space(13)
      font.bold: true
    }
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
      width: parent.width
      text: "Bar"
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.space(13)
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

    MutedNote {
      page: "window"
      shown: root.barNote !== ""
      text: root.barNote
    }

  }

  SectionBox {
    id: curvesBox
    heading: "Curves"
    mark: Marks.curve

  MutedNote {
    page: "curves"
    text: "Export writes every mode. Import waits until you Apply. Matching groups are saved immediately."
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

  MutedNote {
    page: "curves"
    shown: root.curveNote !== ""
    ink: root.fg
    text: root.curveNote
  }

  ToggleRow {
    page: "curves"
    aimKind: "pumpFloor"
    label: "Keep pumps at or above 50%"
    checked: !root.service || root.service.pumpFloor !== false
    onToggled: {
      if (!root.service || root.service.pumpFloorBusy) return
      if (root.service.pumpFloor) root.service.requestPumpFloorOff()
      else root.service.enablePumpFloor()
    }
  }

  MutedNote {
    page: "curves"
    text: "Off lets a pump stop. Turning it off asks for your password. On raises any pump point below 50%."
  }

  MutedNote {
    page: "curves"
    shown: root.service && (root.service.pumpFloorBusy || root.service.pumpFloorNote !== "")
    ink: root.fg
    text: root.service && root.service.pumpFloorBusy ? "Waiting for the password." : (root.service ? root.service.pumpFloorNote : "")
  }

  ToggleRow {
    page: "curves"
    aimKind: "silentRamp"
    label: "Ease Silent fans"
    checked: root.service && root.service.silentRamp === true
    onToggled: {
      if (!root.service || root.service.silentRampBusy) return
      root.service.setSilentRamp(!(root.service.silentRamp === true))
    }
  }

  MutedNote {
    page: "curves"
    text: "Silent fans wait about 8 seconds before they rise or fall. Other modes are left alone."
  }

  MutedNote {
    page: "curves"
    shown: root.service && (root.service.silentRampBusy || root.service.silentRampNote !== "")
    ink: root.fg
    text: root.service && root.service.silentRampBusy
      ? (root.service.silentRampNote !== "" ? root.service.silentRampNote : "Applying the Silent pace.")
      : (root.service ? root.service.silentRampNote : "")
  }

    Text {
      width: parent.width
      visible: root.hopFunctions.length > 0
      text: "Curve response"
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.space(13)
      font.bold: true
    }

    MutedNote {
      page: "curves"
      shown: root.hopFunctions.length > 0
      text: "On, a fan that holds one speed for 30 seconds skips its step limit and finishes the move to the curve."
    }

  Repeater {
    model: root.hopFunctions
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
        text: modelData.name
        textFormat: Text.PlainText
        color: root.aimed("function", index) ? root.accent : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.space(13)
      }
    }
  }

  }

  SectionBox {
    id: alertsBox
    heading: "Alerts"
    mark: Marks.alerts

    MutedNote {
      page: "alerts"
      shown: !(root.service && root.service.connection === "ready")
      text: "Alerts show up after Omaflow is connected to coolercontrold."
    }

  MutedNote {
    page: "alerts"
    shown: root.service && root.service.connection === "ready" && root.alertRows.length === 0
    px: Style.space(12)
    text: "No temperature sensor for an alert."
  }

  Repeater {
    model: root.alertRows
    delegate: Row {
      required property var modelData
      required property int index
      spacing: Style.space(10)
      SquareSwitch {
        anchors.verticalCenter: parent.verticalCenter
        on: modelData.on === true
        foreground: root.fg
        accent: root.aimed("alert", index) ? root.accent : root.fg
        onClicked: root.toggleAlertRow(modelData)
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.alertCaption(modelData)
        textFormat: Text.PlainText
        color: root.aimed("alert", index) ? root.accent : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.space(13)
      }
    }
  }

  MutedNote {
    page: "alerts"
    shown: root.service && root.service.connection === "ready"
    text: "A notification is sent when a temperature stays out of range. The PC stays on."
  }

  }
}
