// Shape coolercontrold JSON into the fields both OmaFlow surfaces read.
// Plain functions so a node harness can load this file. No hardware access.

function lastHistory(device) {
  var hist = device && device.status_history
  if (!hist || !hist.length) return null
  return hist[hist.length - 1]
}

function statusByUid(statusDevices) {
  var out = {}
  var list = statusDevices || []
  for (var i = 0; i < list.length; i++) {
    var row = list[i]
    if (!row || !row.uid) continue
    out[row.uid] = lastHistory(row)
  }
  return out
}

function isPumpName(name, label) {
  return /pump/i.test(String(name || "")) || /pump/i.test(String(label || ""))
}

function modeByUid(modes, uid) {
  var list = modes || []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].uid === uid) return list[i]
  }
  return null
}

function profileByUid(profiles, uid) {
  var list = profiles || []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].uid === uid) return list[i]
  }
  return null
}

function assigned(setting) {
  if (!setting) return false
  if (setting.speed_fixed !== undefined && setting.speed_fixed !== null) return true
  var uid = setting.profile_uid
  return !(uid === undefined || uid === null || uid === "" || uid === "0" || uid === 0)
}

function rawGraphPoints(profile) {
  if (!profile || profile.p_type !== "Graph" || !profile.speed_profile) return []
  var src = profile.speed_profile
  var out = []
  for (var i = 0; i < src.length; i++) {
    var pair = src[i]
    if (!pair || pair.length < 2) continue
    if (pair[0] === null || pair[0] === undefined || pair[1] === null || pair[1] === undefined) continue
    var x = Number(pair[0])
    var y = Number(pair[1])
    if (!isFinite(x) || !isFinite(y)) continue
    out.push([x, y])
  }
  return out
}

// Duty on the stored path. Colder than the first point keeps that duty.
// Hotter than the last point keeps that duty.
function dutyOnCurve(points, temp) {
  var pts = points || []
  if (!pts.length) return 0
  if (temp <= Number(pts[0][0])) return Number(pts[0][1])
  var last = pts[pts.length - 1]
  if (temp >= Number(last[0])) return Number(last[1])
  var i
  for (i = 1; i < pts.length; i++) {
    var t0 = Number(pts[i - 1][0])
    var d0 = Number(pts[i - 1][1])
    var t1 = Number(pts[i][0])
    var d1 = Number(pts[i][1])
    if (temp <= t1) {
      var span = t1 - t0
      var t = span ? (temp - t0) / span : 0
      return d0 + (d1 - d0) * t
    }
  }
  return Number(last[1])
}

function extendEnds(src) {
  var out = []
  var i
  for (i = 0; i < src.length; i++) {
    var temp = src[i][0]
    var duty = src[i][1]
    if (out.length && temp <= out[out.length - 1][0]) continue
    out.push([temp, duty])
  }
  if (!out.length) return out
  if (out[0][0] > 0) out.unshift([0, out[0][1]])
  if (out[out.length - 1][0] < 100) out.push([100, out[out.length - 1][1]])
  return out
}

// Fifteen points on even temperature steps from 0° to 100°.
// Duty follows the stored curve. Ends hold the first and last duty.
function spreadPoints(points, minDuty) {
  var src = []
  var i
  for (i = 0; i < (points || []).length; i++) {
    var pair = points[i]
    if (!pair || pair.length < 2) continue
    var temp = Number(pair[0])
    var duty = Number(pair[1])
    if (!isFinite(temp) || !isFinite(duty)) continue
    src.push([temp, duty])
  }
  if (!src.length) return []
  src.sort(function(a, b) { return a[0] - b[0] })
  var floor = Number(minDuty) || 0
  var same = Math.round(src[0][1])
  var flat = true
  for (i = 1; i < src.length; i++) {
    if (Math.round(src[i][1]) !== same) flat = false
  }
  if (flat && floor) same = Math.max(floor, same)
  var curve = flat ? null : extendEnds(src)
  var out = []
  var steps = 14
  for (i = 0; i <= steps; i++) {
    var at = Math.round(i * 100 / steps)
    if (out.length && at <= out[out.length - 1][0]) at = out[out.length - 1][0] + 1
    var next = flat ? same : Math.round(dutyOnCurve(curve, at))
    if (floor) next = Math.max(floor, next)
    next = Math.max(0, Math.min(100, next))
    out.push([at, next])
  }
  out[0][0] = 0
  out[out.length - 1][0] = 100
  return out
}

// Number(null) is 0. A missing reading stays missing, and a real 0 stays 0.
function finiteNum(value) {
  if (value === null || value === undefined || value === "") return null
  var n = Number(value)
  return isFinite(n) ? n : null
}

// 0 is a real floor. A missing value is the only case that still means 50.
function dutyFloor(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback
  var n = Number(value)
  if (!isFinite(n)) return fallback
  if (n < 0) return 0
  if (n > 100) return 100
  return n
}

function graphPoints(profile, floor) {
  var limit
  if (floor === undefined || floor === null || floor === "")
    limit = profile && /pump/i.test(String(profile.name || "")) ? 50 : 0
  else
    limit = dutyFloor(floor, 0)
  return spreadPoints(rawGraphPoints(profile), limit)
}

function floorCaption(isPump, minDuty) {
  if (!isPump) return ""
  var floor = Number(minDuty)
  if (isFinite(floor) && floor >= 50) return "floor 50%"
  return "floor off"
}

function withGraphPoints(profile, points, minDuty) {
  var copy = JSON.parse(JSON.stringify(profile))
  var floor = Number(minDuty) || 0
  var clamped = []
  for (var i = 0; i < points.length; i++) {
    var temp = Number(points[i][0])
    var duty = Math.round(Number(points[i][1]))
    if (!isFinite(temp) || !isFinite(duty)) continue
    if (floor) duty = Math.max(floor, duty)
    duty = Math.max(0, Math.min(100, duty))
    clamped.push([temp, duty])
  }
  copy.p_type = "Graph"
  copy.speed_profile = clamped
  return copy
}

function sensorText(row) {
  if (!row) return ""
  var name = String(row.name || "")
  var label = row.label === undefined || row.label === null ? "" : String(row.label)
  if (!label || label === name) return name
  return name + " " + label
}

function matchTemp(candidates, pattern) {
  var list = candidates || []
  var i
  for (i = 0; i < list.length; i++) {
    if (!list[i] || !pattern.test(sensorText(list[i]))) continue
    var reading = finiteNum(list[i].temp)
    if (reading !== null) return reading
  }
  return null
}

