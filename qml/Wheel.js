.pragma library

// One notch of a physical wheel. Qt's Flickable turns that notch into a flick,
// and the flick restarts on the next notch, which is the stutter.
var NOTCH = 64

function deltaY(event) {
  if (!event) return 0
  var angle = event.angleDelta ? event.angleDelta.y : 0
  var pixel = event.pixelDelta ? event.pixelDelta.y : 0
  var phase = event.phase
  var gesture = phase === Qt.ScrollBegin || phase === Qt.ScrollUpdate
    || phase === Qt.ScrollMomentum || phase === Qt.ScrollEnd
  // A mouse wheel reports NoScrollPhase. Its pixelDelta is often 0 or 1,
  // and following that 1 is a crawl. A trackpad reports a scroll phase.
  if (gesture && pixel) return pixel
  if (angle) return angle / 120 * NOTCH
  return pixel || 0
}

function roll(flick, event) {
  if (!flick || !event) return false
  var dy = deltaY(event)
  var limit = Math.max(0, flick.contentHeight - flick.height)
  var next = (flick.contentY || 0) - dy
  if (next < 0) next = 0
  if (next > limit) next = limit
  next = Math.round(next)
  flick.cancelFlick()
  if (Math.abs(next - flick.contentY) < 0.5) return false
  flick.contentY = next
  return true
}
