import QtQuick
import qs.Commons
import qs.Ui
import "CcMap.js" as Cc

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

  property var history: ({ tctl: [], gpu: [], liquid: [] })
  property var stableGauges: []

  width: parent ? parent.width : 0
  spacing: Style.space(10)

  readonly property var temps: service && service.temps ? service.temps : ({})
  readonly property color gpuColor: companion(accent)
  readonly property color liquidColor: coolantInk(accent)
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
    return [
      { color: accent, values: history.tctl || [] },
      { color: gpuColor, values: history.gpu || [] },
      { color: liquidColor, values: history.liquid || [] }
    ]
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
    var room = viewHeight - tempWrap.height - gauges - spacing * 2
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

  function moveNav(dx, dy) {}

  function activateNav() {}

  function takeEscape() { return false }

  onGaugeSigChanged: stableGauges = gaugeBoard
  Component.onCompleted: stableGauges = gaugeBoard

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
    property int boxH: Math.max(cpuCol.implicitHeight, gpuCol.implicitHeight, liquidCol.implicitHeight) + Style.space(20)
    property int chipW: Math.max(1, Math.floor((width - spacing * 2) / 3))
    property int chipLast: Math.max(1, width - spacing * 2 - chipW * 2)

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
      width: tempRow.chipW
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
}