// A named sensor when the pattern hits, otherwise the hottest reading.
// Callers that need "absent" rather than a stand-in use matchTemp.
function pickTemp(candidates, pattern) {
  var found = matchTemp(candidates, pattern)
  if (found !== null) return found
  var best = null
  var list = candidates || []
  var j
  for (j = 0; j < list.length; j++) {
    var reading = list[j] ? finiteNum(list[j].temp) : null
    if (reading === null) continue
    if (best === null || reading > best) best = reading
  }
  return best
}

// "GPU Temp" wins, then a name or label that says edge, then any other
// sensor. Hotspot is last, so it cannot stand in for the edge reading.
function gpuSensorRank(name, label) {
  var primary = String(name || "")
  var secondary = label === undefined || label === null || label === "" ? primary : String(label)
  var score = 1
  if (/hotspot|hot spot/i.test(primary) || /hotspot|hot spot/i.test(secondary)) score = 0
  if (/edge/i.test(primary) || /edge/i.test(secondary)) score = 3
  if (/gpu temp$/i.test(primary) || /gpu temp$/i.test(secondary)) score = 4
  return score
}

// GPU edge. Callers pass the daemon sensor name and, when they have it, the label.
function gpuEdge(candidates) {
  var list = candidates || []
  var best = null
  var rank = -1
  var i
  for (i = 0; i < list.length; i++) {
    var row = list[i]
    var temp = row ? finiteNum(row.temp) : null
    if (temp === null) continue
    var score = gpuSensorRank(row.name, row.label)
    if (score > rank) {
      rank = score
      best = temp
    }
  }
  return best
}

function view(devices, statusDevices, modes, activeUid, pumpMin) {
  var byStatus = statusByUid(statusDevices)
  var channels = []
  var lcdChannels = []
  var cpuTemps = []
  var gpuTemps = []
  var coolant = null
  var pumpDuty = null
  var pumpRpm = null
  var pumpRank = -1
  var gpuPower = null
  var gpuLoad = null
  var gpuName = ""
  var cpuName = "CPU"
  var coolerName = ""
  var pumpDevice = ""
  var devs = devices || []
  for (var d = 0; d < devs.length; d++) {
    var dev = devs[d]
    if (!dev || !dev.info) continue
    var latest = byStatus[dev.uid] || {}
    var dutyBy = {}
    var rpmBy = {}
    var wattsBy = {}
    var reported = latest.channels || []
    for (var c = 0; c < reported.length; c++) {
      var item = reported[c]
      if (!item) continue
      dutyBy[item.name] = item.duty
      rpmBy[item.name] = item.rpm
      if (item.watts !== undefined && item.watts !== null) wattsBy[item.name] = Number(item.watts)
    }
    var temps = latest.temps || []
    for (var t = 0; t < temps.length; t++) {
      var sample = temps[t]
      var tempValue = sample ? finiteNum(sample.temp) : null
      if (tempValue === null) continue
      var tempName = String(sample.name || "")
      var tempLabel = String((dev.info.temps && dev.info.temps[tempName] && dev.info.temps[tempName].label) || tempName)
      if (/liquid|coolant|water/i.test(tempName) || /liquid|coolant/i.test(tempLabel)) {
        coolant = tempValue
        if (dev.name) coolerName = dev.name
      }
      if (dev.type === "CPU") cpuTemps.push({ name: tempName, label: tempLabel || tempName, temp: tempValue })
      if (dev.type === "GPU") gpuTemps.push({ name: tempName, label: tempLabel || tempName, temp: tempValue })
    }
    var infoChannels = dev.info.channels || {}
    for (var name in infoChannels) {
      if (!Object.prototype.hasOwnProperty.call(infoChannels, name)) continue
      var info = infoChannels[name] || {}
      var label = info.label || name
      var key = dev.uid + "/" + name
      if (info.lcd_modes && info.lcd_modes.length) {
        var lcdInfo = info.lcd_info || {}
        var screenW = Number(lcdInfo.screen_width)
        var screenH = Number(lcdInfo.screen_height)
        lcdChannels.push({
          key: key,
          deviceUid: dev.uid,
          deviceName: dev.name || "",
          name: name,
          label: label,
          screenWidth: isFinite(screenW) && screenW > 0 ? screenW : 0,
          screenHeight: isFinite(screenH) && screenH > 0 ? screenH : 0,
          hasImage: lcdHasImage(info.lcd_modes)
        })
      }
      if (dev.type === "CPU") cpuName = dev.name || cpuName
      if (dev.type === "GPU") {
        gpuName = dev.name || gpuName
        if (/power/i.test(name) && isFinite(wattsBy[name])) gpuPower = wattsBy[name]
        if (/load/i.test(name)) {
          var load = finiteNum(dutyBy[name])
          if (load !== null) gpuLoad = load
        }
      }
      if (!info.speed_options) continue
      var pump = isPumpName(name, label)
      if (pump) {
        var rank = (/pump/i.test(name) ? 2 : 1) + (String(dev.type || "").toLowerCase() === "liquidctl" ? 2 : 0)
        if (pumpRank < 0 || rank >= pumpRank) {
          if (rank > pumpRank) {
            pumpDuty = null
            pumpRpm = null
          }
          pumpRank = rank
          if (dev.name) pumpDevice = dev.name
          var nextDuty = finiteNum(dutyBy[name])
          var nextRpm = finiteNum(rpmBy[name])
          if (nextDuty !== null) pumpDuty = nextDuty
          if (nextRpm !== null) pumpRpm = nextRpm
        }
      }
      var deviceMin = Number(info.speed_options.min_duty)
      if (!isFinite(deviceMin)) deviceMin = 0
      channels.push({
        key: key,
        deviceUid: dev.uid,
        deviceName: dev.name || "",
        deviceType: dev.type || "",
        name: name,
        label: label,
        duty: finiteNum(dutyBy[name]),
        rpm: finiteNum(rpmBy[name]),
        isPump: pump,
        controllable: info.speed_options.fixed_enabled !== false,
        minDuty: pump ? Math.max(deviceMin, dutyFloor(pumpMin, 50)) : deviceMin
      })
    }
  }

  var active = modeByUid(modes, activeUid)
  var cpu = pickTemp(cpuTemps, /package|tctl|tdie/i)
  var cpuCcd1 = matchTemp(cpuTemps, /tccd1|ccd1/i)
  var cpuCcd2 = matchTemp(cpuTemps, /tccd2|ccd2/i)
  var gpu = gpuEdge(gpuTemps)
  // isFinite(null) is true, because null becomes 0. A missing sensor must not
  // win a comparison against a real reading, including one below 0°.
  var hottest = null
  if (cpu !== null) hottest = cpu
  if (gpu !== null && (hottest === null || gpu > hottest)) hottest = gpu
  if (coolant !== null && (hottest === null || coolant > hottest)) hottest = coolant
  if (!coolerName) coolerName = pumpDevice

  return {
    channels: channels,
    lcdChannels: lcdChannels,
    temps: {
      cpu: cpu,
      cpuCcd1: cpuCcd1,
      cpuCcd2: cpuCcd2,
      cpuName: cpuName,
      gpu: gpu,
      gpuPower: gpuPower,
      gpuLoad: gpuLoad,
      gpuName: gpuName,
      coolant: coolant,
      liquidName: coolerName,
      pumpDuty: pumpDuty,
      pumpRpm: pumpRpm,
      hottest: hottest
    },
    activeModeName: active ? active.name : ""
  }
}

