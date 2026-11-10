.pragma library

// One set of JetBrainsMono Nerd Font marks for the window and the bar chip.
// Material icons live above U+FFFF. The pages share these so a fan, a
// thermometer, and a curve are the same character everywhere.
function g(cp) {
  return String.fromCodePoint(cp)
}

var fan = g(0xF0210)
// About panel: oct-cpu and fae-chip.
var cpu = g(0xF4BC)
var gpu = g(0xE266)
var liquid = g(0xF1A86)
// fa-line_chart. The monitoring rail used this before the material set.
var monitor = g(0xF201)
// fa-chart_area. The modes rail used this before the sine wave.
var modes = g(0xF1FE)
var curve = g(0xF095B)
var lcd = g(0xF0379)
// fa-info-circle. The filled mark Ionosphere uses on its Info button.
// U+F02FD is the outline, which reads as a thin ring at this size.
var info = g(0xF05A)
var settings = g(0xF0493)
var silent = g(0xF0594)
var performance = g(0xF140B)
var fixed = g(0xF0341)
var hell = g(0xF0238)
var open = g(0xF03CC)
var power = g(0xF0425)
// fa-window-maximize. A frame with a title bar. U+F05EF is an open envelope.
var frame = g(0xF2D0)
var alerts = g(0xF009C)

function modeMark(name) {
  var n = String(name || "").toLowerCase()
  if (n.indexOf("hell") >= 0) return hell
  if (n.indexOf("silent") >= 0) return silent
  if (n.indexOf("perf") >= 0) return performance
  if (n.indexOf("fixed") >= 0) return fixed
  return curve
}
