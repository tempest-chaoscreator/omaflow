.pragma library

// Neighbor in a grid of controls. x and y are cells, not pixels.
// A step only considers a control that sits strictly in that direction.
function step(items, index, dx, dy) {
  if (!items || !items.length) return 0
  var i = index
  if (!(i >= 0) || i >= items.length) i = 0
  if (!dx && !dy) return i
  var cur = items[i] || {}
  var cx = Number(cur.x) || 0
  var cy = Number(cur.y) || 0
  var best = -1
  var bestScore = 1e12
  for (var n = 0; n < items.length; n++) {
    if (n === i) continue
    var item = items[n] || {}
    var ox = (Number(item.x) || 0) - cx
    var oy = (Number(item.y) || 0) - cy
    if (dx > 0 && ox <= 0) continue
    if (dx < 0 && ox >= 0) continue
    if (dy > 0 && oy <= 0) continue
    if (dy < 0 && oy >= 0) continue
    var primary = dx !== 0 ? Math.abs(ox) : Math.abs(oy)
    var cross = dx !== 0 ? Math.abs(oy) : Math.abs(ox)
    var score = primary + cross * 3
    if (score < bestScore) {
      bestScore = score
      best = n
    }
  }
  return best >= 0 ? best : i
}