// Membership of the channel list. Duty and RPM numbers are not part of it.
// "spin" is a tach above 0. "idle" is a stopped channel with a duty of 0.
// "held" is a duty above 0 that has not produced a tach. "none" is an unused header.
function channelPresence(channel) {
  var rpm = finiteNum(channel && channel.rpm)
  if (rpm !== null && rpm > 0) return "spin"
  var duty = channel ? channel.duty : null
  if (duty === null || duty === undefined || duty === "") return "none"
  var level = Number(duty)
  if (!isFinite(level)) return "none"
  if (level <= 0) return "idle"
  return "held"
}

function channelShape(channels) {
  var out = []
  var list = channels || []
  var i
  for (i = 0; i < list.length; i++) {
    var ch = list[i]
    if (!ch) continue
    out.push([
      ch.key || "",
      ch.deviceUid || "",
      ch.deviceName || "",
      ch.deviceType || "",
      ch.name || "",
      ch.label || "",
      ch.isPump ? 1 : 0,
      ch.controllable === false ? 0 : 1,
      Number(ch.minDuty) || 0,
      channelPresence(ch)
    ])
  }
  return out
}

function channelLive(channels) {
  var out = {}
  var list = channels || []
  var i
  for (i = 0; i < list.length; i++) {
    var ch = list[i]
    if (!ch || !ch.key) continue
    out[ch.key] = {
      duty: ch.duty === undefined ? null : ch.duty,
      rpm: ch.rpm === undefined ? null : ch.rpm
    }
  }
  return out
}

// Write the latest duty and RPM onto the channel objects already on screen.
function paintLive(target, fresh) {
  var list = target || []
  var src = fresh || []
  var i
  for (i = 0; i < list.length && i < src.length; i++) {
    if (!list[i] || !src[i] || list[i].key !== src[i].key) continue
    list[i].duty = src[i].duty
    list[i].rpm = src[i].rpm
  }
}

// One status tick. Duty and RPM for the channels already on screen, plus the
// temperatures the chip shows. A new channel, a missing channel, or a fan
// that starts or stops is a shape change and the caller rebuilds the lists.
function statusPatch(devices, statusDevices, channels) {
  var byStatus = statusByUid(statusDevices)
  var known = {}
  var list = channels || []
  var i
  for (i = 0; i < list.length; i++) {
    var ch = list[i]
    if (!ch || !ch.key) continue
    known[ch.key] = channelPresence(ch)
  }
  var seen = {}
  var live = {}
  var shapeChanged = false
  var cpuTemps = []
  var gpuTemps = []
  var coolant = null
  var pumpDuty = null
  var pumpRpm = null
  var pumpRank = -1
  var gpuPower = null
  var gpuLoad = null
  var gpuName = ""
  var cpuName = "CPU"
  var coolerName = ""
  var pumpDevice = ""
  var devs = devices || []
  var d
  for (d = 0; d < devs.length; d++) {
    var dev = devs[d]
    if (!dev || !dev.info) continue
    var latest = byStatus[dev.uid] || {}
    var dutyBy = {}
    var rpmBy = {}
    var wattsBy = {}
    var reported = latest.channels || []
    var c
    for (c = 0; c < reported.length; c++) {
      var item = reported[c]
      if (!item) continue
      dutyBy[item.name] = item.duty
      rpmBy[item.name] = item.rpm
      if (item.watts !== undefined && item.watts !== null) wattsBy[item.name] = Number(item.watts)
    }
    var samples = latest.temps || []
    var t
    for (t = 0; t < samples.length; t++) {
      var sample = samples[t]
      var tempValue = sample ? finiteNum(sample.temp) : null
      if (tempValue === null) continue
      var tempName = String(sample.name || "")
      var tempLabel = String((dev.info.temps && dev.info.temps[tempName] && dev.info.temps[tempName].label) || tempName)
      if (/liquid|coolant|water/i.test(tempName) || /liquid|coolant/i.test(tempLabel)) {
        coolant = tempValue
        if (dev.name) coolerName = dev.name
      }
      if (dev.type === "CPU") cpuTemps.push({ name: tempName, label: tempLabel || tempName, temp: tempValue })
      if (dev.type === "GPU") gpuTemps.push({ name: tempName, label: tempLabel || tempName, temp: tempValue })
    }
    var infoChannels = dev.info.channels || {}
    var name
    for (name in infoChannels) {
      if (!Object.prototype.hasOwnProperty.call(infoChannels, name)) continue
      var info = infoChannels[name] || {}
      var label = info.label || name
      var key = dev.uid + "/" + name
      if (dev.type === "CPU") cpuName = dev.name || cpuName
      if (dev.type === "GPU") {
        gpuName = dev.name || gpuName
        if (/power/i.test(name) && isFinite(wattsBy[name])) gpuPower = wattsBy[name]
        if (/load/i.test(name)) {
          var load = finiteNum(dutyBy[name])
          if (load !== null) gpuLoad = load
        }
      }
      if (!info.speed_options) continue
      var duty = finiteNum(dutyBy[name])
      var rpm = finiteNum(rpmBy[name])
      var pump = isPumpName(name, label)
      if (pump) {
        var rank = (/pump/i.test(name) ? 2 : 1) + (String(dev.type || "").toLowerCase() === "liquidctl" ? 2 : 0)
        if (pumpRank < 0 || rank >= pumpRank) {
          if (rank > pumpRank) {
            pumpDuty = null
            pumpRpm = null
          }
          pumpRank = rank
          if (dev.name) pumpDevice = dev.name
          if (duty !== null) pumpDuty = duty
          if (rpm !== null) pumpRpm = rpm
        }
      }
      var presence = channelPresence({ duty: duty, rpm: rpm })
      if (!Object.prototype.hasOwnProperty.call(known, key) || known[key] !== presence)
        shapeChanged = true
      seen[key] = true
      live[key] = { duty: duty, rpm: rpm }
    }
  }
  var prev
  for (prev in known) {
    if (!Object.prototype.hasOwnProperty.call(known, prev)) continue
    if (!seen[prev]) shapeChanged = true
  }
  var cpu = pickTemp(cpuTemps, /package|tctl|tdie/i)
  var cpuCcd1 = matchTemp(cpuTemps, /tccd1|ccd1/i)
  var cpuCcd2 = matchTemp(cpuTemps, /tccd2|ccd2/i)
  var gpu = gpuEdge(gpuTemps)
  var hottest = null
  if (cpu !== null) hottest = cpu
  if (gpu !== null && (hottest === null || gpu > hottest)) hottest = gpu
  if (coolant !== null && (hottest === null || coolant > hottest)) hottest = coolant
  if (!coolerName) coolerName = pumpDevice
  return {
    shapeChanged: shapeChanged,
    live: live,
    temps: {
      cpu: cpu,
      cpuCcd1: cpuCcd1,
      cpuCcd2: cpuCcd2,
      cpuName: cpuName,
      gpu: gpu,
      gpuPower: gpuPower,
      gpuLoad: gpuLoad,
      gpuName: gpuName,
      coolant: coolant,
      liquidName: coolerName,
      pumpDuty: pumpDuty,
      pumpRpm: pumpRpm,
      hottest: hottest
    }
  }
}

