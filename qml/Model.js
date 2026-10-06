.pragma library

// CPU-temperature graphs: 28–98 °C, 15 columns, 5 °C apart.
var CPU_TEMPS = [28, 33, 38, 43, 48, 53, 58, 63, 68, 73, 78, 83, 88, 93, 98]
// GPU keeps the 20–90 axis the Silent handoff was tuned on.
var GPU_TEMPS = [20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90]
// Coolant graphs stop at 60 °C. 2 °C columns so the 34–38 °C band is editable.
var LIQUID_TEMPS = [28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60]
var TEMPS = CPU_TEMPS
var POINT_COUNT = 15
var FAN_MIN = 20
var PUMP_MIN = 50
var CHANNELS = ["chassis", "cpu", "gpu", "aio", "pump"]
var SENSOR_CHANNELS = ["pump", "aio", "cpu"]
var MODES = ["silent", "static", "performance", "hell", "custom"]

function clamp(v, lo, hi) {
  var n = Number(v)
  if (!isFinite(n)) n = lo
  return Math.max(lo, Math.min(hi, n))
}

function hex2(n) {
  var s = Math.round(clamp(n, 0, 255)).toString(16)
  return s.length < 2 ? "0" + s : s
}

// "#rrggbb" from a QML color, "#rrggbb", or "#aarrggbb". Qt 6 often
// stringifies as #AARRGGBB; taking the first six digits of that would
// turn Ristretto's orange into near-white (#fff38d).
function hexOf(value) {
  if (value === undefined || value === null) return ""
  if (typeof value === "string") {
    var s = value.replace(/^\s+|\s+$/g, "")
    if (s.charAt(0) === "#") s = s.slice(1)
    if (s.length === 8) s = s.slice(2)
    if (s.length === 3) s = s.charAt(0) + s.charAt(0) + s.charAt(1) + s.charAt(1) + s.charAt(2) + s.charAt(2)
    if (!/^[0-9a-fA-F]{6}$/.test(s)) return ""
    return "#" + s.toLowerCase()
  }
  if (typeof value.r === "number" && typeof value.g === "number" && typeof value.b === "number") {
    var scale = (value.r <= 1 && value.g <= 1 && value.b <= 1) ? 255 : 1
    return "#" + hex2(value.r * scale) + hex2(value.g * scale) + hex2(value.b * scale)
  }
  return hexOf(String(value))
}

function round1(v) {
  return Math.round(Number(v) * 10) / 10
}

function formatTemp(v) {
  if (v === undefined || v === null || v === "" || !isFinite(Number(v))) return "—"
  return Math.round(Number(v)) + "°"
}

function formatRpm(v) {
  if (v === undefined || v === null || !isFinite(Number(v))) return "—"
  return Math.round(Number(v)) + " rpm"
}

function formatDuty(v) {
  if (v === undefined || v === null || !isFinite(Number(v))) return "—"
  return Math.round(Number(v)) + "%"
}

function formatWatts(v) {
  if (v === undefined || v === null || !isFinite(Number(v))) return "—"
  return round1(v) + " W"
}

function tempTone(temp, urgent, accent, foreground) {
  var t = Number(temp)
  if (!isFinite(t)) return foreground
  if (t >= 85) return urgent
  if (t >= 70) return Qt.rgba(0.92, 0.62, 0.22, 1)
  return accent
}

function modeLabel(id) {
  switch (String(id)) {
  case "silent": return "Silent"
  case "static": return "Static"
  case "performance": return "Performance"
  case "hell": return "Hell"
  case "custom": return "Custom"
  default: return String(id)
  }
}

function channelLabel(id) {
  switch (String(id)) {
  case "chassis": return "Chassis"
  case "cpu": return "CPU"
  case "gpu": return "GPU"
  case "aio": return "AIO"
  case "pump": return "Pump"
  default: return String(id)
  }
}

function channelMin(id) {
  return String(id) === "pump" ? PUMP_MIN : 0
}

function hasSensor(id) {
  return SENSOR_CHANNELS.indexOf(String(id)) !== -1
}

function axisFor(channel, sensor) {
  if (String(channel) === "gpu") return GPU_TEMPS
  if (hasSensor(channel) && String(sensor) === "liquid") return LIQUID_TEMPS
  return CPU_TEMPS
}

