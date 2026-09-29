import QtQuick
import qs.Commons

// Square action button. Radius stays 0 so it matches the task-manager controls.
Item {
  id: root

  property string text: ""
  property bool selected: false
  property bool fillWidth: false

  signal clicked()

  implicitWidth: fillWidth ? (parent ? parent.width : 0) : label.implicitWidth + Style.space(20)
  implicitHeight: Style.space(32)
  width: implicitWidth
  height: implicitHeight

  Rectangle {
    anchors.fill: parent
    radius: 0
    color: root.selected
      ? Color.accent
      : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
    border.width: 1
    border.color: root.selected
      ? Color.accent
      : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.28)

    Text {
      id: label
      anchors.centerIn: parent
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      text: root.text
      color: root.selected ? Color.background : Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.space(12)
      font.bold: root.selected
      elide: Text.ElideRight
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
