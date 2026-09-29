import QtQuick
import qs.Commons
import qs.Ui

// One row in the standalone rail.
Rectangle {
  id: root

  property string label: ""
  property string mark: ""
  property bool on: false
  property bool armed: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal picked()

  width: parent ? parent.width : implicitWidth
  height: Style.space(36)
  radius: 0
  color: on
    ? Qt.rgba(accent.r, accent.g, accent.b, 0.14)
    : (armed ? Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06) : "transparent")

  Rectangle {
    width: 2
    height: parent.height
    visible: root.armed
    color: root.accent
  }

  OpticalGlyph {
    id: glyph
    anchors.left: parent.left
    anchors.leftMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(16)
    height: Style.space(16)
    text: root.mark
    fontFamily: root.fontFamily
    fontSize: Style.space(14)
    color: root.on || root.armed ? root.accent : root.foreground
  }

  Text {
    anchors.left: glyph.right
    anchors.leftMargin: Style.space(10)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    text: root.label
    color: root.on || root.armed ? root.accent : root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.space(13)
    font.bold: root.on
    elide: Text.ElideRight
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.picked()
  }
}
