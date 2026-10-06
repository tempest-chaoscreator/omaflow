import QtQuick
import qs.Commons
import "Model.js" as Model

// NZXT CAM-style fan curve: ~15 fixed temperature columns, each a handle
// you drag up and down. X is locked; Y is duty %. Dragging a handle up
// lifts every handle to its right so the curve never dips.
Item {
  id: root

  property var points: []
  property var livePoints: []
  property var temps: [20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90]
  property real currentTemp: -1
  property bool interactive: true
  property int minDuty: 0
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal pointChanged(int index, real value)
  signal dragFinished()

  readonly property int n: Math.max(2, temps.length)
  readonly property int padL: Style.space(36)
  readonly property int padR: Style.space(12)
  readonly property int padT: Style.space(14)
  readonly property int padB: Style.space(28)
  readonly property real plotW: Math.max(1, width - padL - padR)
  readonly property real plotH: Math.max(1, height - padT - padB)
  property int dragIndex: -1

  function syncLive() {
    livePoints = Model.copyPoints(points, minDuty)
  }

  function dutyAt(i) {
    var pts = (livePoints && livePoints.length) ? livePoints : (points || [])
    var v = (i >= 0 && i < pts.length) ? Number(pts[i]) : minDuty
    if (!isFinite(v)) v = minDuty
    return Math.max(minDuty, Math.min(100, v))
  }

  function xAt(i) {
    return padL + (i / (n - 1)) * plotW
  }

  function yAt(duty) {
    return padT + (1 - duty / 100) * plotH
  }

  function dutyFromY(y) {
    var t = (y - padT) / plotH
    var duty = (1 - t) * 100
    return Math.max(minDuty, Math.min(100, Math.round(duty)))
  }

  onPointsChanged: {
    if (dragIndex < 0) syncLive()
    canvas.requestPaint()
  }
  Component.onCompleted: syncLive()
  onLivePointsChanged: canvas.requestPaint()
  onCurrentTempChanged: canvas.requestPaint()
  onAccentChanged: canvas.requestPaint()
  onForegroundChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()
  onMinDutyChanged: {
    if (dragIndex < 0) syncLive()
    canvas.requestPaint()
  }

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
      ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.12)
      ctx.lineWidth = 1

      var duties = [0, 25, 50, 75, 100]
      for (var g = 0; g < duties.length; g++) {
        var y = root.yAt(duties[g])
        ctx.beginPath()
        ctx.moveTo(root.padL, y)
        ctx.lineTo(root.width - root.padR, y)
        ctx.stroke()
      }

      if (root.minDuty > 0) {
        var yFloor = root.yAt(root.minDuty)
        var yZero = root.yAt(0)
        ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.08)
        ctx.fillRect(root.padL, yFloor, root.plotW, Math.max(0, yZero - yFloor))
        ctx.beginPath()
        ctx.moveTo(root.padL, yFloor)
        ctx.lineTo(root.width - root.padR, yFloor)
        ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.35)
        ctx.stroke()
      }

      var pts = root.livePoints && root.livePoints.length ? root.livePoints : (root.points || [])
      if (pts.length >= 2) {
        var floorY = root.yAt(root.minDuty)
        ctx.beginPath()
        ctx.moveTo(root.xAt(0), root.yAt(root.dutyAt(0)))
        for (var i = 1; i < root.n; i++)
          ctx.lineTo(root.xAt(i), root.yAt(root.dutyAt(i)))
        ctx.lineTo(root.xAt(root.n - 1), floorY)
        ctx.lineTo(root.xAt(0), floorY)
        ctx.closePath()
        ctx.fillStyle = Qt.rgba(ac.r, ac.g, ac.b, 0.18)
        ctx.fill()

        ctx.beginPath()
        ctx.moveTo(root.xAt(0), root.yAt(root.dutyAt(0)))
        for (var j = 1; j < root.n; j++)
          ctx.lineTo(root.xAt(j), root.yAt(root.dutyAt(j)))
        ctx.strokeStyle = ac
        ctx.lineWidth = 2
        ctx.stroke()
      }

      if (root.currentTemp >= root.temps[0] && root.currentTemp <= root.temps[root.n - 1]) {
        var t0 = root.temps[0]
        var t1 = root.temps[root.n - 1]
        var tx = root.padL + ((root.currentTemp - t0) / (t1 - t0)) * root.plotW
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
    model: root.n
    Rectangle {
      required property int index
      width: Style.space(10)
      height: width
      radius: width / 2
      x: root.xAt(index) - width / 2
      y: root.yAt(root.dutyAt(index)) - height / 2
      color: root.interactive ? root.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
      border.width: 1
      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.85)
      z: 2
      opacity: root.interactive ? 1 : 0.7

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(8)
        enabled: root.interactive
        cursorShape: root.interactive ? Qt.SizeVerCursor : Qt.ArrowCursor
        preventStealing: true
        onPressed: root.dragIndex = index
        onPositionChanged: function(mouse) {
          if (!pressed) return
          var gy = mapToItem(root, mouse.x, mouse.y).y
          var duty = root.dutyFromY(gy)
          root.livePoints = Model.applyMonotonic(root.livePoints, index, duty, root.minDuty)
          root.pointChanged(index, duty)
        }
        onReleased: {
          root.dragIndex = -1
          root.dragFinished()
        }
      }
    }
  }

  // Axis labels
  Repeater {
    model: [0, n - 1]
    Text {
      required property int index
      required property var modelData
      x: root.xAt(modelData) - implicitWidth / 2
      y: root.height - implicitHeight
      text: String(root.temps[modelData]) + "°"
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
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
    text: String(root.minDuty) + "%"
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