function copyPoints(points, minDuty, count) {
  var lo = minDuty === undefined ? 0 : Number(minDuty)
  if (!isFinite(lo)) lo = 0
  var src = Array.isArray(points) ? points : []
  var n = Number(count)
  if (!(n >= 2)) n = src.length >= 2 ? src.length : POINT_COUNT
  var out = []
  for (var i = 0; i < n; i++) {
    var v = i < src.length ? Number(src[i]) : lo
    out.push(clamp(isFinite(v) ? v : lo, lo, 100))
  }
  return out
}

// Keep the curve non-decreasing. Dragging a point up lifts every handle
// to its right; dragging down pulls every handle to its left, so you
// cannot leave a hill or a valley.
function applyMonotonic(points, index, value, minDuty) {
  var lo = minDuty === undefined ? 0 : Number(minDuty)
  if (!isFinite(lo)) lo = 0
  var src = Array.isArray(points) ? points : []
  var n = src.length >= 2 ? src.length : POINT_COUNT
  var pts = copyPoints(src, lo, n)
  var i = Math.round(Number(index))
  if (!(i >= 0 && i < n)) return pts
  var v = clamp(value, lo, 100)
  pts[i] = v
  var j
  for (j = i + 1; j < n; j++) {
    if (pts[j] < v) pts[j] = v
  }
  for (j = i - 1; j >= 0; j--) {
    if (pts[j] > v) pts[j] = v
  }
  for (j = 0; j < n; j++) {
    if (pts[j] < lo) pts[j] = lo
  }
  return pts
}

function dutyAt(points, temp, temps) {
  var axis = (temps && temps.length >= 2) ? temps : TEMPS
  var pts = copyPoints(points, 0, axis.length)
  var t = Number(temp)
  if (!isFinite(t)) t = axis[0]
  if (t <= axis[0]) return pts[0]
  if (t >= axis[axis.length - 1]) return pts[axis.length - 1]
  for (var i = 0; i < axis.length - 1; i++) {
    var a = axis[i]
    var b = axis[i + 1]
    if (t >= a && t <= b) {
      var u = (t - a) / (b - a)
      return pts[i] + (pts[i + 1] - pts[i]) * u
    }
  }
  return pts[pts.length - 1]
}

function isLocked(locks, mode) {
  if (String(mode) === "custom") return false
  if (!locks) return true
  if (typeof locks.presetsLocked === "boolean") return locks.presetsLocked !== false
  return locks[String(mode)] !== false
}

function channelEnabled(id, gpuControl, aioFanControl, cpuControl, cpuPresent, chassisControl, pumpControl) {
  if (id === "gpu") return gpuControl === true
  if (id === "aio") return aioFanControl === true
  if (id === "cpu") return cpuControl === true && cpuPresent === true
  if (id === "chassis") return chassisControl !== false
  if (id === "pump") return pumpControl !== false
  return true
}

function flavorText(mode, temp) {
  var t = Number(temp)
  if (isFinite(t) && t >= 88) return "Need a medkit"
  if (isFinite(t) && t >= 80) return "I'm on fire"
  var name = String(mode || "").replace(/^\s+|\s+$/g, "").toLowerCase()
  if (name === "silent") return "Silencer on"
  if (name === "static" || name === "fixed") return "Camping A"
  if (name === "performance") return "Rocket jump"
  if (name === "hell") return "Quad damage"
  if (name === "custom" || name) return "sv_cheats 1"
  return "Frag limit"
}

function hottest(temps) {
  var t = temps || {}
  var best = null
  var keys = ["cpu", "gpu", "coolant"]
  for (var i = 0; i < keys.length; i++) {
    var n = Number(t[keys[i]])
    if (isFinite(n) && (best === null || n > best)) best = n
  }
  return best
}

function fanByKind(fans, kind) {
  var list = Array.isArray(fans) ? fans : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].kind === kind) out.push(list[i])
  }
  return out
}

function firstFan(fans, kind) {
  var list = fanByKind(fans, kind)
  return list.length ? list[0] : null
}

function averageDuty(fans, kind) {
  var list = fanByKind(fans, kind)
  if (list.length === 0) return null
  var sum = 0
  var n = 0
  for (var i = 0; i < list.length; i++) {
    var d = Number(list[i].duty)
    if (isFinite(d)) { sum += d; n++ }
  }
  return n ? sum / n : null
}

function gpuName(gpu) {
  var name = gpu && gpu.name ? String(gpu.name) : ""
  if (name === "") return "GPU"
  return name.replace("NVIDIA GeForce ", "").replace("NVIDIA RTX ", "RTX ")
}

function lcdLabel(mode) {
  switch (String(mode)) {
  case "liquid": return "Liquid temp"
  case "accent": return "Theme accent"
  case "off": return "Off"
  default: return String(mode)
  }
}