function liquidName(text) {
  return /liquid|coolant|water/i.test(String(text || ""))
}

// True when the AIO LCD channel can take a still image.
function lcdHasImage(modes) {
  var list = modes || []
  var i
  for (i = 0; i < list.length; i++) {
    var mode = list[i]
    if (!mode) continue
    if (typeof mode === "string") {
      if (mode === "image") return true
      continue
    }
    if (mode.image === true) return true
    var name = String(mode.name || mode.type || "")
    if (name === "image") return true
  }
  return false
}

// CPU package temp, or the GPU edge temp when the channel belongs to a GPU.
// Coolant is never a curve source. A missing GPU sensor falls back to CPU.
function tempSourceFor(devices, deviceType) {
  var list = devices || []
  var wantGpu = String(deviceType || "") === "GPU"
  var cpu = null
  var cpuStandIn = false
  var gpu = null
  var gpuRank = -1
  for (var i = 0; i < list.length; i++) {
    var dev = list[i]
    if (!dev || !dev.info || !dev.info.temps) continue
    var temps = dev.info.temps
    for (var name in temps) {
      if (!Object.prototype.hasOwnProperty.call(temps, name)) continue
      var info = temps[name] || {}
      var label = info.label ? String(info.label) : String(name)
      if (liquidName(name) || /liquid|coolant/i.test(label)) continue
      var source = { temp_name: name, device_uid: dev.uid }
      var namedLabel = /package|tctl|tdie/i.test(label)
      var namedName = /package|tctl|tdie/i.test(name)
      // ^temp1$ against "name label" never matched. A bare temp1 is only a stand-in.
      var generic = /^temp1$/i.test(name) || /^temp1$/i.test(label)
      if (dev.type === "CPU" && (namedLabel || namedName || generic)) {
        if (!cpu || namedLabel || (namedName && cpuStandIn)) {
          cpu = source
          cpuStandIn = !namedLabel && !namedName
        }
      }
      if (dev.type === "GPU") {
        var rank = gpuSensorRank(name, label)
        if (rank > gpuRank) {
          gpuRank = rank
          gpu = source
        }
      }
    }
  }
  if (wantGpu && gpu) return gpu
  return cpu || (wantGpu ? gpu : null)
}

function defaultTempSource(devices) {
  return tempSourceFor(devices, "CPU")
}

// The four named modes, and only when the daemon has none.
// A daemon that already has modes is left alone: creating one snapshots
// the live channels and can become the running mode.
function missingDefaultModes(modes) {
  var list = modes || []
  if (list.length > 0) return []
  return ["Silent", "Performance", "Fixed", "Hell"]
}

function defaultPoints(isPump) {
  if (isPump) return spreadPoints([[0, 50], [45, 65], [60, 80], [100, 100]], 50)
  return spreadPoints([[0, 25], [50, 45], [70, 70], [100, 100]], 0)
}

// Shipped shapes for a daemon that has no modes yet. These are not a
// machine's saved curves. Pumps stay at or above 50%.
function modeDefaultPoints(name, isPump) {
  var key = String(name || "").replace(/^\s+|\s+$/g, "").toLowerCase()
  if (isPump) {
    if (key === "silent") return spreadPoints([[0, 50], [60, 58], [80, 70], [100, 80]], 50)
    if (key === "performance") return spreadPoints([[0, 55], [45, 70], [70, 85], [100, 100]], 50)
    if (key === "fixed") return spreadPoints([[0, 60], [100, 60]], 50)
    if (key === "hell") return spreadPoints([[0, 70], [40, 85], [70, 100], [100, 100]], 50)
    return defaultPoints(true)
  }
  if (key === "silent") return spreadPoints([[0, 20], [50, 28], [70, 40], [100, 65]], 0)
  if (key === "performance") return spreadPoints([[0, 30], [40, 50], [60, 75], [100, 100]], 0)
  if (key === "fixed") return spreadPoints([[0, 50], [100, 50]], 0)
  if (key === "hell") return spreadPoints([[0, 45], [35, 70], [55, 100], [100, 100]], 0)
  return defaultPoints(false)
}

function speedChannels(devices, pumpMin) {
  var floor = dutyFloor(pumpMin, 50)
  var out = []
  var devs = devices || []
  var d
  for (d = 0; d < devs.length; d++) {
    var dev = devs[d]
    if (!dev || !dev.uid || !dev.info) continue
    var infoChannels = dev.info.channels || {}
    var name
    for (name in infoChannels) {
      if (!Object.prototype.hasOwnProperty.call(infoChannels, name)) continue
      var info = infoChannels[name] || {}
      if (!info.speed_options) continue
      var profilesOn = info.speed_options.profiles_enabled !== false
      var fixedOn = info.speed_options.fixed_enabled !== false
      if (!profilesOn && !fixedOn) continue
      var label = info.label || name
      var pump = isPumpName(name, label)
      var deviceMin = Number(info.speed_options.min_duty)
      if (!isFinite(deviceMin)) deviceMin = 0
      out.push({
        deviceUid: dev.uid,
        name: name,
        isPump: pump,
        minDuty: pump ? Math.max(deviceMin, floor) : deviceMin
      })
    }
  }
  return out
}

function modeSettingRows(mode) {
  var rows = mode && mode.device_settings
  if (!rows) return []
  if (rows.length !== undefined && typeof rows !== "string") return rows
  var out = []
  var key
  for (key in rows) {
    if (!Object.prototype.hasOwnProperty.call(rows, key)) continue
    out.push([key, rows[key]])
  }
  return out
}

