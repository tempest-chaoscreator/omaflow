import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "CcMap.js" as Cc
import "Marks.js" as Marks
import "Nav.js" as Nav
import "ProcessScale.js" as Scale
import "ThemePalette.js" as ThemePalette

// CPU, GPU, and liquid sit above one chart. Fan speedometers follow the Modes groups.
Column {
  id: root

  property var service: null
  property bool keyed: false
  property int navIndex: 0
  property color fg: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color muted: Qt.darker(fg, 1.4)
  property color line: Qt.rgba(fg.r, fg.g, fg.b, 0.22)
  property string fontFamily: Style.font.family
  property int chartHeight: Style.space(168)
  property bool fill: false
  property int viewHeight: 0
  property int processLimit: 4
  property int meterSquares: 12
  // "100%" and "0.0%" are the same width in this monospace face.
  readonly property int pctWidth: Math.max(1, Math.ceil(pctProbe.implicitWidth))
  readonly property int sortSlot: Style.space(14) + Style.space(4)
  property var palette: []
  property var scales: ({})
  property var sortMode: ({ cpu: "load", gpu: "load" })
  property var sortDir: ({ cpu: -1, gpu: -1 })
  property var totalHold: ({ cpu: -1, gpu: -1 })
  // nf-md-chevron_up_box U+F09DC, nf-md-chevron_down_box U+F09D6
  readonly property string chevronUp: "\uDB82\uDDDC"
  readonly property string chevronDown: "\uDB82\uDDD6"

  property var history: ({ tctl: [], gpu: [], liquid: [] })
  property var stableGauges: []
  readonly property var navItems: {
    if (!service || service.connection !== "ready") return []
    return [
      { side: "cpu", mode: "name", x: 0, y: 0 },
      { side: "cpu", mode: "load", x: 1, y: 0 },
      { side: "gpu", mode: "name", x: 2, y: 0 },
      { side: "gpu", mode: "load", x: 3, y: 0 }
    ]
  }

  width: parent ? parent.width : 0
  spacing: Style.space(10)

  readonly property var temps: service && service.temps ? service.temps : ({})
  readonly property color gpuColor: companion(accent)
  readonly property color liquidColor: coolantInk(accent)
  // A machine with no coolant sensor and no pump is air cooled.
  readonly property bool liquidOn: num(temps.coolant) !== null || num(temps.pumpDuty) !== null || num(temps.pumpRpm) !== null
  readonly property var gaugeBoard: buildGauges()
  readonly property string gaugeSig: gaugeSignature(gaugeBoard)

  function companion(base) {
    var h = (base.hslHue + 0.52) % 1
    if (h < 0) h += 1
    var s = Math.max(0.35, Math.min(0.7, base.hslSaturation + 0.2))
    var l = Math.max(0.55, Math.min(0.74, base.hslLightness))
    return Qt.hsla(h, s, l, 1)
  }

  function coolantInk(base) {
    var h = (base.hslHue + 0.22) % 1
    if (h < 0) h += 1
    var s = Math.max(0.4, Math.min(0.72, base.hslSaturation + 0.18))
    var l = Math.max(0.52, Math.min(0.7, base.hslLightness))
    return Qt.hsla(h, s, l, 1)
  }

  function num(value) {
    if (value === null || value === undefined || value === "") return null
    var n = Number(value)
    return isFinite(n) ? n : null
  }

  function tempText(value) {
    if (value === null || value === undefined || value === "") return "—"
    var n = Number(value)
    return isFinite(n) ? Math.round(n) + "°" : "—"
  }

  function oneDecimal(value) {
    if (value === null || value === undefined || value === "") return "—"
    var n = Number(value)
    return isFinite(n) ? n.toFixed(1) + "°" : "—"
  }

  function ccdLine() {
    var a = num(temps.cpuCcd1)
    var b = num(temps.cpuCcd2)
    if (a === null && b === null) return ""
    if (a !== null && b !== null)
      return "CCD1 " + oneDecimal(a) + "  ·  CCD2 " + oneDecimal(b)
    if (a !== null) return "CCD1 " + oneDecimal(a)
    return "CCD2 " + oneDecimal(b)
  }

  function fullName(model, fallback) {
    var name = String(model || "").replace(/^\s+|\s+$/g, "")
    return name || fallback
  }

  function pumpDutyText() {
    var duty = num(temps.pumpDuty)
    return "Pump " + (duty === null ? "—" : Math.round(duty) + "%")
  }

  function pumpRpmText() {
    var rpm = num(temps.pumpRpm)
    return rpm === null ? "— rpm" : Math.round(rpm) + " rpm"
  }

  function pushSample() {
    var t = temps
    var cpu = num(t.cpu)
    var gpu = num(t.gpu)
    var liquid = num(t.coolant)
    var empty = (history.tctl || []).length === 0 && (history.gpu || []).length === 0 && (history.liquid || []).length === 0
    if (cpu === null && gpu === null && liquid === null && empty) return
    var next = ({})
    var keys = ["tctl", "gpu", "liquid"]
    var values = { tctl: cpu, gpu: gpu, liquid: liquid }
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i]
      var list = (history[key] || []).slice()
      list.push(values[key])
      if (list.length > 90) list = list.slice(list.length - 90)
      next[key] = list
    }
    history = next
  }

  function chartSeries() {
    var series = [
      { color: accent, values: history.tctl || [] },
      { color: gpuColor, values: history.gpu || [] }
    ]
    if (liquidOn) series.push({ color: liquidColor, values: history.liquid || [] })
    return series
  }

  function activeMode() {
    var modes = service && service.modes ? service.modes : []
    var uid = service ? service.activeModeUid : ""
    for (var i = 0; i < modes.length; i++) if (modes[i].uid === uid) return modes[i]
    return null
  }

  function buildGauges() {
    var saved = service && service.groups ? service.groups : []
    var channels = service && service.channels ? service.channels : []
    var profiles = service && service.profiles ? service.profiles : []
    var members = Cc.modeMembers(activeMode(), channels, profiles)
    var byKey = ({})
    var order = []
    function deviceConcealed(uid) {
      var map = service && service.hiddenDevices ? service.hiddenDevices : ({})
      return map[String(uid || "")] === true
    }

    // A header we are driving that never reports a tach is empty. A GPU fan
    // at 0% is stopped by the card and spins up with load, so it stays.
    function presentOnBoard(src) {
      if (!src) return false
      var rpm = Number(src.rpm)
      if (isFinite(rpm) && rpm > 0) return true
      if (String(src.deviceType || "") === "GPU") return true
      if (src.duty === null || src.duty === undefined || src.duty === "") return false
      var duty = Number(src.duty)
      return isFinite(duty) && duty <= 0
    }

    function keep(src) {
      if (!src || !src.key || byKey[src.key]) return
      if (deviceConcealed(src.deviceUid)) return
      if (!presentOnBoard(src)) return
      byKey[src.key] = {
        key: src.key,
        label: src.label || src.name || "",
        deviceUid: src.deviceUid || "",
        deviceName: src.deviceName || "",
        isPump: src.isPump === true
      }
      order.push(src.key)
    }
    var i
    for (i = 0; i < members.length; i++) keep(members[i])
    for (i = 0; i < channels.length; i++) keep(channels[i])

    var out = []
    var claimed = ({})
    for (var s = 0; s < saved.length; s++) {
      var group = saved[s]
      var memberKeys = group.members || []
      var rows = []
      for (var k = 0; k < memberKeys.length; k++) {
        var row = byKey[memberKeys[k]]
        if (!row) continue
        rows.push(row)
        claimed[row.key] = true
      }
      if (!rows.length) continue
      out.push({ kind: "shared", uid: group.id || "", name: group.name || "Shared", rows: rows })
    }
    var devices = ({})
    var devOrder = []
    for (i = 0; i < order.length; i++) {
      var item = byKey[order[i]]
      if (!item || claimed[item.key]) continue
      var uid = item.deviceUid || ""
      if (!devices[uid]) {
        devices[uid] = { kind: "device", uid: uid, name: item.deviceName || "Device", rows: [] }
        devOrder.push(uid)
      }
      if (item.deviceName) devices[uid].name = item.deviceName
      devices[uid].rows.push(item)
    }
    for (i = 0; i < devOrder.length; i++) out.push(devices[devOrder[i]])
    return out
  }

  function gaugeSignature(board) {
    var parts = []
    var list = board || []
    for (var i = 0; i < list.length; i++) {
      var card = list[i]
      var rows = card.rows || []
      var keys = []
      for (var r = 0; r < rows.length; r++) keys.push((rows[r].key || "") + "=" + (rows[r].label || ""))
      parts.push((card.kind || "") + ":" + (card.uid || "") + ":" + (card.name || "") + ":" + keys.join(","))
    }
    return parts.join("|")
  }

  function liveOf(key) {
    var map = service && service.channelLive
    if (map && map[key]) return map[key]
    var list = service && service.channels ? service.channels : []
    for (var i = 0; i < list.length; i++) if (list[i].key === key) return list[i]
    return null
  }

  function dutyOf(key) {
    var live = liveOf(key)
    if (!live) return -1
    var duty = live.duty
    if (duty === null || duty === undefined || duty === "") {
      // Number(null) is 0. A missing tach is not a stopped fan.
      var rawRpm = live.rpm
      if (rawRpm === null || rawRpm === undefined || rawRpm === "") return -1
      var rpm = Number(rawRpm)
      return isFinite(rpm) && rpm <= 0 ? 0 : -1
    }
    var n = Number(duty)
    return isFinite(n) ? Math.max(0, Math.min(100, n)) : -1
  }

  function rpmOf(key) {
    var live = liveOf(key)
    if (!live) return "—"
    var raw = live.rpm
    if (raw === null || raw === undefined || raw === "") return "—"
    var n = Number(raw)
    return isFinite(n) ? Math.round(n) + " rpm" : "—"
  }

  // Graphs take the spare height. Chips grow a little, and stop well short of that.
  readonly property real chipScale: {
    if (!fill) return 1
    var fitW = width > 0 ? width / 1100 : 1
    var fitH = viewHeight > 0 ? viewHeight / 720 : 1
    var fit = Math.min(fitW, fitH)
    if (fit < 1) fit = 1
    var scale = 1 + (fit - 1) * 0.16
    if (scale > 1.18) scale = 1.18
    return scale
  }
  readonly property int gaugeNatural: Math.round(Style.space(72) * chipScale)
  readonly property int chipText: Math.round(Style.space(11) * chipScale)
  readonly property int drawnChart: {
    var base = chartHeight
    if (!fill || !visible || viewHeight < 1) return base
    var gauges = gaugeRow.visible ? gaugeRow.height : 0
    var procs = processBlock.visible ? processBlock.height : 0
    var room = viewHeight - tempWrap.height - gauges - procs - spacing * 3
    return room > base ? room : base
  }

  function gaugeWeight(card) {
    var n = card && card.rows ? card.rows.length : 0
    return Math.max(2, n)
  }

  function gaugeCardWidth(avail, index, cards) {
    var list = cards || []
    var count = list.length
    if (!count) return Math.max(1, avail)
    var gap = Style.space(8)
    var room = Math.max(1, avail - gap * Math.max(0, count - 1))
    var span = 0
    var i
    for (i = 0; i < count; i++) span += gaugeWeight(list[i])
    if (span < 1) span = count
    var used = 0
    for (i = 0; i < count; i++) {
      var w = i === count - 1 ? room - used : Math.floor(room * gaugeWeight(list[i]) / span)
      if (i === index) return Math.max(1, w)
      used += w
    }
    return Math.max(1, Math.floor(room / count))
  }

  function gaugeSide(cardWidth, fans) {
    var pad = Style.space(16)
    var gap = Style.space(6)
    var n = Math.max(1, fans)
    var inner = Math.max(1, cardWidth - pad)
    var fit = Math.floor((inner - gap * Math.max(0, n - 1)) / n)
    return Math.max(Style.space(36), Math.min(gaugeNatural, fit))
  }

  function pushWatch() {
    if (service) service.watchProcesses = visible
  }

  function scaleFloor(side) {
    return side === "gpu" ? 20 : 2
  }

  function noteRows(side, rows) {
    var now = Date.now()
    var next = ({})
    var cur = scales
    var key
    for (key in cur) {
      var kept = cur[key]
      if (!kept || now - kept.seen >= 180000) continue
      next[key] = kept
    }
    var list = rows || []
    var i
    for (i = 0; i < list.length; i++) {
      var row = list[i]
      if (!row || !row.name) continue
      var id = side + "\n" + row.name
      var prev = cur[id]
      var sample = loadOf(row)
      var max = prev ? Number(prev.max) : sample
      if (!isFinite(max) || sample > max) max = sample
      var lit = Scale.litCount(sample, Scale.ceiling(max, scaleFloor(side)), meterSquares)
      next[id] = {
        max: max,
        seen: now,
        hold: Scale.stepHold(prev ? prev.hold : -1, lit),
        sample: sample
      }
    }
    scales = next
  }

  function loadOf(row) {
    if (!row) return 0
    var share = Number(row.share)
    if (isFinite(share)) return share < 0 ? 0 : share
    var pct = Number(row.percent)
    return isFinite(pct) && pct > 0 ? pct : 0
  }

  function pctText(value) {
    var n = Number(value)
    if (!isFinite(n) || n <= 0) return "0%"
    if (n < 10) {
      var tenth = Math.round(n * 10) / 10
      if (tenth <= 0) return "0%"
      var text = String(tenth)
      if (text.indexOf(".") < 0) return text + "%"
      return text + "%"
    }
    return Math.round(n) + "%"
  }

  function totalOf(side) {
    if (!service) return 0
    var value = side === "gpu" ? Number(service.processGpuTotal) : Number(service.processCpuTotal)
    if (!isFinite(value) || value < 0) return 0
    if (value > 100) return 100
    return value
  }

  function noteTotal(side) {
    var lit = Scale.litCount(totalOf(side), 100, meterSquares)
    var next = ({ cpu: -1, gpu: -1 })
    var cur = totalHold || ({})
    if (cur.cpu !== undefined && cur.cpu !== null) next.cpu = cur.cpu
    if (cur.gpu !== undefined && cur.gpu !== null) next.gpu = cur.gpu
    next[side] = Scale.stepHold(next[side], lit)
    totalHold = next
  }

  function toggleSort(side, mode) {
    var modes = ({ cpu: sortMode.cpu || "load", gpu: sortMode.gpu || "load" })
    var dirs = ({ cpu: Number(sortDir.cpu) || -1, gpu: Number(sortDir.gpu) || -1 })
    if (modes[side] === mode) dirs[side] = dirs[side] === 1 ? -1 : 1
    else {
      modes[side] = mode
      dirs[side] = mode === "name" ? 1 : -1
    }
    sortMode = modes
    sortDir = dirs
  }

  function sortGlyph(side, mode) {
    var active = (sortMode[side] || "load") === mode
    var dir = active ? Number(sortDir[side]) : (mode === "name" ? 1 : -1)
    return dir === 1 ? chevronUp : chevronDown
  }

  function sortOn(side, mode) {
    return (sortMode[side] || "load") === mode
  }

  function sortTip(side, mode) {
    var active = sortOn(side, mode)
    var dir = active ? Number(sortDir[side]) : (mode === "name" ? 1 : -1)
    if (dir !== 1 && dir !== -1) dir = mode === "name" ? 1 : -1
    var way = dir === 1 ? "Ascending" : "Descending"
    return mode === "name" ? ("Name " + way) : ("% Load " + way)
  }

  function shownProcesses(list, side) {
    var src = []
    var rows = list || []
    var i
    for (i = 0; i < rows.length; i++) src.push(rows[i])
    var mode = sortMode[side] || "load"
    var dir = Number(sortDir[side])
    if (dir !== 1 && dir !== -1) dir = -1
    src.sort(function(a, b) {
      if (mode === "name") {
        var cmp = String(a && a.name || "").localeCompare(String(b && b.name || ""))
        if (cmp !== 0) return cmp * dir
      }
      var av = root.loadOf(a)
      var bv = root.loadOf(b)
      if (av !== bv) return (av - bv) * dir
      return String(a && a.name || "").localeCompare(String(b && b.name || ""))
    })
    var out = []
    var limit = processLimit > 0 ? processLimit : 0
    for (i = 0; i < src.length && out.length < limit; i++) out.push(src[i])
    return out
  }

  function navAt() {
    return navItems.length ? navItems[Math.max(0, Math.min(navItems.length - 1, navIndex))] : null
  }

  function aimedSort(side, mode) {
    if (!keyed) return false
    var item = navAt()
    return !!(item && item.side === side && item.mode === mode)
  }

  function aimSort(side, mode) {
    var items = navItems
    var i
    for (i = 0; i < items.length; i++) {
      if (items[i].side === side && items[i].mode === mode) {
        navIndex = i
        return
      }
    }
  }

  function moveNav(dx, dy) {
    navIndex = Nav.step(navItems, navIndex, dx, dy)
  }

  function activateNav() {
    var item = navAt()
    if (!item) return
    toggleSort(item.side, item.mode)
  }

  function takeEscape() { return false }

  onGaugeSigChanged: stableGauges = gaugeBoard
  Component.onCompleted: {
    stableGauges = gaugeBoard
    pushWatch()
    if (!palette.length) palette = ThemePalette.ramp("", accent, Commons.Color.urgent)
    if (service) {
      noteRows("cpu", service.processCpu)
      noteRows("gpu", service.processGpu)
    }
  }
  Component.onDestruction: if (service) service.watchProcesses = false

  Timer {
    interval: 2000
    running: root.visible && root.service && root.service.connection === "ready"
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pushSample()
  }

  // The short name stays on its own line. The mark sits at the
  // temperature's size, on the same baseline, to the left of the number.
  component TempFigure: Row {
    id: figureRow
    property string mark: ""
    property string value: ""
    property color ink: root.accent
    spacing: Style.space(6)

    Text {
      anchors.baseline: figureValue.baseline
      text: figureRow.mark
      color: figureRow.ink
      font.family: root.fontFamily
      font.pixelSize: Style.font.displayLarge
    }

    Text {
      id: figureValue
      text: figureRow.value
      color: figureRow.ink
      font.family: root.fontFamily
      font.pixelSize: Style.font.displayLarge
      font.bold: true
    }
  }

  Item {
    id: tempWrap
    width: parent.width
    height: tempRow.height

  Row {
    id: tempRow
    width: parent.width
    spacing: Style.space(8)
    property int boxH: {
      var h = Math.max(cpuCol.implicitHeight, gpuCol.implicitHeight)
      if (root.liquidOn) h = Math.max(h, liquidCol.implicitHeight)
      return h + Style.space(20)
    }
    property int slots: root.liquidOn ? 3 : 2
    property int chipW: Math.max(1, Math.floor((width - spacing * (slots - 1)) / slots))
    property int chipLast: Math.max(1, width - spacing * (slots - 1) - chipW * (slots - 1))

    Rectangle {
      id: cpuChip
      readonly property bool hot: tempHover.hx >= x && tempHover.hx < x + width
      readonly property string model: root.fullName(root.temps.cpuName, "CPU")
      width: tempRow.chipW
      height: tempRow.boxH
      radius: 0
      clip: true
      color: hot
        ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.08)
        : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
      border.width: 1
      border.color: hot ? root.accent : root.line

      Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 2
        color: root.accent
      }

      Column {
        id: cpuCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(10)
        spacing: Style.space(2)
        Text {
          width: parent.width
          text: "CPU"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        TempFigure {
          mark: Marks.cpu
          value: root.tempText(root.temps.cpu)
          ink: root.accent
        }
        Text {
          width: parent.width
          visible: root.ccdLine() !== ""
          text: root.ccdLine()
          textFormat: Text.PlainText
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          // A chip card is narrower than "CCD1 42.5°  ·  CCD2 36.8°".
          // HorizontalFit lays the line out to the item width first, so the
          // fit check already sees a line that fits and elide keeps the cut.
          // Scale toward the left only when the natural line is wider.
          scale: {
            var natural = implicitWidth
            if (width <= 0 || natural <= width) return 1
            return Math.max(0.82, width / natural)
          }
          transformOrigin: Item.Left
          elide: Text.ElideNone
        }
      }

      PanelToolTip {
        visible: cpuChip.hot && cpuChip.model !== "CPU"
        text: cpuChip.model
        delay: 200
        fontFamily: root.fontFamily
        panelBackground: Commons.Color.background
        panelForeground: Commons.Color.foreground
        panelBorder: root.accent
      }
    }

    Rectangle {
      id: gpuChip
      readonly property bool hot: tempHover.hx >= x && tempHover.hx < x + width
      readonly property string model: root.fullName(root.temps.gpuName, "GPU")
      width: root.liquidOn ? tempRow.chipW : tempRow.chipLast
      height: tempRow.boxH
      radius: 0
      clip: true
      color: hot
        ? Qt.rgba(root.gpuColor.r, root.gpuColor.g, root.gpuColor.b, 0.10)
        : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
      border.width: 1
      border.color: hot ? root.gpuColor : root.line

      Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 2
        color: root.gpuColor
      }

      Column {
        id: gpuCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(10)
        spacing: Style.space(2)
        Text {
          width: parent.width
          text: "GPU"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        TempFigure {
          mark: Marks.gpu
          value: root.tempText(root.temps.gpu)
          ink: root.gpuColor
        }
        Text {
          width: parent.width
          text: {
            // The process header is nvidia-smi utilization. The daemon's
            // "GPU Load" channel is a different sensor and was drawing 0%
            // beside a 43% header.
            var load = NaN
            if (root.service && root.service.processGpuOk !== false)
              load = Number(root.service.processGpuTotal)
            if (!isFinite(load)) {
              var sensor = root.num(root.temps.gpuLoad)
              if (sensor !== null) load = sensor
            }
            var loadText = isFinite(load) ? Math.round(load) + "%" : "—"
            var power = root.num(root.temps.gpuPower)
            var watts = power === null ? "—" : Math.round(power) + " W"
            return loadText + "  ·  " + watts
          }
          textFormat: Text.PlainText
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          // Same card fit as the CCD line.
          scale: {
            var natural = implicitWidth
            if (width <= 0 || natural <= width) return 1
            return Math.max(0.82, width / natural)
          }
          transformOrigin: Item.Left
          elide: Text.ElideNone
        }
      }

      PanelToolTip {
        visible: gpuChip.hot && gpuChip.model !== "GPU"
        text: gpuChip.model
        delay: 200
        fontFamily: root.fontFamily
        panelBackground: Commons.Color.background
        panelForeground: Commons.Color.foreground
        panelBorder: root.gpuColor
      }
    }

    Rectangle {
      id: liquidChip
      readonly property bool hot: visible && tempHover.hx >= x && tempHover.hx < x + width
      readonly property string model: root.fullName(root.temps.liquidName, "Liquid")
      visible: root.liquidOn
      width: tempRow.chipLast
      height: tempRow.boxH
      radius: 0
      clip: true
      color: hot
        ? Qt.rgba(root.liquidColor.r, root.liquidColor.g, root.liquidColor.b, 0.10)
        : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
      border.width: 1
      border.color: hot ? root.liquidColor : root.line

      Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 2
        color: root.liquidColor
      }

      Column {
        id: liquidCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(10)
        spacing: Style.space(2)
        Text {
          width: parent.width
          text: "Liquid"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        TempFigure {
          mark: Marks.liquid
          value: root.tempText(root.temps.coolant)
          ink: root.liquidColor
        }
        Text {
          width: parent.width
          text: root.pumpDutyText() + "  ·  " + root.pumpRpmText()
          textFormat: Text.PlainText
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          // Same card fit as the CCD line.
          scale: {
            var natural = implicitWidth
            if (width <= 0 || natural <= width) return 1
            return Math.max(0.82, width / natural)
          }
          transformOrigin: Item.Left
          elide: Text.ElideNone
        }
      }

      PanelToolTip {
        visible: liquidChip.hot && liquidChip.model !== "Liquid"
        text: liquidChip.model
        delay: 200
        fontFamily: root.fontFamily
        panelBackground: Commons.Color.background
        panelForeground: Commons.Color.foreground
        panelBorder: root.liquidColor
      }
    }

  }

    // Row rejects fill anchors on its children, so the hover target sits on the wrap.
    MouseArea {
      id: tempHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      z: 5
      property real hx: -1
      onPositionChanged: function(mouse) { hx = mouse.x }
      onContainsMouseChanged: if (!containsMouse) hx = -1
    }
  }

  TimeChart {
    width: parent.width
    height: root.drawnChart
    series: root.chartSeries()
    foreground: root.fg
    fontFamily: root.fontFamily
  }

  Row {
    id: gaugeRow
    width: parent.width
    spacing: Style.space(8)
    visible: root.stableGauges.length > 0

    Repeater {
      model: root.stableGauges
      delegate: Rectangle {
        id: gaugeCard
        required property var modelData
        required property int index
        readonly property int fans: Math.max(1, (modelData.rows || []).length)
        readonly property int side: root.gaugeSide(width, fans)
        width: root.gaugeCardWidth(gaugeRow.width, index, root.stableGauges)
        implicitHeight: gaugeCol.implicitHeight + Style.space(20)
        height: implicitHeight
        radius: 0
        color: "transparent"
        border.width: 1
        border.color: root.line
        clip: true

        Column {
          id: gaugeCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(10)
          spacing: Style.space(6)

          Item {
            width: parent.width
            height: gaugeTitle.implicitHeight

            Text {
              id: gaugeTitle
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: gaugeCard.modelData.kind === "shared"
                ? gaugeCard.modelData.name
                : String(gaugeCard.modelData.name || "Device").toUpperCase()
              textFormat: Text.PlainText
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Math.round(Style.font.caption * root.chipScale)
              font.bold: true
              elide: Text.ElideRight
            }
          }

          Item {
            width: parent.width
            height: gaugeInner.implicitHeight
            clip: true

            Row {
              id: gaugeInner
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(6)

              Repeater {
                model: gaugeCard.modelData.rows
                delegate: Column {
                  required property var modelData
                  width: gaugeCard.side
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: modelData.label || ""
                    textFormat: Text.PlainText
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: root.chipText
                    elide: Text.ElideRight
                  }

                  Item {
                    width: gaugeCard.side
                    height: root.gaugeNatural

                    SpeedGauge {
                      anchors.centerIn: parent
                      width: gaugeCard.side
                      height: gaugeCard.side
                      percent: root.dutyOf(modelData.key)
                      textScale: root.chipScale
                      foreground: root.fg
                      accent: root.accent
                      fontFamily: root.fontFamily
                    }
                  }

                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: root.rpmOf(modelData.key)
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: root.chipText
                    elide: Text.ElideRight
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  Text {
    id: pctProbe
    visible: false
    text: "100%"
    font.family: root.fontFamily
    font.pixelSize: Style.space(12)
  }

  component ProcessColumn: Column {
    id: column
    property string side: "cpu"
    property string title: "CPU"
    property string mark: ""
    property string emptyText: "No CPU samples yet"
    property var rows: []
    width: (parent.width - parent.spacing) / 2
    spacing: Style.space(6)

    Item {
      width: parent.width
      height: Style.space(22)

      Item {
        id: nameHit
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(14) + Style.space(4) + nameWord.implicitWidth + Style.space(4) + Style.space(14)
        height: parent.height

        Text {
          id: nameMark
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: column.mark
          color: root.sortOn(column.side, "name") ? root.accent : root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.space(14)
        }

        Text {
          id: nameWord
          anchors.left: nameMark.right
          anchors.leftMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          text: column.title
          color: root.sortOn(column.side, "name") ? root.accent : root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.space(13)
          font.bold: true
        }
        OpticalGlyph {
          anchors.left: nameWord.right
          anchors.leftMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(14)
          height: Style.space(14)
          text: root.sortGlyph(column.side, "name")
          fontFamily: root.fontFamily
          fontSize: Style.space(14)
          color: root.sortOn(column.side, "name") ? root.accent : root.muted
        }
        Rectangle {
          anchors.fill: parent
          color: "transparent"
          border.width: root.aimedSort(column.side, "name") ? 1 : 0
          border.color: root.accent
        }
        MouseArea {
          id: nameMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.aimSort(column.side, "name")
            root.toggleSort(column.side, "name")
          }
        }
        PanelToolTip {
          visible: nameMouse.containsMouse
          text: root.sortTip(column.side, "name")
          fontFamily: root.fontFamily
          panelBackground: Commons.Color.background
          panelForeground: Commons.Color.foreground
          panelBorder: Commons.Color.accent
        }
      }

      Item {
        id: loadHit
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        width: totalMeter.implicitWidth + Style.space(6) + root.pctWidth + root.sortSlot

        LoadMeter {
          id: totalMeter
          anchors.right: totalPct.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          squares: root.meterSquares
          lit: Scale.litCount(root.totalOf(column.side), 100, root.meterSquares)
          hold: root.totalHold[column.side] === undefined ? -1 : root.totalHold[column.side]
          palette: root.palette
        }
        Text {
          id: totalPct
          anchors.right: loadGlyph.left
          anchors.rightMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          width: root.pctWidth
          horizontalAlignment: Text.AlignRight
          text: root.pctText(root.totalOf(column.side))
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.space(12)
        }
        OpticalGlyph {
          id: loadGlyph
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(14)
          height: Style.space(14)
          text: root.sortGlyph(column.side, "load")
          fontFamily: root.fontFamily
          fontSize: Style.space(14)
          color: root.sortOn(column.side, "load") ? root.accent : root.muted
        }
        Rectangle {
          anchors.fill: parent
          color: "transparent"
          border.width: root.aimedSort(column.side, "load") ? 1 : 0
          border.color: root.accent
        }
        MouseArea {
          id: loadMouse
          anchors.left: totalMeter.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.aimSort(column.side, "load")
            root.toggleSort(column.side, "load")
          }
        }
        PanelToolTip {
          visible: loadMouse.containsMouse
          text: root.sortTip(column.side, "load")
          fontFamily: root.fontFamily
          panelBackground: Commons.Color.background
          panelForeground: Commons.Color.foreground
          panelBorder: Commons.Color.accent
        }
      }
    }

    Text {
      width: parent.width
      visible: root.shownProcesses(column.rows, column.side).length === 0
      text: column.emptyText
      wrapMode: Text.WordWrap
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: root.shownProcesses(column.rows, column.side)
      delegate: Item {
        id: procRow
        required property var modelData
        readonly property real sample: root.loadOf(modelData)
        readonly property var remembered: root.scales[column.side + "\n" + modelData.name]
        readonly property real scaleTop: Scale.ceiling(remembered ? remembered.max : sample, root.scaleFloor(column.side))
        readonly property int lit: Scale.litCount(sample, scaleTop, root.meterSquares)
        readonly property int hold: remembered ? remembered.hold : -1
        width: column.width
        height: Style.space(22)

        Text {
          anchors.left: parent.left
          anchors.right: procMeter.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.name + (Number(modelData.count) > 1 ? "  ×" + modelData.count : "")
          textFormat: Text.PlainText
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.space(12)
          elide: Text.ElideRight
        }

        LoadMeter {
          id: procMeter
          anchors.right: procPct.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          squares: root.meterSquares
          lit: procRow.lit
          hold: procRow.hold
          palette: root.palette
        }

        Text {
          id: procPct
          anchors.right: parent.right
          anchors.rightMargin: root.sortSlot
          anchors.verticalCenter: parent.verticalCenter
          width: root.pctWidth
          horizontalAlignment: Text.AlignRight
          text: root.pctText(root.loadOf(procRow.modelData))
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.space(12)
        }
      }
    }
  }

  Row {
    id: processBlock
    width: parent.width
    spacing: Style.space(16)
    visible: root.service && root.service.connection === "ready"

    ProcessColumn {
      side: "cpu"
      title: "CPU"
      mark: Marks.cpu
      emptyText: "No CPU samples yet"
      rows: root.service ? root.service.processCpu : []
    }

    ProcessColumn {
      side: "gpu"
      title: "GPU"
      mark: Marks.gpu
      emptyText: root.service && root.service.processGpuOk === false ? "GPU processes unavailable" : "No GPU samples yet"
      rows: root.service ? root.service.processGpu : []
    }
  }

  Connections {
    target: root.service
    function onProcessCpuChanged() {
      root.noteRows("cpu", root.service.processCpu)
      root.noteTotal("cpu")
    }
    function onProcessGpuChanged() {
      root.noteRows("gpu", root.service.processGpu)
      root.noteTotal("gpu")
    }
  }

  Timer {
    interval: 10000
    repeat: true
    running: root.visible
    onTriggered: {
      var now = Date.now()
      var next = ({})
      var cur = root.scales
      var key
      for (key in cur) {
        var row = cur[key]
        if (!row || now - row.seen >= 180000) continue
        var side = String(key).indexOf("gpu\n") === 0 ? "gpu" : "cpu"
        next[key] = {
          max: Scale.decayMax(row.max, row.sample, root.scaleFloor(side)),
          seen: row.seen,
          hold: row.hold,
          sample: row.sample
        }
      }
      root.scales = next
    }
  }

  FileView {
    id: themeFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.palette = ThemePalette.ramp(text(), root.accent, Commons.Color.urgent)
    onFileChanged: reload()
  }

  onVisibleChanged: pushWatch()
  onServiceChanged: pushWatch()
}
