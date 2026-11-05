import QtQuick
import qs.Commons
import qs.Commons as Commons
import "Wheel.js" as Wheel

// Overlay scroller. It sits on the viewport, shows while the pointer is in
// the lane or the view is moving, and fades after the motion stops.
Item {
  id: root

  property var flick: null
  property color ink: Commons.Color.foreground

  readonly property bool overflow: flick && flick.contentHeight > flick.height + 1
  readonly property real span: flick ? Math.max(0, flick.contentHeight - flick.height) : 0
  readonly property real handleH: {
    if (!flick || !overflow || flick.contentHeight <= 0) return height
    return Math.max(Style.space(28), height * (flick.height / flick.contentHeight))
  }
  readonly property real handleY: {
    var room = Math.max(0, height - handleH)
    if (!flick || span <= 0) return 0
    return Math.max(0, Math.min(room, (flick.contentY / span) * room))
  }
  property bool moving: false
  // The lane's mouse area sits above the hover handler, so containsMouse is the one that sees the pointer.
  readonly property bool hot: lane.hovered || drag.containsMouse || drag.pressed
  readonly property bool shown: overflow && (hot || moving)

  // The rest knob is 6px. The lane is wider than the knob so a hover can find it.
  readonly property real laneWidth: Style.space(14)
  readonly property real restWidth: Style.space(6)
  width: laneWidth
  visible: overflow && flick && flick.visible
  z: 40

  function jump(at) {
    if (!flick || span <= 0) return
    var room = Math.max(1, height - handleH)
    var next = ((at - handleH / 2) / room) * span
    flick.cancelFlick()
    flick.contentY = Math.max(0, Math.min(span, next))
  }

  HoverHandler { id: lane }

  Timer {
    id: hold
    interval: 700
    onTriggered: root.moving = false
  }

  Connections {
    target: root.flick
    function onContentYChanged() {
      if (!root.flick || !root.flick.visible) return
      root.moving = true
      hold.restart()
    }
  }

  Item {
    anchors.fill: parent
    opacity: root.shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: root.shown ? 0 : 180 } }

    Rectangle {
      anchors.fill: parent
      visible: root.hot
      color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.08)
    }

    Rectangle {
      x: root.hot ? Style.space(2) : parent.width - width - Style.space(2)
      y: root.handleY
      width: root.hot ? parent.width - Style.space(4) : root.restWidth
      height: root.handleH
      radius: 0
      antialiasing: false
      color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, root.hot ? 0.62 : 0.5)
    }
  }

  MouseArea {
    id: drag
    anchors.fill: parent
    hoverEnabled: true
    preventStealing: true
    cursorShape: Qt.PointingHandCursor
    onPressed: function(mouse) { root.jump(mouse.y) }
    onPositionChanged: function(mouse) { if (pressed) root.jump(mouse.y) }
    onWheel: function(wheel) {
      Wheel.roll(root.flick, wheel)
      wheel.accepted = true
    }
  }
}
