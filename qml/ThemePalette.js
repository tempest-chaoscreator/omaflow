// Theme square colors for the process meters. Does not write the shell Color singleton.

function parse(raw) {
  var palette = ({})
  var lines = String(raw || "").split("\n")
  var i
  for (i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (match) palette[match[1]] = match[2].toLowerCase()
  }
  return palette
}

function channel(hex, index) {
  return parseInt(hex.substr(index, 2), 16)
}

function mix(from, to, t) {
  var amount = t < 0 ? 0 : (t > 1 ? 1 : t)
  var r = Math.round(channel(from, 1) + (channel(to, 1) - channel(from, 1)) * amount)
  var g = Math.round(channel(from, 3) + (channel(to, 3) - channel(from, 3)) * amount)
  var b = Math.round(channel(from, 5) + (channel(to, 5) - channel(from, 5)) * amount)
  function byte(value) {
    var hex = value.toString(16)
    return hex.length < 2 ? "0" + hex : hex
  }
  return "#" + byte(r) + byte(g) + byte(b)
}

function hexOf(color) {
  if (!color) return ""
  if (typeof color === "string") {
    var text = color.toLowerCase()
    return text.charAt(0) === "#" && text.length >= 7 ? text.substr(0, 7) : ""
  }
  if (typeof color.r !== "number") return ""
  function byte(value) {
    var hex = Math.round(Math.max(0, Math.min(1, value)) * 255).toString(16)
    return hex.length < 2 ? "0" + hex : hex
  }
  return "#" + byte(color.r) + byte(color.g) + byte(color.b)
}

function take(palette, keys) {
  var colors = []
  var i
  for (i = 0; i < keys.length; i++) if (palette[keys[i]]) colors.push(palette[keys[i]])
  return colors
}

function ramp(raw, accent, urgent) {
  var palette = parse(raw)
  // color2 green, color6 cyan, color4 blue, color5 magenta, color1 red.
  // Omarchy themes often store those as names instead of colorN.
  var colors = take(palette, ["color2", "color6", "color4", "color5", "color1"])
  if (colors.length < 2) colors = take(palette, ["green", "cyan", "blue", "magenta", "red"])
  if (colors.length >= 2) return colors
  var from = palette.accent || hexOf(accent) || "#6aa8ff"
  var to = palette.color1 || palette.red || hexOf(urgent) || from
  var out = []
  var i
  for (i = 0; i < 5; i++) out.push(mix(from, to, i / 4))
  return out
}

// Same device and group keys on Devices and Modes, so both tabs pick the same square.
function keysOf(channels, groups) {
  var keys = []
  var list = channels || []
  var i
  for (i = 0; i < list.length; i++) {
    var uid = list[i] && list[i].deviceUid
    if (uid) keys.push("d:" + uid)
  }
  var saved = groups || []
  for (i = 0; i < saved.length; i++) {
    var id = saved[i] && saved[i].id
    if (id) keys.push("g:" + id)
  }
  return keys
}

function swatch(palette, keys, key) {
  var list = palette && palette.length ? palette : ["#a7c080", "#83c092", "#7fbbb3", "#d699b6", "#e67e80"]
  var sorted = []
  var seen = ({})
  var src = keys || []
  var i
  for (i = 0; i < src.length; i++) {
    var item = String(src[i] || "")
    if (!item || seen[item]) continue
    seen[item] = true
    sorted.push(item)
  }
  sorted.sort()
  var at = 0
  var want = String(key || "")
  for (i = 0; i < sorted.length; i++) {
    if (sorted[i] === want) {
      at = i
      break
    }
  }
  return list[at % list.length]
}
