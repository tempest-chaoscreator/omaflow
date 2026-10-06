import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "CcMap.js" as Cc
import "ProcessScale.js" as Scale
import "ThemePalette.js" as ThemePalette

// CPU, GPU, and liquid sit above one chart. Fan speedometers follow the Modes groups.
Column {
  id: root

  property var service: null
  property bool keyed: false
  property int navIndex: 0
  property color fg: Color.foreground
  property color accent: Color.accent
  property color muted: Qt.darker(fg, 1.4)
  property color line: Qt.rgba(fg.r, fg.g, fg.b, 0.16)
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
    return isFinite(Number(value)) ? Math.round(Number(value)) + "°" : "—"
  }

  function oneDecimal(value) {
    return isFinite(Number(value)) ? Number(value).toFixed(1) + "°" : "—"
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
    var list = service && service.channels ? service.channels : []
    for (var i = 0; i < list.length; i++) if (list[i].key === key) return list[i]
    return null
  }

  function dutyOf(key) {
    var live = liveOf(key)
    if (!live) return -1
    if (live.duty === null || live.duty === undefined || live.duty === "") {
      var rpm = Number(live.rpm)
      return isFinite(rpm) && rpm <= 0 ? 0 : -1
    }
    var n = Number(live.duty)
    return isFinite(n) ? Math.max(0, Math.min(100, n)) : -1
  }

  function rpmOf(key) {
    var live = liveOf(key)
    var n = live ? Number(live.rpm) : NaN
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
      var sample = Number(row.percent)
      if (!isFinite(sample) || sample < 0) sample = 0
      var max = prev ? Number(prev.max) : sample
      if (!isFinite(max) || sample > max) max = sample
      var lit = Scale.litCount(sample, Scale.ceiling(max), meterSquares)
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

  function moveNav(dx, dy) {}

  function activateNav() {}

  function takeEscape() { return false }

  onGaugeSigChanged: stableGauges = gaugeBoard
  Component.onCompleted: {
    stableGauges = gaugeBoard
    pushWatch()
    if (!palette.length) palette = ThemePalette.ramp("", accent, Color.urgent)
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
      width: tempRow.chipW
      height: tempRow.boxH
      radius: 0
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
      border.width: 1
      border.color: root.line

      Column {
        id: cpuCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(10)
        spacing: Style.space(2)
        ChipTitle {
          width: parent.width
          mark: "\uF4BC"
          label: cpuChip.hot ? root.fullName(root.temps.cpuName, "CPU") : "CPU"
          color: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          wrapLines: 2
        }
        Text {
          text: root.tempText(root.temps.cpu)
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
          font.bold: true
        }
        Text {
          width: parent.width
          text: "CCD1 " + root.oneDecimal(root.temps.cpuCcd1) + "  ·  CCD2 " + root.oneDecimal(root.temps.cpuCcd2)
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

    }

    Rectangle {
      id: gpuChip
      readonly property bool hot: tempHover.hx >= x && tempHover.hx < x + width
      width: root.liquidOn ? tempRow.chipW : tempRow.chipLast
      height: tempRow.boxH
      radius: 0
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
      border.width: 1
      border.color: root.line

      Column {
        id: gpuCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(10)
        spacing: Style.space(2)
        ChipTitle {
          width: parent.width
          mark: "\uE266"
          label: gpuChip.hot ? root.fullName(root.temps.gpuName, "GPU") : "GPU"
          color: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          wrapLines: 2
        }
        Text {
          text: root.tempText(root.temps.gpu)
          color: root.gpuColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
          font.bold: true
        }
        Text {
          width: parent.width
          text: {
            var load = isFinite(Number(root.temps.gpuLoad)) ? Math.round(Number(root.temps.gpuLoad)) + "%" : "—"
            var watts = isFinite(Number(root.temps.gpuPower)) ? Math.round(Number(root.temps.gpuPower)) + " W" : "—"
            return load + "  ·  " + watts
          }
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

    }

    Rectangle {
      id: liquidChip
      visible: root.liquidOn
      width: tempRow.chipLast
      height: tempRow.boxH
      radius: 0
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
      border.width: 1
      border.color: root.line

      Column {
        id: liquidCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(10)
        spacing: Style.space(2)
        ChipTitle {
          width: parent.width
          // nf-md-water_thermometer_outline U+F1A86
          mark: "\uDB86\uDE86"
          label: "Liquid"
          color: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
        }
        Text {
          text: root.tempText(root.temps.coolant)
          color: root.liquidColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
          font.bold: true
        }
        Text {
          width: parent.width
          text: root.pumpDutyText() + "  ·  " + root.pumpRpmText()
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
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
        implicitHeight: gaugeCol.implicitHeight + Style.space(16)
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
          anchors.margins: Style.space(8)
          spacing: Style.space(6)

          Text {
            width: parent.width
            text: gaugeCard.modelData.kind === "shared"
              ? gaugeCard.modelData.name
              : String(gaugeCard.modelData.name || "Device").toUpperCase()
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Math.round(Style.font.caption * root.chipScale)
            font.bold: true
            font.letterSpacing: gaugeCard.modelData.kind === "shared" ? 0 : 0.6
            elide: Text.ElideRight
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

  Row {
    id: processBlock
    width: parent.width
    spacing: Style.space(16)
    visible: root.service && root.service.connection === "ready"

    Column {
      id: cpuProc
      width: (parent.width - parent.spacing) / 2
      spacing: Style.space(6)
      property string side: "cpu"

      Item {
        width: parent.width
        height: Style.space(22)

        Item {
          id: cpuNameHit
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: cpuWord.implicitWidth + Style.space(4) + Style.space(14)
          height: parent.height

          Text {
            id: cpuWord
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "CPU"
            color: root.sortOn("cpu", "name") ? root.accent : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.space(13)
            font.bold: true
          }
          OpticalGlyph {
            anchors.left: cpuWord.right
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(14)
            height: Style.space(14)
            text: root.sortGlyph("cpu", "name")
            fontFamily: root.fontFamily
            fontSize: Style.space(14)
            color: root.sortOn("cpu", "name") ? root.accent : root.muted
          }
          MouseArea {
            id: cpuNameMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleSort("cpu", "name")
          }
          PanelToolTip {
            visible: cpuNameMouse.containsMouse
            text: root.sortTip("cpu", "name")
            fontFamily: root.fontFamily
            panelBackground: Color.background
            panelForeground: Color.foreground
            panelBorder: Color.accent
          }
        }

        Item {
          id: cpuLoadHit
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          height: parent.height
          width: cpuTotalMeter.implicitWidth + Style.space(6) + root.pctWidth + root.sortSlot

          LoadMeter {
            id: cpuTotalMeter
            anchors.right: cpuTotalPct.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            squares: root.meterSquares
            lit: Scale.litCount(root.totalOf("cpu"), 100, root.meterSquares)
            hold: root.totalHold.cpu === undefined ? -1 : root.totalHold.cpu
            palette: root.palette
          }
          Text {
            id: cpuTotalPct
            anchors.right: cpuLoadGlyph.left
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            width: root.pctWidth
            horizontalAlignment: Text.AlignRight
            text: root.pctText(root.totalOf("cpu"))
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
          }
          OpticalGlyph {
            id: cpuLoadGlyph
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(14)
            height: Style.space(14)
            text: root.sortGlyph("cpu", "load")
            fontFamily: root.fontFamily
            fontSize: Style.space(14)
            color: root.sortOn("cpu", "load") ? root.accent : root.muted
          }
          MouseArea {
            id: cpuLoadMouse
            anchors.left: cpuTotalMeter.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleSort("cpu", "load")
          }
          PanelToolTip {
            visible: cpuLoadMouse.containsMouse
            text: root.sortTip("cpu", "load")
            fontFamily: root.fontFamily
            panelBackground: Color.background
            panelForeground: Color.foreground
            panelBorder: Color.accent
          }
        }
      }

      Text {
        width: parent.width
        visible: root.shownProcesses(root.service ? root.service.processCpu : [], "cpu").length === 0
        text: "No CPU samples yet"
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Repeater {
        model: root.shownProcesses(root.service ? root.service.processCpu : [], "cpu")
        delegate: Item {
          id: cpuRow
          required property var modelData
          readonly property real sample: {
            var value = Number(modelData.percent)
            return isFinite(value) && value > 0 ? value : 0
          }
          readonly property var remembered: root.scales[cpuProc.side + "\n" + modelData.name]
          readonly property real scaleTop: Scale.ceiling(remembered ? remembered.max : sample)
          readonly property int lit: Scale.litCount(sample, scaleTop, root.meterSquares)
          readonly property int hold: remembered ? remembered.hold : -1
          width: cpuProc.width
          height: Style.space(22)

          Text {
            id: cpuName
            anchors.left: parent.left
            anchors.right: cpuMeter.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.name + (Number(modelData.count) > 1 ? "  ×" + modelData.count : "")
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
            elide: Text.ElideRight
          }

          LoadMeter {
            id: cpuMeter
            anchors.right: cpuPct.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            squares: root.meterSquares
            lit: cpuRow.lit
            hold: cpuRow.hold
            palette: root.palette
          }

          Text {
            id: cpuPct
            anchors.right: parent.right
            anchors.rightMargin: root.sortSlot
            anchors.verticalCenter: parent.verticalCenter
            width: root.pctWidth
            horizontalAlignment: Text.AlignRight
            text: root.pctText(root.loadOf(cpuRow.modelData))
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
          }
        }
      }
    }

    Column {
      id: gpuProc
      width: (parent.width - parent.spacing) / 2
      spacing: Style.space(6)
      property string side: "gpu"

      Item {
        width: parent.width
        height: Style.space(22)

        Item {
          id: gpuNameHit
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: gpuWord.implicitWidth + Style.space(4) + Style.space(14)
          height: parent.height

          Text {
            id: gpuWord
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "GPU"
            color: root.sortOn("gpu", "name") ? root.accent : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.space(13)
            font.bold: true
          }
          OpticalGlyph {
            anchors.left: gpuWord.right
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(14)
            height: Style.space(14)
            text: root.sortGlyph("gpu", "name")
            fontFamily: root.fontFamily
            fontSize: Style.space(14)
            color: root.sortOn("gpu", "name") ? root.accent : root.muted
          }
          MouseArea {
            id: gpuNameMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleSort("gpu", "name")
          }
          PanelToolTip {
            visible: gpuNameMouse.containsMouse
            text: root.sortTip("gpu", "name")
            fontFamily: root.fontFamily
            panelBackground: Color.background
            panelForeground: Color.foreground
            panelBorder: Color.accent
          }
        }

        Item {
          id: gpuLoadHit
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          height: parent.height
          width: gpuTotalMeter.implicitWidth + Style.space(6) + root.pctWidth + root.sortSlot

          LoadMeter {
            id: gpuTotalMeter
            anchors.right: gpuTotalPct.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            squares: root.meterSquares
            lit: Scale.litCount(root.totalOf("gpu"), 100, root.meterSquares)
            hold: root.totalHold.gpu === undefined ? -1 : root.totalHold.gpu
            palette: root.palette
          }
          Text {
            id: gpuTotalPct
            anchors.right: gpuLoadGlyph.left
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            width: root.pctWidth
            horizontalAlignment: Text.AlignRight
            text: root.pctText(root.totalOf("gpu"))
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
          }
          OpticalGlyph {
            id: gpuLoadGlyph
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(14)
            height: Style.space(14)
            text: root.sortGlyph("gpu", "load")
            fontFamily: root.fontFamily
            fontSize: Style.space(14)
            color: root.sortOn("gpu", "load") ? root.accent : root.muted
          }
          MouseArea {
            id: gpuLoadMouse
            anchors.left: gpuTotalMeter.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleSort("gpu", "load")
          }
          PanelToolTip {
            visible: gpuLoadMouse.containsMouse
            text: root.sortTip("gpu", "load")
            fontFamily: root.fontFamily
            panelBackground: Color.background
            panelForeground: Color.foreground
            panelBorder: Color.accent
          }
        }
      }

      Text {
        width: parent.width
        visible: root.shownProcesses(root.service ? root.service.processGpu : [], "gpu").length === 0
        text: root.service && root.service.processGpuOk === false ? "GPU processes unavailable" : "No GPU samples yet"
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Repeater {
        model: root.shownProcesses(root.service ? root.service.processGpu : [], "gpu")
        delegate: Item {
          id: gpuRow
          required property var modelData
          readonly property real sample: {
            var value = Number(modelData.percent)
            return isFinite(value) && value > 0 ? value : 0
          }
          readonly property var remembered: root.scales[gpuProc.side + "\n" + modelData.name]
          readonly property real scaleTop: Scale.ceiling(remembered ? remembered.max : sample)
          readonly property int lit: Scale.litCount(sample, scaleTop, root.meterSquares)
          readonly property int hold: remembered ? remembered.hold : -1
          width: gpuProc.width
          height: Style.space(22)

          Text {
            id: gpuName
            anchors.left: parent.left
            anchors.right: gpuMeter.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.name + (Number(modelData.count) > 1 ? "  ×" + modelData.count : "")
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
            elide: Text.ElideRight
          }

          LoadMeter {
            id: gpuMeter
            anchors.right: gpuPct.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            squares: root.meterSquares
            lit: gpuRow.lit
            hold: gpuRow.hold
            palette: root.palette
          }

          Text {
            id: gpuPct
            anchors.right: parent.right
            anchors.rightMargin: root.sortSlot
            anchors.verticalCenter: parent.verticalCenter
            width: root.pctWidth
            horizontalAlignment: Text.AlignRight
            text: root.pctText(root.loadOf(gpuRow.modelData))
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
          }
        }
      }
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
        next[key] = {
          max: Scale.decayMax(row.max, row.sample),
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
    onLoaded: root.palette = ThemePalette.ramp(text(), root.accent, Color.urgent)
    onFileChanged: reload()
  }

  onVisibleChanged: pushWatch()
  onServiceChanged: pushWatch()
}
