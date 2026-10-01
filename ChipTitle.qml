import QtQuick
import qs.Commons
import qs.Ui

// One monitoring title. The shell glyph only shifts horizontal ink, and a
// taller slot was dropping the icon below the word. This matches the icon's
// painted center to the capital height and keeps it on the first line.
Item {
  id: root

  property string mark: ""
  property string label: ""
  property color color: Color.foreground
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.caption
  property int wrapLines: 1

  readonly property int px: Math.max(1, Math.round(fontSize))
  readonly property int slot: Style.space(16)
  readonly property real glyphLine: Math.max(1, glyphMetrics.boundingRect.height)
  readonly property real wordMid: wordMetrics.tightBoundingRect.y + wordMetrics.tightBoundingRect.height / 2
  readonly property real glyphMid: glyphMetrics.tightBoundingRect.y + glyphMetrics.tightBoundingRect.height / 2
  readonly property real inkShift: {
    var shift = wordMid - glyphMid
    var limit = Math.max(slot, glyphLine)
    if (shift > limit) shift = limit
    if (shift < -limit) shift = -limit
    return Math.round(shift)
  }

  width: parent ? parent.width : implicitWidth
  implicitHeight: Math.max(labelText.implicitHeight, Math.max(0, inkShift) + glyphLine)
  height: implicitHeight

  TextMetrics {
    id: wordMetrics
    font.family: root.fontFamily
    font.pixelSize: root.px
    font.bold: true
    text: "H"
  }

  TextMetrics {
    id: glyphMetrics
    font.family: root.fontFamily
    font.pixelSize: root.px
    text: root.mark !== "" ? root.mark : " "
  }

  Item {
    id: glyphHost
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.topMargin: root.inkShift
    width: root.slot
    height: root.glyphLine
    OpticalGlyph {
      anchors.fill: parent
      text: root.mark
      fontFamily: root.fontFamily
      fontSize: root.px
      color: root.color
    }
  }

  Text {
    id: labelText
    anchors.left: glyphHost.right
    anchors.leftMargin: Style.space(6)
    anchors.right: parent.right
    anchors.top: parent.top
    text: root.label
    color: root.color
    font.family: root.fontFamily
    font.pixelSize: root.px
    font.bold: true
    wrapMode: Text.WordWrap
    maximumLineCount: Math.max(1, root.wrapLines)
    elide: Text.ElideRight
  }
}
