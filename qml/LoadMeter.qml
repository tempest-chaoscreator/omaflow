import QtQuick
import qs.Commons

// Horizontal LED row. Unlit squares stay dim. The residual square is the one
// the parent holds above the live fill.
Item {
  id: meter

  property var palette: []
  property int squares: 12
  property int lit: 0
  property int hold: -1
  property int cell: Style.space(8)
  property int gap: Style.space(2)

  implicitWidth: squares * cell + Math.max(0, squares - 1) * gap
  implicitHeight: cell
  width: implicitWidth
  height: implicitHeight

  function colorAt(index) {
    var list = palette || []
    if (!list.length) return "#888888"
    var slot = Math.floor(index * list.length / Math.max(1, squares))
    if (slot < 0) slot = 0
    if (slot >= list.length) slot = list.length - 1
    return list[slot]
  }

  Repeater {
    model: meter.squares
    delegate: Rectangle {
      required property int index
      x: index * (meter.cell + meter.gap)
      y: 0
      width: meter.cell
      height: meter.cell
      radius: 1
      color: meter.colorAt(index)
      opacity: {
        var filled = index < meter.lit
        var peak = index === meter.hold && meter.hold >= meter.lit
        return filled || peak ? 1 : 0.18
      }
    }
  }
}
