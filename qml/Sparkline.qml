import QtQuick
import qs.Commons

Item {
  id: root
  property var values: []
  property color stroke: Color.accent
  property color foreground: Color.foreground
  property real minY: 20
  property real maxY: 100

  onValuesChanged: canvas.requestPaint()
  onStrokeChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.clearRect(0, 0, width, height)
      var pts = []
      var src = root.values || []
      for (var i = 0; i < src.length; i++) {
        var n = Number(src[i])
        if (isFinite(n)) pts.push(n)
      }
      if (pts.length < 2) return
      var lo = root.minY
      var hi = root.maxY
      var span = Math.max(1, hi - lo)
      ctx.beginPath()
      for (var j = 0; j < pts.length; j++) {
        var x = (j / (pts.length - 1)) * width
        var y = height - ((pts[j] - lo) / span) * height
        if (j === 0) ctx.moveTo(x, y)
        else ctx.lineTo(x, y)
      }
      ctx.strokeStyle = root.stroke
      ctx.lineWidth = 1.8
      ctx.stroke()
    }
  }
}
