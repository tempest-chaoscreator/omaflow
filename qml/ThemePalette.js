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

// Modes and Devices bars. Named inks from the theme that is loaded now.
// Brown stays last. swatch holds it for one leftover block and leaves it
// out of the repeat, because it reads as mud next to the others.
function blockInks(raw) {
  var parsed = parse(raw)
  var colors = take(parsed, ["red", "yellow", "orange", "green", "cyan", "blue", "magenta"])
  if (!colors.length) return ramp(raw)
  if (parsed.brown) colors.push(parsed.brown)
  return colors
}

// Same order as the Devices list, so both tabs paint one color per block.
// Hidden blocks sit at the end, then names. Groups lead when they are pinned.
function blockKeys(channels, groups, hiddenDevices, hiddenChannels, pinGroups) {
  var byKey = ({})
  var list = channels || []
  var i
  for (i = 0; i < list.length; i++) if (list[i] && list[i].key) byKey[list[i].key] = list[i]
  function concealed(channel) {
    if (!channel) return false
    var uid = channel.deviceUid
    if (uid && hiddenDevices && hiddenDevices[uid] === true) return true
    var key = channel.key
    return !!(key && hiddenChannels && hiddenChannels[key] === true)
  }
  var devices = []
  var seen = ({})
  for (i = 0; i < list.length; i++) {
    var channel = list[i]
    if (!channel || !channel.deviceUid || seen[channel.deviceUid]) continue
    seen[channel.deviceUid] = true
    devices.push({
      key: "d:" + channel.deviceUid,
      name: String(channel.deviceName || "Device"),
      hidden: !!(hiddenDevices && hiddenDevices[channel.deviceUid] === true)
    })
  }
  devices.sort(function(a, b) {
    if (a.hidden !== b.hidden) return a.hidden ? 1 : -1
    return a.name.localeCompare(b.name)
  })
  var cards = []
  var saved = groups || []
  for (i = 0; i < saved.length; i++) {
    var group = saved[i]
    if (!group || !group.id) continue
    var members = group.members || []
    var any = false
    var hidden = true
    var m
    for (m = 0; m < members.length; m++) {
      var row = byKey[members[m]]
      if (!row) continue
      any = true
      if (!concealed(row)) hidden = false
    }
    if (!any) continue
    cards.push({ key: "g:" + group.id, name: String(group.name || "Group"), hidden: hidden })
  }
  cards.sort(function(a, b) {
    if (a.hidden !== b.hidden) return a.hidden ? 1 : -1
    return a.name.localeCompare(b.name)
  })
  var rows = pinGroups ? cards.concat(devices) : devices.concat(cards)
  var keys = []
  for (i = 0; i < rows.length; i++) keys.push(rows[i].key)
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
  var at = 0
  var want = String(key || "")
  for (i = 0; i < sorted.length; i++) {
    if (sorted[i] === want) {
      at = i
      break
    }
  }
  // A full named set ends in brown. Use it only when exactly one block is
  // left after the other inks. More blocks than that repeat those inks.
  var cycle = list
  var reserved = ""
  if (list.length >= 8) {
    reserved = list[list.length - 1]
    cycle = list.slice(0, list.length - 1)
  }
  var n = sorted.length
  if (reserved && n === cycle.length + 1 && at === n - 1) return reserved
  return cycle[at % cycle.length]
}
