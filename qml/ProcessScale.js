// Per-process meter scale. Plain functions so a node harness can load this file.
// `floor` is the quiet-row scale top: the row never zooms tighter than that percent.
// CPU passes 2. GPU passes 20. Header totals stay on a fixed 0–100 scale.

function ceiling(recordedMax, floor) {
  var max = Number(recordedMax)
  if (!isFinite(max) || max < 0) max = 0
  var minTop = Number(floor)
  if (!isFinite(minTop) || minTop < 0) minTop = 0
  var top = max * 1.15
  return top > minTop ? top : minTop
}

function litCount(percent, top, squares) {
  var count = Number(squares)
  if (!isFinite(count) || count < 1) count = 1
  var value = Number(percent)
  var scale = Number(top)
  if (!isFinite(value) || value <= 0 || !isFinite(scale) || scale <= 0) return 0
  var lit = Math.round(value / scale * count)
  if (lit < 0) lit = 0
  if (lit > count) lit = count
  return lit
}

function decayMax(recorded, latest, floor) {
  var max = Number(recorded)
  var sample = Number(latest)
  if (!isFinite(max) || max < 0) max = 0
  if (!isFinite(sample) || sample < 0) sample = 0
  var minTop = Number(floor)
  if (!isFinite(minTop) || minTop < 0) minTop = 0
  var next = max * 0.9
  // Keep the peak on the display floor. ceiling() multiplies by 1.15,
  // so dividing here makes a quiet row land on that floor instead of above it.
  var bottom = Math.max(sample, minTop > 0 ? minTop / 1.15 : 0)
  if (next < bottom) next = bottom
  return next
}

function stepHold(hold, lit) {
  var peak = Number(hold)
  if (!isFinite(peak)) peak = -1
  var count = Number(lit)
  if (!isFinite(count) || count < 0) count = 0
  var top = count > 0 ? count - 1 : -1
  if (top > peak) return top
  if (peak > top) return peak - 1
  return top
}
