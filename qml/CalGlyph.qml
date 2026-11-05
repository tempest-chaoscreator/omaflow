import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// nf-md-fan U+F0210. A boxed button anchored on the right, so a reveal grows left.
// Calibrate All keeps its words. Group and channel buttons open their words on hover.
// stick keeps the square until `open` is set, which is a click rather than a hover.
Item {
  id: root

  property bool selected: false
  property string label: ""
  property bool reveal: false
  property bool stick: false
  property bool open: false
  property string mark: fanGlyph
  property color fg: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family
  readonly property string fanGlyph: "\uDB80\uDE10"
  readonly property bool hovered: hit.containsMouse
  readonly property bool hot: selected || hit.containsMouse || (stick && open)
  readonly property bool words: label !== "" && (stick ? open : (!reveal || hit.containsMouse || selected))
  signal clicked()

  implicitWidth: words
    ? Style.space(16) + Style.space(4) + word.implicitWidth + Style.space(14)
    : Style.space(22)
  implicitHeight: Style.space(22)
  width: implicitWidth
  height: implicitHeight
  clip: true

  Behavior on implicitWidth {
    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
  }

  Rectangle {
    anchors.fill: parent
    radius: 0
    color: (root.selected || (root.stick && root.open))
      ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
      : (hit.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06) : "transparent")
    border.width: 1
    border.color: root.hot
      ? root.accent
      : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.28)
  }

  // The fan stays on the right. The label grows to the left.
  Row {
    anchors.right: parent.right
    anchors.rightMargin: Style.space(3)
    anchors.verticalCenter: parent.verticalCenter
    layoutDirection: Qt.RightToLeft
    spacing: root.words ? Style.space(4) : 0

    OpticalGlyph {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(16)
      height: Style.space(16)
      text: root.mark
      fontFamily: root.fontFamily
      fontSize: Style.space(16)
      color: root.hot ? root.accent : root.fg
    }

    Text {
      id: word
      anchors.verticalCenter: parent.verticalCenter
      visible: root.words
      text: root.label
      textFormat: Text.PlainText
      color: root.hot ? root.accent : root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.space(12)
    }
  }

  MouseArea {
    id: hit
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
