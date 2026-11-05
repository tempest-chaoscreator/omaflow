import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// One row in the standalone rail.
Rectangle {
  id: root

  property string label: ""
  property string mark: ""
  property bool on: false
  property bool armed: false
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family

  signal picked()

  width: parent ? parent.width : implicitWidth
  height: Style.space(36)
  radius: 0
  color: on
    ? Qt.rgba(accent.r, accent.g, accent.b, hit.containsMouse ? 0.20 : 0.14)
    : ((armed || hit.containsMouse) ? Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06) : "transparent")

  Rectangle {
    width: 2
    height: parent.height
    visible: root.armed
    color: root.accent
  }

  OpticalGlyph {
    id: glyph
    visible: root.mark !== ""
    anchors.left: parent.left
    anchors.leftMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    width: visible ? Style.space(16) : 0
    height: Style.space(16)
    text: root.mark
    fontFamily: root.fontFamily
    fontSize: Style.space(14)
    color: root.on || root.armed || hit.containsMouse ? root.accent : root.foreground
  }

  Text {
    anchors.left: glyph.right
    anchors.leftMargin: root.mark !== "" ? Style.space(10) : Style.space(8)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    text: root.label
    color: root.on || root.armed || hit.containsMouse ? root.accent : root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.space(13)
    font.bold: root.on
    elide: Text.ElideRight
  }

  MouseArea {
    id: hit
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.picked()
  }
}