// `visit` returns false to stop. A bare return walks the next setting.
function eachModeSetting(mode, visit) {
  var rows = modeSettingRows(mode)
  var r
  var s
  for (r = 0; r < rows.length; r++) {
    var settings = (rows[r] && rows[r][1]) || []
    var deviceUid = rows[r] && rows[r][0]
    for (s = 0; s < settings.length; s++) {
      if (visit(deviceUid, settings[s]) === false) return
    }
  }
}

function copyMap(src) {
  var next = ({})
  if (!src) return next
  var k
  for (k in src) next[k] = src[k]
  return next
}

function modeUsesProfile(mode, profileUid) {
  if (!mode || !profileUid) return false
  var found = false
  eachModeSetting(mode, function(deviceUid, setting) {
    if (setting && setting.profile_uid === profileUid) {
      found = true
      return false
    }
  })
  return found
}

function otherModeUsesProfile(modes, profileUid, modeUid) {
  if (!profileUid) return false
  var list = modes || []
  var m
  for (m = 0; m < list.length; m++) {
    var mode = list[m]
    if (!mode || mode.uid === modeUid) continue
    if (modeUsesProfile(mode, profileUid)) return true
  }
  return false
}

// The curve this mode already uses for one of a group's fans.
// Another mode may store the same speeds. It may not store this profile uid.
function modeGroupProfile(mode, modes, members) {
  var keys = {}
  var list = members || []
  var i
  for (i = 0; i < list.length; i++) if (list[i]) keys[String(list[i])] = true
  var found = ""
  eachModeSetting(mode, function(deviceUid, setting) {
    if (!setting || !setting.channel_name || !setting.profile_uid) return
    var key = String(deviceUid || "") + "/" + String(setting.channel_name)
    if (!keys[key]) return
    var uid = String(setting.profile_uid)
    if (!uid || uid === "0") return
    if (otherModeUsesProfile(modes, uid, mode && mode.uid)) return
    found = uid
    return false
  })
  return found
}

function modeProfileChannels(mode, profileUid) {
  var out = []
  if (!mode || !profileUid) return out
  eachModeSetting(mode, function(deviceUid, setting) {
    if (!setting || setting.profile_uid !== profileUid || !setting.channel_name) return
    out.push({ deviceUid: deviceUid, name: setting.channel_name })
  })
  return out
}

function sameGraph(sent, got) {
  var a = sent || []
  var b = got || []
  if (a.length !== b.length) return false
  var i
  for (i = 0; i < a.length; i++) {
    if (!a[i] || a[i].length < 2 || !b[i] || b[i].length < 2) return false
    if (Math.round(Number(a[i][0])) !== Math.round(Number(b[i][0]))) return false
    if (Math.round(Number(a[i][1])) !== Math.round(Number(b[i][1]))) return false
  }
  return true
}

// True when every sent curve is the profile the daemon stored, and each
// listed channel on this mode points at that profile.
function appliedCurvesMatch(mode, profiles, jobs) {
  var list = jobs || []
  var i
  for (i = 0; i < list.length; i++) {
    var job = list[i]
    if (!job || !job.profileUid) return false
    var profile = profileByUid(profiles, job.profileUid)
    if (!profile || !sameGraph(job.points, profile.speed_profile)) return false
    var chans = job.channels || []
    var c
    for (c = 0; c < chans.length; c++) {
      var wantDevice = String(chans[c] && chans[c].deviceUid || "")
      var wantName = String(chans[c] && chans[c].name || "")
      var bound = false
      eachModeSetting(mode, function(deviceUid, setting) {
        if (!setting || bound) return
        if (String(deviceUid || "") !== wantDevice) return
        if (String(setting.channel_name || "") !== wantName) return
        if (String(setting.profile_uid || "") === String(job.profileUid)) bound = true
      })
      if (!bound) return false
    }
  }
  return true
}

function matchChannel(channels, deviceName, channelName) {
  var wantDevice = String(deviceName || "").toLowerCase()
  var wantChannel = String(channelName || "").toLowerCase()
  if (!wantDevice || !wantChannel) return null
  var list = channels || []
  var i
  for (i = 0; i < list.length; i++) {
    var row = list[i]
    if (!row) continue
    if (String(row.deviceName || "").toLowerCase() !== wantDevice) continue
    var channel = String(row.name || "").toLowerCase()
    var label = String(row.label || "").toLowerCase()
    if (channel === wantChannel || label === wantChannel) return row
  }
  return null
}

// A curve pack is a file the user picks. A JSON object can carry a huge
// length without being an array, and a for-loop over that length freezes
// the shell. The 1 MB file cap does not stop that. Only real arrays under
// these caps are walked.
var PACK_MODE_CAP = 64
var PACK_CHANNEL_CAP = 128
var PACK_POINT_CAP = 64
var PACK_GROUP_CAP = 64
var PACK_MEMBER_CAP = 128

function boundedArray(value, cap) {
  if (!Array.isArray(value) || value.length > cap) return null
  return value
}

// Qt Text defaults to AutoText and treats a tag anywhere before the first
// newline as rich text. That fetch is not limited by the 1 MB pack cap.
function plainLabel(value, fallback) {
  var text = String(value == null ? "" : value).replace(/[\u0000-\u001f\u007f]/g, "")
  text = text.replace(/^\s+|\s+$/g, "")
  if (!text || text.length > 120 || /[<>]/.test(text)) return fallback
  return text
}

function cleanGroupList(groups) {
  var list = Array.isArray(groups) ? groups : []
  var out = []
  var i
  for (i = 0; i < list.length; i++) {
    var group = list[i]
    if (!group || typeof group !== "object" || Array.isArray(group)) continue
    var copy = copyMap(group)
    copy.name = plainLabel(group.name, "Group")
    out.push(copy)
  }
  return out
}

function packPoints(pack, modeName, deviceName, channelName) {
  if (!pack || pack.kind !== "omaflow-curves") return null
  var want = String(modeName || "").toLowerCase()
  var modes = boundedArray(pack.modes, PACK_MODE_CAP)
  if (!modes) return null
  var i
  var c
  for (i = 0; i < modes.length; i++) {
    var mode = modes[i]
    if (!mode || String(mode.name || "").toLowerCase() !== want) continue
    var rows = boundedArray(mode.channels, PACK_CHANNEL_CAP)
    if (!rows) continue
    for (c = 0; c < rows.length; c++) {
      var row = rows[c]
      if (!row) continue
      if (String(row.deviceName || "").toLowerCase() !== String(deviceName || "").toLowerCase()) continue
      var channel = String(channelName || "").toLowerCase()
      if (String(row.channel || "").toLowerCase() !== channel && String(row.label || "").toLowerCase() !== channel) continue
      var points = boundedArray(row.points, PACK_POINT_CAP)
      return points && points.length > 1 ? points : null
    }
  }
  return null
}

