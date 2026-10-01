import QtQuick
import qs.Commons

// Square speedometer. The arc and the center read duty percent.
// The caller draws the RPM under this item.
Item {
  id: root

  property real percent: -1
  property real textScale: 1
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  readonly property bool known: isFinite(percent) && percent >= 0
  property real shown: 0

  onPercentChanged: shown = known ? Math.max(0, Math.min(100, percent)) : 0
  Behavior on shown { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
  onShownChanged: dial.requestPaint()
  onTextScaleChanged: dial.requestPaint()
  onWidthChanged: dial.requestPaint()
  onHeightChanged: dial.requestPaint()
  Component.onCompleted: dial.requestPaint()

  Canvas {
    id: dial
    anchors.fill: parent
    antialiasing: true
    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      var cx = width / 2
      var cy = height * 0.56
      var radius = Math.max(8, Math.min(width, height) * 0.38)
      var start = Math.PI * 0.75
      var sweep = Math.PI * 1.5
      var span = root.known ? Math.max(0, Math.min(1, root.shown / 100)) : 0
      ctx.lineWidth = Math.max(2, Style.space(3) * Math.max(1, root.textScale))
      ctx.lineCap = "butt"
      ctx.strokeStyle = Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)
      ctx.beginPath()
      ctx.arc(cx, cy, radius, start, start + sweep, false)
      ctx.stroke()
      if (span > 0) {
        ctx.strokeStyle = root.accent
        ctx.beginPath()
        ctx.arc(cx, cy, radius, start, start + sweep * span, false)
        ctx.stroke()
      }
      var ang = start + sweep * span
      ctx.strokeStyle = root.foreground
      ctx.lineWidth = Math.max(1, Style.space(2))
      ctx.beginPath()
      ctx.moveTo(cx, cy)
      ctx.lineTo(cx + Math.cos(ang) * (radius - Style.space(2)), cy + Math.sin(ang) * (radius - Style.space(2)))
      ctx.stroke()
      ctx.fillStyle = root.foreground
      ctx.beginPath()
      ctx.arc(cx, cy, Math.max(2, Style.space(2)), 0, Math.PI * 2, false)
      ctx.fill()
    }
  }

  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    text: root.known ? Math.round(root.shown) + "%" : "—"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Math.round(Style.space(12) * Math.max(1, root.textScale))
    font.bold: true
  }
}
