import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "CcMap.js" as Cc
import "Nav.js" as Nav
import "RepoPath.js" as Repo

// Daemon, AIO LCD, window, curves, and alerts. One subtab is on screen at a time.
Column {
  id: root

  property var service: null
  property bool keyed: false
  property int navIndex: 0
  property string section: "daemon"
  readonly property var sections: [
    { id: "daemon", label: "Daemon" },
    { id: "lcd", label: "AIO LCD" },
    { id: "window", label: "Window" },
    { id: "curves", label: "Curves" },
    { id: "alerts", label: "Alerts" }
  ]
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
    { key: "apply_on_boot", label: "Apply on boot" },
    { key: "hide_duplicate_devices", label: "Hide duplicate devices" },
    { key: "liquidctl_integration", label: "USB coolers through liquidctl" },
    { key: "compress", label: "Compress API responses" },
    { key: "sensors_conf_enabled", label: "Use sensors.conf labels" }
  ]
  property string barScript: Repo.rootFile("scripts/bar_plugin.py")
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
    var i
    var col = 0
    for (i = 0; i < sections.length; i++) {
      if (sections[i].id === section) col = i
      out.push({ kind: "section", index: i, x: i, y: 0 })
    }
    var row = 1
    function place(item) {
      item.x = col
      item.y = row
      row = row + 1
      out.push(item)
    }
    if (section === "daemon") {
      if (bootState !== "enabled" && service && service.daemonGate !== "install" && service.daemonGate !== "unknown")
        place({ kind: "boot", index: 0 })
      if (service && service.connection === "ready") {
        for (i = 0; i < switches.length; i++) place({ kind: "daemon", index: i })
      }
    } else if (section === "lcd") {
      place({ kind: "lcd", index: 0 })
      if (!service || service.lcdBackground !== false) place({ kind: "lcdSpeed", index: 0 })
    } else if (section === "window") {
      place({ kind: "fill", index: 0 })
      place({ kind: "pinGroups", index: 0 })
      place({ kind: "textFollow", index: 0 })
      place({ kind: "textSize", index: 0 })
      place({ kind: "bar", index: 0 })
    } else if (section === "curves") {
      place({ kind: "export", index: 0 })
      place({ kind: "import", index: 0 })
      place({ kind: "pumpFloor", index: 0 })
      place({ kind: "silentRamp", index: 0 })
      if (service && service.connection === "ready") {
        var fns = hopFunctions
        for (i = 0; i < fns.length; i++) place({ kind: "function", index: i })
      }
    } else if (section === "alerts") {
      if (service && service.connection === "ready") {
        var alerts = alertRows
        for (i = 0; i < alerts.length; i++) place({ kind: "alert", index: i })
      }
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
    var index = 1
    var i
    if (theme && service.lcdThemeSync === true) index = stops.length - 1
    else {
      for (i = 0; i < stops.length; i++) if (stops[i] === service.lcdSeconds) index = i
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
    // Left and right change subtabs only from the tab row. A control stays put.
    if (dx && !dy && (!item || item.kind !== "section")) return
    var next = Nav.step(items, navIndex, dx, dy)
    var landed = items[next]
    if (landed && landed.kind === "section" && sections[landed.index]) {
      var id = sections[landed.index].id
      if (id !== section) section = id
    }
    navIndex = next
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
    if (!item || item.kind === "section") return
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

  component SectionHead: Text {
    property string page: ""
    property bool pad: true
    property bool extra: true
    visible: root.section === page && extra
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.space(14)
    font.bold: true
    topPadding: pad ? Style.space(8) : 0
  }

  component MutedNote: Text {
    property string page: ""
    property bool shown: true
    property color ink: root.muted
    property int px: Style.font.caption
    width: parent.width
    wrapMode: Text.WordWrap
    visible: root.section === page && shown
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
    visible: root.section === page
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

  Row {
    id: sectionRow
    width: parent.width
    spacing: Style.space(6)

    Repeater {
      model: root.sections
      delegate: Rectangle {
        required property var modelData
        required property int index
        width: Math.max(0, (sectionRow.width - sectionRow.spacing * (root.sections.length - 1)) / root.sections.length)
        height: Style.space(32)
        radius: 0
        color: root.section === modelData.id
          ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
          : "transparent"
        border.width: 1
        border.color: root.aimed("section", index) || root.section === modelData.id ? root.accent : root.line
        Text {
          anchors.centerIn: parent
          width: parent.width - Style.space(8)
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
          text: modelData.label
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.space(12)
          font.bold: root.section === modelData.id
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.section = modelData.id
            root.navIndex = index
          }
        }
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

  SectionHead {
    text: "coolercontrold"
    page: "daemon"
    pad: false
  }

  MutedNote {
    page: "daemon"
    text: root.service && root.service.daemonGate === "install"
      ? "Install coolercontrold from the button above. Start with the PC stays off until you turn it on."
      : root.bootState === "enabled"
        ? "The daemon starts with the PC. Omaflow connects when it is up, including a window or bar chip that opened first."
        : "The daemon is not enabled at boot. One approval turns it on now and at the next start. If the prompt does not appear, run: sudo systemctl enable --now coolercontrold"
  }

  Row {
    spacing: Style.space(10)
    visible: root.section === "daemon" && root.bootState !== "enabled" && root.service && root.service.daemonGate !== "install" && root.service.daemonGate !== "unknown"
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

  SectionHead {
    text: "AIO LCD"
    page: "lcd"
  }

  ToggleRow {
    page: "lcd"
    aimKind: "lcd"
    label: "Keep updating"
    checked: !root.service || root.service.lcdBackground !== false
    onToggled: if (root.service) root.service.setUi({ lcdBackground: !(root.service.lcdBackground !== false) })
  }

  MutedNote {
    page: "lcd"
    text: "The cooler keeps the last picture it was sent. With this on, a new picture goes out on the interval below, including while this window is closed. Never leaves that picture in place. Picture mode always uses Never, and sends again only when its image changes. Omarchy waits for a theme change. Omarchy | Time updates once a minute. Only theme sync sends that logo when the theme changes and ignores the interval."
  }

  Flow {
    width: parent.width
    spacing: Style.space(8)
    visible: root.section === "lcd" && (!root.service || root.service.lcdBackground !== false)
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

  SectionHead {
    text: "Window"
    page: "window"
  }

  ToggleRow {
    page: "window"
    aimKind: "fill"
    label: "Fill this window"
    checked: root.service && root.service.dynamicScale === true
    onToggled: if (root.service) root.service.setUi({ dynamicScale: !(root.service.dynamicScale === true) })
  }

  MutedNote {
    page: "window"
    text: "The chart and the mode curve use the spare height. Speedometers and their titles grow a little. The rail, the LCD, and the text size stay as they are."
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
    text: "Custom groups stay below the hidden devices until this is on."
  }

  Row {
    spacing: Style.space(8)
    visible: root.section === "window"
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
    visible: root.section === "window"
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

  SectionHead {
    text: "Curves"
    page: "curves"
  }

  MutedNote {
    page: "curves"
    text: "Export writes every mode's curves and the shared groups. Import keeps them until you Apply a mode, so the other modes stay put. Groups that match this PC are saved immediately."
  }

  TextField {
    visible: root.section === "curves"
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
    visible: root.section === "curves"
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

  SectionHead {
    text: "Bar"
    page: "window"
  }

  Row {
    spacing: Style.space(10)
    visible: root.section === "window"
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

  MutedNote {
    page: "daemon"
    shown: root.service && root.service.connection === "ready"
    ink: root.fg
    px: Style.space(13)
    text: "Fan writes and sensor polls stay on coolercontrold. These are the daemon's own options."
  }

  Repeater {
    visible: root.section === "daemon"
    model: root.service && root.service.connection === "ready" ? root.switches : []
    delegate: Row {
      required property var modelData
      required property int index
      visible: root.section === "daemon"
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
    visible: root.section === "daemon"
    text: "Poll interval"
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Flow {
    width: parent.width
    spacing: Style.space(6)
    visible: root.section === "daemon"
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
    text: "Turning this off lets a pump stop, and a stopped pump can overheat the cooler. Turning it off asks for your password. Curves you already saved stay as they are until you edit them. Turning it back on raises any pump point below 50%."
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
    text: "A short CPU spike waits about 8 seconds before Silent fans rise. They also wait about 8 seconds before they fall. Pumps are left alone. Silent, Fixed, Performance, Hell, and any custom mode each keep their own fan and group curves, even when the speeds match. Easing Silent does not slow the other modes."
  }

  MutedNote {
    page: "curves"
    shown: root.service && (root.service.silentRampBusy || root.service.silentRampNote !== "")
    ink: root.fg
    text: root.service && root.service.silentRampBusy
      ? (root.service.silentRampNote !== "" ? root.service.silentRampNote : "Applying the Silent pace.")
      : (root.service ? root.service.silentRampNote : "")
  }

  SectionHead {
    text: "Curve response"
    page: "curves"
  }

  Repeater {
    visible: root.section === "curves"
    model: root.hopFunctions
    delegate: Row {
      required property var modelData
      required property int index
      visible: root.section === "curves"
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

  MutedNote {
    page: "alerts"
    shown: !(root.service && root.service.connection === "ready")
    text: "Alerts show up after Omaflow is connected to coolercontrold."
  }

  SectionHead {
    text: "Alerts"
    page: "alerts"
    pad: false
    extra: root.service && root.service.connection === "ready"
  }

  MutedNote {
    page: "alerts"
    shown: root.service && root.service.connection === "ready" && root.alertRows.length === 0
    px: Style.space(12)
    text: "No temperature sensor for an alert."
  }

  Repeater {
    visible: root.section === "alerts"
    model: root.alertRows
    delegate: Row {
      required property var modelData
      required property int index
      visible: root.section === "alerts"
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
        color: root.aimed("alert", index) ? root.accent : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.space(13)
      }
    }
  }

  MutedNote {
    page: "alerts"
    shown: root.service && root.service.connection === "ready"
    text: "A desktop notification is sent when the temperature stays outside the range. Nothing shuts the PC down."
  }
}