function copyPointList(points) {
  var copy = []
  var src = points || []
  var i
  for (i = 0; i < src.length; i++) {
    if (!src[i] || src[i].length < 2) continue
    var temp = Number(src[i][0])
    var duty = Number(src[i][1])
    if (!isFinite(temp) || !isFinite(duty)) continue
    copy.push([temp, duty])
  }
  return copy
}

function samePointList(a, b) {
  var left = a || []
  var right = b || []
  if (left.length !== right.length) return false
  var i
  for (i = 0; i < left.length; i++) {
    if (!left[i] || !right[i]) return false
    if (Number(left[i][0]) !== Number(right[i][0])) return false
    if (Number(left[i][1]) !== Number(right[i][1])) return false
  }
  return true
}

// One drag step from the points captured at press. Later points rise to the
// dragged duty. Earlier points fall to it. A colder point does not stay above
// a hotter one. Callers pass the press-time points, not the previous step.
function monotonicPoints(src, index, duty) {
  var next = []
  var list = src || []
  var i
  for (i = 0; i < list.length; i++) next.push([Number(list[i][0]), Number(list[i][1])])
  if (index < 0 || index >= next.length) return next
  var level = Number(duty)
  if (!isFinite(level)) return next
  next[index] = [next[index][0], level]
  var j
  for (j = index + 1; j < next.length; j++) {
    if (next[j][1] < level) next[j] = [next[j][0], level]
  }
  for (j = index - 1; j >= 0; j--) {
    if (next[j][1] > level) next[j] = [next[j][0], level]
  }
  return next
}

// One curve's undo stack. `entry` is { steps, index } or empty.
// A new edit drops the redo tail and keeps the curve that was on screen,
// so the first undo can return to it. No visible change returns null.
function pushCurveHistory(entry, before, after, limit) {
  var nextPoints = copyPointList(after)
  if (nextPoints.length < 2) return null
  var steps = []
  var i
  if (entry && entry.steps && entry.steps.length) {
    var keep = (Number(entry.index) || 0) + 1
    if (keep < 1) keep = 1
    if (keep > entry.steps.length) keep = entry.steps.length
    for (i = 0; i < keep; i++) steps.push(entry.steps[i])
  }
  if (!steps.length) {
    var base = copyPointList(before)
    if (base.length > 1) steps.push(base)
  }
  if (!steps.length || samePointList(steps[steps.length - 1], nextPoints)) return null
  steps.push(nextPoints)
  var index = steps.length - 1
  var cap = Number(limit) || 40
  if (cap < 2) cap = 2
  if (steps.length > cap) {
    var drop = steps.length - cap
    steps = steps.slice(drop)
    index = index - drop
    if (index < 0) index = 0
  }
  return { steps: steps, index: index }
}

function buildCurvePack(modes, channels, profiles, groups) {
  var byKey = {}
  var list = channels || []
  var i
  for (i = 0; i < list.length; i++) if (list[i] && list[i].key) byKey[list[i].key] = list[i]
  var modeOut = []
  var modeList = modes || []
  for (i = 0; i < modeList.length; i++) {
    var mode = modeList[i]
    if (!mode || !mode.name) continue
    var members = modeMembers(mode, channels, profiles)
    var rows = []
    var m
    for (m = 0; m < members.length; m++) {
      var member = members[m]
      if (!member.points || member.points.length < 2) continue
      rows.push({
        deviceName: member.deviceName || "",
        channel: member.name || "",
        label: member.label || "",
        points: member.points,
        minDuty: Number(member.minDuty) || 0,
        profileName: member.profileName || ""
      })
    }
    modeOut.push({ name: mode.name, channels: rows })
  }
  var groupOut = []
  var saved = groups || []
  for (i = 0; i < saved.length; i++) {
    var group = saved[i]
    if (!group) continue
    var membersOut = []
    var keys = group.members || []
    var k
    for (k = 0; k < keys.length; k++) {
      var channel = byKey[keys[k]]
      if (!channel) continue
      membersOut.push({
        deviceName: channel.deviceName || "",
        channel: channel.name || "",
        label: channel.label || ""
      })
    }
    if (membersOut.length < 2) continue
    groupOut.push({ name: group.name || "Group", members: membersOut })
  }
  return { kind: "omaflow-curves", version: 1, modes: modeOut, groups: groupOut }
}

function validCurvePack(pack) {
  if (!pack || pack.kind !== "omaflow-curves" || pack.version !== 1) return false
  var modes = boundedArray(pack.modes, PACK_MODE_CAP)
  if (!modes) return false
  var i
  var c
  for (i = 0; i < modes.length; i++) {
    var mode = modes[i]
    if (!mode || typeof mode !== "object" || Array.isArray(mode)) return false
    if (mode.channels === undefined || mode.channels === null) continue
    var channels = boundedArray(mode.channels, PACK_CHANNEL_CAP)
    if (!channels) return false
    for (c = 0; c < channels.length; c++) {
      var row = channels[c]
      if (!row || typeof row !== "object" || Array.isArray(row)) return false
      if (row.points === undefined || row.points === null) continue
      if (!boundedArray(row.points, PACK_POINT_CAP)) return false
    }
  }
  if (pack.groups === undefined || pack.groups === null) return true
  var groups = boundedArray(pack.groups, PACK_GROUP_CAP)
  if (!groups) return false
  for (i = 0; i < groups.length; i++) {
    var group = groups[i]
    if (!group || typeof group !== "object" || Array.isArray(group)) return false
    if (group.members === undefined || group.members === null) continue
    if (!boundedArray(group.members, PACK_MEMBER_CAP)) return false
  }
  return true
}

function remapGroups(pack, channels, newId) {
  var out = []
  if (!pack) return out
  var saved = boundedArray(pack.groups, PACK_GROUP_CAP)
  if (!saved) return out
  var i
  var k
  for (i = 0; i < saved.length; i++) {
    var group = saved[i]
    if (!group || typeof group !== "object" || Array.isArray(group)) continue
    var members = []
    var rows = boundedArray(group.members, PACK_MEMBER_CAP)
    if (!rows) continue
    for (k = 0; k < rows.length; k++) {
      var row = rows[k]
      var channel = matchChannel(channels, row && row.deviceName, row && (row.channel || row.label))
      if (!channel || !channel.key) continue
      if (members.indexOf(channel.key) < 0) members.push(channel.key)
    }
    if (members.length < 2) continue
    out.push({
      id: newId ? newId() : ("group-" + i),
      name: plainLabel(group.name, "Group"),
      profileUid: "",
      members: members
    })
  }
  return out
}

