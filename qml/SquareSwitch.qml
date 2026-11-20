import QtQuick
import qs.Commons
import qs.Commons as Commons

// Square on/off track used by the channel cards and the theme-sync row.
// On is the accent fill. Off is an empty grey track. The caller owns `on`.
Item {
  id: root

  property bool on: false
  property bool switchEnabled: true
  property bool interactive: true
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent

  signal clicked()

  readonly property int trackH: Math.max(14, Style.space(16))
  readonly property int trackW: Math.round(trackH * 1.9)

  implicitWidth: trackW
  implicitHeight: trackH

  Rectangle {
    id: track
    anchors.fill: parent
    radius: 0
    opacity: root.switchEnabled ? 1 : 0.45
    color: root.on
      ? root.accent
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
    border.width: 1
    border.color: root.on
      ? root.accent
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.28)

    Rectangle {
      width: Math.round(track.height * 0.72)
      height: width
      radius: 0
      anchors.verticalCenter: parent.verticalCenter
      x: root.on
        ? track.width - width - Math.round((track.height - height) / 2)
        : Math.round((track.height - height) / 2)
      color: root.on
        ? Commons.Color.background
        : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.4)
      Behavior on x { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
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
