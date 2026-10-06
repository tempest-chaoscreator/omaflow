import QtQuick
import qs.Commons

// Duty on x, RPM on y. Samples keep the daemon spacing: dense near
// kick-in, wider steps after that. This is not a temperature curve.
Item {
  id: root

  property var samples: []
  property color stroke: Color.accent
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  implicitHeight: Style.space(80)
  height: Style.space(80)

  onSamplesChanged: canvas.requestPaint()
  onStrokeChanged: canvas.requestPaint()
  onForegroundChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  readonly property real topRpm: {
    var src = samples || []
    var max = 0
    for (var i = 0; i < src.length; i++) {
      var rpm = Number(src[i] && src[i].rpm)
      if (isFinite(rpm) && rpm > max) max = rpm
    }
    return max
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.clearRect(0, 0, width, height)
      var src = root.samples || []
      var pts = []
      var i
      for (i = 0; i < src.length; i++) {
        var row = src[i]
        if (!row) continue
        var duty = Number(row.duty)
        var rpm = Number(row.rpm)
        if (!isFinite(duty) || !isFinite(rpm)) continue
        pts.push({ duty: duty, rpm: rpm })
      }
      if (pts.length < 2) return

      var padL = 2
      var padR = 2
      var padT = Style.space(14)
      var padB = Style.space(16)
      var plotW = Math.max(1, width - padL - padR)
      var plotH = Math.max(1, height - padT - padB)
      var maxRpm = Math.max(1, root.topRpm)
      var fg = root.foreground

      ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.16)
      ctx.lineWidth = 1
      var marks = [0, 25, 50, 75, 100]
      var g
      for (g = 0; g < marks.length; g++) {
        var gx = padL + (marks[g] / 100) * plotW
        ctx.beginPath()
        ctx.moveTo(gx, padT)
        ctx.lineTo(gx, padT + plotH)
        ctx.stroke()
      }

      ctx.beginPath()
      for (i = 0; i < pts.length; i++) {
        var x = padL + (Math.max(0, Math.min(100, pts[i].duty)) / 100) * plotW
        var y = padT + (1 - (pts[i].rpm / maxRpm)) * plotH
        if (i === 0) ctx.moveTo(x, y)
        else ctx.lineTo(x, y)
      }
      ctx.strokeStyle = root.stroke
      ctx.lineWidth = 1.8
      ctx.stroke()
    }
  }

  Text {
    anchors.left: parent.left
    anchors.top: parent.top
    text: root.topRpm > 0 ? Math.round(root.topRpm) + " rpm" : ""
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
    font.family: root.fontFamily
    font.pixelSize: Style.space(10)
  }

  Text {
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    text: "0%"
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
    font.family: root.fontFamily
    font.pixelSize: Style.space(10)
  }

  Text {
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    text: "100%"
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
    font.family: root.fontFamily
    font.pixelSize: Style.space(10)
  }
}