function modeMembers(mode, channels, profiles) {
  var byKey = {}
  var list = channels || []
  for (var i = 0; i < list.length; i++) byKey[list[i].key] = list[i]
  var out = []
  eachModeSetting(mode, function(deviceUid, setting) {
    if (!assigned(setting) || !setting.channel_name) return
    var key = deviceUid + "/" + setting.channel_name
    var channel = byKey[key]
    if (!channel) return
    var profile = setting.profile_uid ? profileByUid(profiles, setting.profile_uid) : null
    out.push({
      key: key,
      deviceUid: deviceUid,
      name: setting.channel_name,
      label: channel.label,
      deviceName: channel.deviceName,
      rpm: channel.rpm,
      isPump: channel.isPump,
      deviceType: channel.deviceType || "",
      minDuty: channel.minDuty,
      profileUid: profile ? profile.uid : "",
      profileName: profile ? profile.name : "",
      pType: profile ? profile.p_type : (setting.speed_fixed !== undefined && setting.speed_fixed !== null ? "Fixed" : ""),
      points: graphPoints(profile, channel && channel.isPump ? channel.minDuty : 0),
      fixed: setting.speed_fixed !== undefined && setting.speed_fixed !== null && isFinite(Number(setting.speed_fixed)) ? Number(setting.speed_fixed) : null
    })
  })
  return out
}

function spinningChannels(channels, memberKeys) {
  var taken = {}
  var keys = memberKeys || []
  for (var i = 0; i < keys.length; i++) taken[keys[i]] = true
  var out = []
  var list = channels || []
  for (var c = 0; c < list.length; c++) {
    var channel = list[c]
    if (!channel || taken[channel.key]) continue
    if (!(Number(channel.rpm) > 0)) continue
    out.push(channel)
  }
  return out
}

function controlledKeys(modes) {
  var out = {}
  var list = modes || []
  for (var m = 0; m < list.length; m++) {
    eachModeSetting(list[m], function(deviceUid, setting) {
      if (!assigned(setting) || !setting.channel_name) return
      out[deviceUid + "/" + setting.channel_name] = true
    })
  }
  return out
}

// rpm > 0 stays visible. A stopped channel stays visible only when a mode
// assigns it, which is how a manual 0% is told apart from an unused header.
function deviceGroups(channels, modes) {
  var kept = controlledKeys(modes)
  var order = []
  var by = {}
  var list = channels || []
  for (var i = 0; i < list.length; i++) {
    var channel = list[i]
    if (!channel) continue
    var uid = channel.deviceUid
    if (!by[uid]) {
      by[uid] = {
        uid: uid,
        name: channel.deviceName || "Device",
        type: channel.deviceType || "",
        shown: [],
        hidden: []
      }
      order.push(uid)
    }
    var spinning = Number(channel.rpm) > 0
    if (spinning || kept[channel.key]) by[uid].shown.push(channel)
    else by[uid].hidden.push(channel)
  }
  var groups = []
  for (var g = 0; g < order.length; g++) {
    var group = by[order[g]]
    group.shown.sort(function(a, b) {
      var ar = Number(a.rpm) > 0 ? 0 : 1
      var br = Number(b.rpm) > 0 ? 0 : 1
      if (ar !== br) return ar - br
      return String(a.label || "").localeCompare(String(b.label || ""))
    })
    groups.push(group)
  }
  return groups
}

function modeNamed(modes, name) {
  var want = String(name || "").toLowerCase()
  var list = modes || []
  var i
  for (i = 0; i < list.length; i++) {
    if (list[i] && String(list[i].name || "").toLowerCase() === want) return list[i]
  }
  return null
}

// CPU package, GPU edge, and coolant. Hotspot is not the GPU alert.
function alertSensors(devices) {
  var cpu = null
  var gpu = null
  var gpuRank = -1
  var coolant = null
  var list = devices || []
  var i
  for (i = 0; i < list.length; i++) {
    var dev = list[i]
    if (!dev || !dev.uid || !dev.info || !dev.info.temps) continue
    var temps = dev.info.temps
    var name
    for (name in temps) {
      if (!Object.prototype.hasOwnProperty.call(temps, name)) continue
      var info = temps[name] || {}
      var label = info.label ? String(info.label) : String(name)
      var source = { device_uid: dev.uid, channel_name: name, channel_metric: "Temp" }
      if (liquidName(name) || /liquid|coolant/i.test(label)) {
        coolant = source
        continue
      }
      if (dev.type === "CPU" && /package|tctl|tdie/i.test(name + " " + label)) {
        if (!cpu || /tctl|package|tdie/i.test(label)) cpu = source
      }
      if (dev.type === "GPU") {
        var rank = gpuSensorRank(name, label)
        if (rank > gpuRank) {
          gpuRank = rank
          gpu = source
        }
      }
    }
  }
  return { cpu: cpu, gpu: gpu, coolant: coolant }
}

function alertNamed(alerts, name) {
  var want = String(name || "")
  var list = alerts || []
  var i
  for (i = 0; i < list.length; i++) {
    if (list[i] && String(list[i].name || "") === want) return list[i]
  }
  return null
}

function alertStateLabel(alert) {
  if (!alert) return ""
  if (alert.enabled === false) return "Off"
  var state = alert.state
  if (state && typeof state === "object") return "Warming"
  var text = String(state || "")
  if (text === "Active") return "Active"
  if (text === "Error") return "Error"
  if (text === "Inactive") return "Watching"
  if (/warm/i.test(text)) return "Warming"
  return text
}

function activeAlertNames(alerts) {
  var out = []
  var list = alerts || []
  var i
  for (i = 0; i < list.length; i++) {
    var alert = list[i]
    if (!alert || alert.enabled === false) continue
    if (String(alert.state || "") !== "Active") continue
    var name = String(alert.name || "").replace(/^\s+|\s+$/g, "")
    if (name) out.push(name)
  }
  return out
}

function activeAlertLine(alerts) {
  var names = activeAlertNames(alerts)
  if (!names.length) return ""
  if (names.length === 1) return names[0]
  return names[0] + " +" + (names.length - 1)
}

// Missing, null, and "" are not a duration. Number(null) is 0, so those stay out of Number.
function alertSeconds(value) {
  if (value === null || value === undefined || value === "" || typeof value === "boolean") return NaN
  var n = Number(value)
  return isFinite(n) ? n : NaN
}

function alertChannel(src) {
  src = src || {}
  return {
    device_uid: String(src.device_uid || ""),
    channel_name: String(src.channel_name || ""),
    channel_metric: String(src.channel_metric || "Temp")
  }
}

