import QtQuick
import qs.Commons

// Draggable plot of coolercontrold graph points: [temp, duty].
// Duty grid, floor band, fill, and round handles.
Item {
  id: root

  property var points: []
  property bool interactive: false
  property int minDuty: 0
  property real currentTemp: -1
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal pointsEdited(var points)

  readonly property int padL: Style.space(36)
  readonly property int padR: Style.space(12)
  readonly property int padT: Style.space(14)
  readonly property int padB: Style.space(28)
  readonly property real plotW: Math.max(1, width - padL - padR)
  readonly property real plotH: Math.max(1, height - padT - padB)
  property int dragIndex: -1
  property var draft: []

  function shown() {
    return (dragIndex >= 0 && draft && draft.length) ? draft : (points || [])
  }

  // Paint holds the first duty back to 0° and the last duty out to 100°.
  function traced() {
    var pts = shown()
    var out = []
    var i
    for (i = 0; i < pts.length; i++) {
      if (!pts[i]) continue
      out.push([Number(pts[i][0]), dutyAt(i)])
    }
    if (out.length < 2) return out
    if (out[0][0] > 0) out.unshift([0, out[0][1]])
    if (out[out.length - 1][0] < 100) out.push([100, out[out.length - 1][1]])
    return out
  }

  function tempSpan() {
    return { lo: 0, hi: 100 }
  }

  function xAt(temp) {
    var span = tempSpan()
    return padL + ((temp - span.lo) / (span.hi - span.lo)) * plotW
  }

  function yAt(duty) {
    return padT + (1 - Math.max(0, Math.min(100, duty)) / 100) * plotH
  }

  function dutyFromY(y) {
    var duty = (1 - (y - padT) / plotH) * 100
    return Math.max(minDuty, Math.min(100, Math.round(duty)))
  }

  function tempAt(index) {
    var pts = shown()
    if (!pts || index < 0 || index >= pts.length || !pts[index]) return tempSpan().lo
    var temp = Number(pts[index][0])
    return isFinite(temp) ? temp : tempSpan().lo
  }

  function dutyAt(index) {
    var pts = shown()
    if (index < 0 || index >= pts.length || !pts[index]) return minDuty
    var duty = Number(pts[index][1])
    if (!isFinite(duty)) duty = minDuty
    return Math.max(minDuty, Math.min(100, duty))
  }

  function monotonic(src, index, duty) {
    var next = []
    for (var i = 0; i < src.length; i++) next.push([Number(src[i][0]), Number(src[i][1])])
    if (index < 0 || index >= next.length) return next
    next[index] = [next[index][0], duty]
    var j
    for (j = index + 1; j < next.length; j++) {
      if (next[j][1] < duty) next[j] = [next[j][0], duty]
    }
    for (j = index - 1; j >= 0; j--) {
      if (next[j][1] > duty) next[j] = [next[j][0], duty]
    }
    return next
  }

  onPointsChanged: {
    if (dragIndex < 0) draft = []
    canvas.requestPaint()
  }
  onDraftChanged: canvas.requestPaint()
  onCurrentTempChanged: canvas.requestPaint()
  onAccentChanged: canvas.requestPaint()
  onForegroundChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()
  onMinDutyChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.clearRect(0, 0, width, height)
      var fg = root.foreground
      var ac = root.accent
      ctx.lineWidth = 1
      ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.12)
      var duties = [0, 25, 50, 75, 100]
      for (var g = 0; g < duties.length; g++) {
        var y = root.yAt(duties[g])
        ctx.beginPath()
        ctx.moveTo(root.padL, y)
        ctx.lineTo(width - root.padR, y)
        ctx.stroke()
      }
      if (root.minDuty > 0) {
        var yFloor = root.yAt(root.minDuty)
        var yZero = root.yAt(0)
        ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.08)
        ctx.fillRect(root.padL, yFloor, root.plotW, Math.max(0, yZero - yFloor))
        ctx.beginPath()
        ctx.moveTo(root.padL, yFloor)
        ctx.lineTo(width - root.padR, yFloor)
        ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.35)
        ctx.stroke()
      }
      var trace = root.traced()
      if (trace.length >= 2) {
        var floorY = root.yAt(root.minDuty)
        ctx.beginPath()
        ctx.moveTo(root.xAt(trace[0][0]), root.yAt(trace[0][1]))
        for (var i = 1; i < trace.length; i++)
          ctx.lineTo(root.xAt(trace[i][0]), root.yAt(trace[i][1]))
        ctx.lineTo(root.xAt(trace[trace.length - 1][0]), floorY)
        ctx.lineTo(root.xAt(trace[0][0]), floorY)
        ctx.closePath()
        ctx.fillStyle = Qt.rgba(ac.r, ac.g, ac.b, 0.18)
        ctx.fill()
        ctx.beginPath()
        ctx.moveTo(root.xAt(trace[0][0]), root.yAt(trace[0][1]))
        for (var j = 1; j < trace.length; j++)
          ctx.lineTo(root.xAt(trace[j][0]), root.yAt(trace[j][1]))
        ctx.strokeStyle = ac
        ctx.lineWidth = 2
        ctx.stroke()
      }
      var span = root.tempSpan()
      if (root.currentTemp >= span.lo && root.currentTemp <= span.hi) {
        var tx = root.xAt(root.currentTemp)
        ctx.beginPath()
        ctx.moveTo(tx, root.padT)
        ctx.lineTo(tx, root.padT + root.plotH)
        ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.45)
        ctx.lineWidth = 1
        ctx.setLineDash([4, 4])
        ctx.stroke()
        ctx.setLineDash([])
      }
    }
  }

  Repeater {
    model: root.shown().length
    Rectangle {
      required property int index
      width: Style.space(10)
      height: width
      radius: width / 2
      x: root.xAt(root.tempAt(index)) - width / 2
      y: root.yAt(root.dutyAt(index)) - height / 2
      color: root.interactive ? root.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
      border.width: 1
      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.85)
      opacity: root.interactive ? 1 : 0.7
      z: 2

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(8)
        enabled: root.interactive
        preventStealing: true
        cursorShape: root.interactive ? Qt.SizeVerCursor : Qt.ArrowCursor
        onPressed: function() {
          root.dragIndex = index
          root.draft = JSON.parse(JSON.stringify(root.points || []))
        }
        onPositionChanged: function(mouse) {
          if (!pressed || root.dragIndex !== index) return
          var gy = mapToItem(root, mouse.x, mouse.y).y
          var src = root.draft && root.draft.length ? root.draft : root.points
          root.draft = root.monotonic(src, index, root.dutyFromY(gy))
        }
        onReleased: {
          if (root.dragIndex !== index) return
          var next = root.draft
          root.dragIndex = -1
          root.pointsEdited(next)
        }
      }
    }
  }

  Text {
    x: Math.max(0, root.xAt(0) - implicitWidth / 2)
    y: root.height - implicitHeight
    text: "0°"
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    x: Math.min(Math.max(0, parent.width - implicitWidth), root.xAt(100) - implicitWidth / 2)
    y: root.height - implicitHeight
    text: "100°"
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    anchors.left: parent.left
    anchors.top: parent.top
    text: "100%"
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(14)
    text: root.minDuty + "%"
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
