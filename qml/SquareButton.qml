import QtQuick
import qs.Commons
import qs.Commons as Commons

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
      ? Commons.Color.accent
      : Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.06)
    border.width: 1
    border.color: root.selected
      ? Commons.Color.accent
      : Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.28)

    Text {
      id: label
      anchors.centerIn: parent
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      text: root.text
      color: root.selected ? Commons.Color.background : Commons.Color.foreground
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