// The body this daemon accepts. A missing warmup is 12. A real 0 is kept.
// Cooldown, repeat, silence, and extra sources are copied or the next save drops them.
// shutdown_on_activation is never forwarded as true.
function alertWriteBody(alert, enabled) {
  var src = alert && alert.channel_source
  if (!src && alert && alert.channel_sources && alert.channel_sources.length) src = alert.channel_sources[0]
  var max = Number(alert && alert.max)
  var min = Number(alert && alert.min)
  var warm = alertSeconds(alert && alert.warmup_duration)
  var body = {
    uid: String(alert && alert.uid || ""),
    name: String(alert && alert.name || ""),
    channel_source: alertChannel(src),
    min: isFinite(min) ? min : 0,
    max: isFinite(max) ? max : 0,
    warmup_duration: isFinite(warm) && warm >= 0 ? warm : 12,
    desktop_notify: !alert || alert.desktop_notify !== false,
    desktop_notify_audio: !!(alert && alert.desktop_notify_audio === true),
    desktop_notify_recovery: !alert || alert.desktop_notify_recovery !== false,
    shutdown_on_activation: false,
    enabled: enabled !== false
  }
  if (!alert) return body
  var cool = alertSeconds(alert.cooldown_duration)
  if (isFinite(cool) && cool >= 0) body.cooldown_duration = cool
  var repeat = alertSeconds(alert.repeat_interval)
  if (isFinite(repeat) && repeat >= 0) body.repeat_interval = repeat
  var silenced = alert.silenced_until
  if (typeof silenced === "string" && silenced !== "") body.silenced_until = silenced
  var sources = alert.channel_sources
  if (sources && sources.length && typeof sources !== "string") {
    var copied = []
    var i
    for (i = 0; i < sources.length; i++) {
      if (!sources[i] || typeof sources[i] !== "object") continue
      copied.push(alertChannel(sources[i]))
    }
    if (copied.length) body.channel_sources = copied
  }
  return body
}

// Eight seconds ignores a short spike. The delay applies on the way down too,
// because this daemon has no upward-only delay. Steps stay small after that.
function silentRampFunction(uid) {
  return {
    uid: String(uid || ""),
    name: "Omaflow silent ramp",
    f_type: "Standard",
    duty_minimum: 2,
    duty_maximum: 6,
    step_size_min_decreasing: 2,
    step_size_max_decreasing: 12,
    threshold_hopping: false,
    bypass_min_at_extremes: true,
    response_delay: 8,
    deviance: 1,
    only_downward: false
  }
}

function rampCloneName(name) {
  var suffix = " omaflow"
  var base = String(name || "curve").replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
  if (!base) base = "curve"
  if (base.length + suffix.length <= 48) return base + suffix
  return base.slice(0, 48 - suffix.length) + suffix
}

// Fan graphs on Silent. Pumps, fixed duties, and the default profile stay put.
// A profile another mode uses is cloned onto Silent. An exclusive profile is
// edited in place. A channel missing from the live device list is skipped.
// A hidden duplicate can still sit in an old mode, and the daemon rejects a
// write to that device.
function planSilentRamp(mode, modes, profiles, channels, rampUid) {
  var inplace = []
  var clones = []
  var already = []
  var cloneAt = {}
  var seenInplace = {}
  var byKey = {}
  var list = channels || []
  var i
  for (i = 0; i < list.length; i++) if (list[i] && list[i].key) byKey[list[i].key] = list[i]
  var ramp = String(rampUid || "")
  eachModeSetting(mode, function(deviceUid, setting) {
    if (!setting || !setting.channel_name || !setting.profile_uid) return
    var channelName = String(setting.channel_name)
    var channel = byKey[String(deviceUid || "") + "/" + channelName]
    if (!channel) return
    var pump = channel.isPump === true
    if (pump) return
    var profile = profileByUid(profiles, setting.profile_uid)
    if (!profile || String(profile.p_type || "") !== "Graph") return
    if (String(profile.uid || "") === "0") return
    var pname = String(profile.name || "")
    if (/^(fixed|default|unmanaged)$/i.test(pname)) return
    var shared = otherModeUsesProfile(modes, profile.uid, mode && mode.uid)
    var fn = String(profile.function_uid || "0")
    var ours = ramp !== "" && fn === ramp
    var cloneNamed = / omaflow$/i.test(pname)
    if (ours && !shared) {
      already.push({
        deviceUid: String(deviceUid || ""),
        channel: channelName,
        profileUid: cloneNamed ? "" : String(profile.uid || ""),
        cloneUid: cloneNamed ? String(profile.uid || "") : "",
        prevFunction: "0"
      })
      return
    }
    if (!shared) {
      if (seenInplace[profile.uid]) return
      seenInplace[profile.uid] = true
      inplace.push({ profileUid: String(profile.uid), prevFunction: fn || "0" })
      return
    }
    if (cloneAt[profile.uid] === undefined) {
      cloneAt[profile.uid] = clones.length
      clones.push({
        profileUid: String(profile.uid),
        prevFunction: ours ? "0" : (fn || "0"),
        restore: ours,
        channels: []
      })
    }
    clones[cloneAt[profile.uid]].channels.push({
      deviceUid: String(deviceUid || ""),
      name: channelName
    })
  })
  return { inplace: inplace, clones: clones, already: already }
}

// Pump profiles whose saved duty is below 50. Turning the floor back on
// raises those points. Turning it off does not call this.
function pumpProfilesToLift(modes, profiles, channels) {
  var byKey = {}
  var list = channels || []
  var i
  for (i = 0; i < list.length; i++) if (list[i] && list[i].key) byKey[list[i].key] = list[i]
  var ids = {}
  var modeList = modes || []
  var m
  for (m = 0; m < modeList.length; m++) {
    eachModeSetting(modeList[m], function(deviceUid, setting) {
      if (!setting || !setting.channel_name || !setting.profile_uid) return
      var channelName = String(setting.channel_name)
      var channel = byKey[String(deviceUid || "") + "/" + channelName]
      var pump = channel ? channel.isPump === true : isPumpName(channelName, channelName)
      if (!pump) return
      ids[String(setting.profile_uid)] = true
    })
  }
  var out = []
  var uid
  for (uid in ids) {
    if (!Object.prototype.hasOwnProperty.call(ids, uid)) continue
    var profile = profileByUid(profiles, uid)
    if (!profile || String(profile.p_type || "") !== "Graph") continue
    var points = profile.speed_profile || []
    var low = false
    var p
    for (p = 0; p < points.length; p++) {
      if (!points[p] || points[p].length < 2) continue
      var duty = Number(points[p][1])
      if (isFinite(duty) && duty < 50) low = true
    }
    if (low) out.push(profile)
  }
  return out
}
