// Per-process meter scale. Plain functions so a node harness can load this file.

function ceiling(recordedMax) {
  var max = Number(recordedMax)
  if (!isFinite(max) || max < 0) max = 0
  var top = max * 1.15
  return top > 4 ? top : 4
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

function decayMax(recorded, latest) {
  var max = Number(recorded)
  var sample = Number(latest)
  if (!isFinite(max) || max < 0) max = 0
  if (!isFinite(sample) || sample < 0) sample = 0
  var next = max * 0.9
  var floor = Math.max(sample, 4)
  if (next < floor) next = floor
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
