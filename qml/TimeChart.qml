import QtQuick
import qs.Commons

// Several series on one time axis. Missing samples break the line.
Item {
  id: root

  property var series: []
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  onSeriesChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  function bounds() {
    var lo = 0
    var hi = 40
    var list = series || []
    for (var s = 0; s < list.length; s++) {
      var values = list[s] && list[s].values ? list[s].values : []
      for (var i = 0; i < values.length; i++) {
        var n = Number(values[i])
        if (!isFinite(n)) continue
        if (n < lo) lo = n
        if (n > hi) hi = n
      }
    }
    if (hi <= 100 && lo >= 0) hi = 100
    if (hi - lo < 10) hi = lo + 10
    return { lo: lo, hi: hi }
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    anchors.leftMargin: Style.space(28)
    anchors.bottomMargin: Style.space(4)
    antialiasing: true
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.clearRect(0, 0, width, height)
      var span = root.bounds()
      var fg = root.foreground
      ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.12)
      ctx.lineWidth = 1
      var marks = [0, 0.25, 0.5, 0.75, 1]
      for (var g = 0; g < marks.length; g++) {
        var y = height - marks[g] * height
        ctx.beginPath()
        ctx.moveTo(0, y)
        ctx.lineTo(width, y)
        ctx.stroke()
      }
      var list = root.series || []
      for (var s = 0; s < list.length; s++) {
        var values = list[s] && list[s].values ? list[s].values : []
        if (values.length < 2) continue
        ctx.beginPath()
        ctx.strokeStyle = list[s].color
        ctx.lineWidth = 1.6
        var started = false
        for (var i = 0; i < values.length; i++) {
          var n = Number(values[i])
          if (!isFinite(n)) { started = false; continue }
          var x = values.length === 1 ? 0 : (i / (values.length - 1)) * width
          var yv = height - ((n - span.lo) / (span.hi - span.lo)) * height
          if (!started) { ctx.moveTo(x, yv); started = true }
          else ctx.lineTo(x, yv)
        }
        ctx.stroke()
      }
    }
  }

  Text {
    anchors.left: parent.left
    anchors.top: parent.top
    text: Math.round(root.bounds().hi)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    text: Math.round(root.bounds().lo)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
