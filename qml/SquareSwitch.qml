import QtQuick
import qs.Commons

// Square on/off track used by the channel cards and the theme-sync row.
// On is the accent fill. Off is an empty grey track. The caller owns `on`.
Item {
  id: root

  property bool on: false
  property bool switchEnabled: true
  property bool interactive: true
  property color foreground: Color.foreground
  property color accent: Color.accent

  signal clicked()

  readonly property int trackH: Math.max(14, Style.space(16))
  readonly property int trackW: Math.round(trackH * 1.9)

  implicitWidth: trackW
  implicitHeight: trackH

  Rectangle {
    id: track
    anchors.fill: parent
    radius: 0
    color: root.on && root.switchEnabled
      ? root.accent
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, root.switchEnabled ? 0.16 : 0.08)
    border.width: 1
    border.color: root.on && root.switchEnabled
      ? root.accent
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.28)

    Rectangle {
      width: Math.round(track.height * 0.72)
      height: width
      radius: 0
      anchors.verticalCenter: parent.verticalCenter
      x: root.on && root.switchEnabled
        ? track.width - width - Math.round((track.height - height) / 2)
        : Math.round((track.height - height) / 2)
      color: root.on && root.switchEnabled
        ? Color.background
        : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.4)
      Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.interactive && root.switchEnabled
    hoverEnabled: true
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: root.clicked()
  }
}
