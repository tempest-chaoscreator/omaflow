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

function channelSetting(mode, deviceUid, channelName) {
  if (!mode) return null
  var rows = mode.device_settings || []
  for (var r = 0; r < rows.length; r++) {
    var row = rows[r]
    if (!row || row[0] !== deviceUid) continue
    var settings = row[1] || []
    for (var s = 0; s < settings.length; s++) {
      if (settings[s] && settings[s].channel_name === channelName) return settings[s]
    }
  }
  return null
}

function rawGraphPoints(profile) {
  if (!profile || profile.p_type !== "Graph" || !profile.speed_profile) return []
  var src = profile.speed_profile
  var out = []
  for (var i = 0; i < src.length; i++) {
    var pair = src[i]
    if (!pair || pair.length < 2) continue
    out.push([Number(pair[0]), Number(pair[1])])
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

function graphPoints(profile) {
  var floor = profile && /pump/i.test(String(profile.name || "")) ? 50 : 0
  return spreadPoints(rawGraphPoints(profile), floor)
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

function pickTemp(candidates, pattern) {
  for (var i = 0; i < candidates.length; i++) {
    if (pattern.test(candidates[i].name)) return candidates[i].temp
  }
  var best = null
  for (var j = 0; j < candidates.length; j++) {
    if (best === null || candidates[j].temp > best) best = candidates[j].temp
  }
  return best
}

function view(devices, statusDevices, modes, profiles, activeUid, selectedKey, pumpMin) {
  var byStatus = statusByUid(statusDevices)
  var channels = []
  var lcdChannels = []
  var cpuTemps = []
  var gpuTemps = []
  var coolant = null
  var pumpDuty = null
  var pumpRpm = null
  var pumpRank = -1
  var cpuPower = null
  var cpuLoad = null
  var gpuPower = null
  var gpuLoad = null
  var gpuFan = null
  var gpuName = ""
  var cpuName = "CPU"
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
      if (!sample || !isFinite(Number(sample.temp))) continue
      var tempName = String(sample.name || "")
      var tempLabel = String((dev.info.temps && dev.info.temps[tempName] && dev.info.temps[tempName].label) || tempName)
      var tempValue = Number(sample.temp)
      if (/liquid|coolant|water/i.test(tempName) || /liquid|coolant/i.test(tempLabel)) coolant = tempValue
      if (dev.type === "CPU") cpuTemps.push({ name: tempLabel || tempName, temp: tempValue })
      if (dev.type === "GPU") gpuTemps.push({ name: tempLabel || tempName, temp: tempValue })
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
          screenHeight: isFinite(screenH) && screenH > 0 ? screenH : 0
        })
      }
      if (dev.type === "CPU") {
        cpuName = dev.name || cpuName
        if (/power/i.test(name) && isFinite(wattsBy[name])) cpuPower = wattsBy[name]
        if (/load/i.test(name) && isFinite(Number(dutyBy[name]))) cpuLoad = Number(dutyBy[name])
      }
      if (dev.type === "GPU") {
        gpuName = dev.name || gpuName
        if (/power/i.test(name) && isFinite(wattsBy[name])) gpuPower = wattsBy[name]
        if (/load/i.test(name) && isFinite(Number(dutyBy[name]))) gpuLoad = Number(dutyBy[name])
        if (/fan/i.test(name) && isFinite(Number(dutyBy[name]))) gpuFan = Number(dutyBy[name])
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
          if (isFinite(Number(dutyBy[name]))) pumpDuty = Number(dutyBy[name])
          if (isFinite(Number(rpmBy[name]))) pumpRpm = Number(rpmBy[name])
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
        duty: dutyBy[name] === undefined ? null : Number(dutyBy[name]),
        rpm: rpmBy[name] === undefined ? null : Number(rpmBy[name]),
        isPump: pump,
        controllable: info.speed_options.fixed_enabled !== false,
        minDuty: pump ? Math.max(deviceMin, Number(pumpMin) || 50) : deviceMin
      })
    }
  }

  var active = modeByUid(modes, activeUid)
  var selected = null
  for (var i = 0; i < channels.length; i++) {
    if (channels[i].key === selectedKey) selected = channels[i]
  }
  if (!selected && channels.length) selected = channels[0]

  var curve = emptyCurve()
  if (selected) {
    var setting = channelSetting(active, selected.deviceUid, selected.name)
    var profile = setting && setting.profile_uid ? profileByUid(profiles, setting.profile_uid) : null
    curve = {
      key: selected.key,
      label: selected.label,
      deviceName: selected.deviceName,
      duty: selected.duty,
      rpm: selected.rpm,
      isPump: selected.isPump,
      minDuty: selected.minDuty,
      profileUid: profile ? profile.uid : "",
      profileName: profile ? profile.name : (setting && setting.speed_fixed !== undefined ? "Fixed " + setting.speed_fixed + "%" : ""),
      pType: profile ? profile.p_type : (setting && setting.speed_fixed !== undefined ? "Fixed" : ""),
      points: graphPoints(profile),
      fixed: setting && setting.speed_fixed !== undefined ? Number(setting.speed_fixed) : null
    }
  }

  var cpu = pickTemp(cpuTemps, /package|tctl|tdie/i)
  var cpuCcd1 = pickTemp(cpuTemps, /tccd1|ccd1/i)
  var cpuCcd2 = pickTemp(cpuTemps, /tccd2|ccd2/i)
  var gpu = pickTemp(gpuTemps, /gpu temp$/i)
  if (!isFinite(gpu)) gpu = pickTemp(gpuTemps, /edge|gpu|temp/i)
  var gpuHotspot = pickTemp(gpuTemps, /hotspot/i)
  var hottest = null
  if (isFinite(cpu)) hottest = cpu
  if (isFinite(gpu) && (hottest === null || gpu > hottest)) hottest = gpu

  return {
    channels: channels,
    lcdChannels: lcdChannels,
    temps: {
      cpu: cpu,
      cpuCcd1: cpuCcd1,
      cpuCcd2: cpuCcd2,
      cpuPower: cpuPower,
      cpuLoad: cpuLoad,
      cpuName: cpuName,
      gpu: gpu,
      gpuHotspot: gpuHotspot,
      gpuPower: gpuPower,
      gpuLoad: gpuLoad,
      gpuFan: gpuFan,
      gpuName: gpuName,
      coolant: coolant,
      pumpDuty: pumpDuty,
      pumpRpm: pumpRpm,
      hottest: hottest
    },
    activeModeName: active ? active.name : "",
    curve: curve
  }
}

function profileMinDuty(profile, channels, modes, pumpMin) {
  if (!profile) return 0
  var floor = Number(pumpMin) || 50
  if (/pump/i.test(profile.name || "")) return floor
  var list = modes || []
  for (var m = 0; m < list.length; m++) {
    var rows = (list[m] && list[m].device_settings) || []
    for (var r = 0; r < rows.length; r++) {
      var deviceUid = rows[r] && rows[r][0]
      var settings = (rows[r] && rows[r][1]) || []
      for (var s = 0; s < settings.length; s++) {
        if (!settings[s] || settings[s].profile_uid !== profile.uid) continue
        for (var c = 0; c < (channels || []).length; c++) {
          var channel = channels[c]
          if (channel.isPump && channel.deviceUid === deviceUid && channel.name === settings[s].channel_name)
            return floor
        }
      }
    }
  }
  return 0
}

function liquidName(text) {
  return /liquid|coolant|water/i.test(String(text || ""))
}

// CPU package temp, or the GPU edge temp when the channel belongs to a GPU.
// Coolant is never a curve source. A missing GPU sensor falls back to CPU.
function tempSourceFor(devices, deviceType) {
  var list = devices || []
  var wantGpu = String(deviceType || "") === "GPU"
  var cpu = null
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
      if (liquidName(name) || liquidName(label)) continue
      var source = { temp_name: name, device_uid: dev.uid }
      if (dev.type === "CPU" && /package|tctl|tdie|^temp1$/i.test(name + " " + label)) {
        if (!cpu || /tctl|package|tdie/i.test(label)) cpu = source
      }
      if (dev.type === "GPU") {
        var rank = 1
        if (/hotspot/i.test(name) || /hotspot/i.test(label)) rank = 0
        if (/^gpu temp$/i.test(String(name)) || /^gpu temp$/i.test(label)) rank = 2
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

function speedChannels(devices) {
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
        minDuty: pump ? Math.max(deviceMin, 50) : deviceMin
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

function modeUsesProfile(mode, profileUid) {
  if (!mode || !profileUid) return false
  var rows = modeSettingRows(mode)
  var r
  var s
  for (r = 0; r < rows.length; r++) {
    var settings = (rows[r] && rows[r][1]) || []
    for (s = 0; s < settings.length; s++) {
      if (settings[s] && settings[s].profile_uid === profileUid) return true
    }
  }
  return false
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

function profileModeCount(modes, profileUid) {
  if (!profileUid) return 0
  var list = modes || []
  var count = 0
  var m
  for (m = 0; m < list.length; m++) {
    if (modeUsesProfile(list[m], profileUid)) count++
  }
  return count
}

function modeProfileChannels(mode, profileUid) {
  var out = []
  if (!mode || !profileUid) return out
  var rows = modeSettingRows(mode)
  var r
  var s
  for (r = 0; r < rows.length; r++) {
    var deviceUid = rows[r] && rows[r][0]
    var settings = (rows[r] && rows[r][1]) || []
    for (s = 0; s < settings.length; s++) {
      var setting = settings[s]
      if (!setting || setting.profile_uid !== profileUid || !setting.channel_name) continue
      out.push({ deviceUid: deviceUid, name: setting.channel_name })
    }
  }
  return out
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

function packPoints(pack, modeName, deviceName, channelName) {
  if (!pack || pack.kind !== "omaflow-curves") return null
  var want = String(modeName || "").toLowerCase()
  var modes = pack.modes || []
  var i
  var c
  for (i = 0; i < modes.length; i++) {
    var mode = modes[i]
    if (!mode || String(mode.name || "").toLowerCase() !== want) continue
    var rows = mode.channels || []
    for (c = 0; c < rows.length; c++) {
      var row = rows[c]
      if (!row) continue
      if (String(row.deviceName || "").toLowerCase() !== String(deviceName || "").toLowerCase()) continue
      var channel = String(channelName || "").toLowerCase()
      if (String(row.channel || "").toLowerCase() !== channel && String(row.label || "").toLowerCase() !== channel) continue
      return row.points && row.points.length > 1 ? row.points : null
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
  return !!(pack && pack.kind === "omaflow-curves" && Number(pack.version) === 1 && pack.modes && pack.modes.length >= 0)
}

function remapGroups(pack, channels, newId) {
  var out = []
  if (!pack) return out
  var saved = pack.groups || []
  var i
  var k
  for (i = 0; i < saved.length; i++) {
    var group = saved[i]
    if (!group) continue
    var members = []
    var rows = group.members || []
    for (k = 0; k < rows.length; k++) {
      var row = rows[k]
      var channel = matchChannel(channels, row && row.deviceName, row && (row.channel || row.label))
      if (!channel || !channel.key) continue
      if (members.indexOf(channel.key) < 0) members.push(channel.key)
    }
    if (members.length < 2) continue
    out.push({
      id: newId ? newId() : ("group-" + i),
      name: group.name || "Group",
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
  var rows = (mode && mode.device_settings) || []
  for (var r = 0; r < rows.length; r++) {
    var deviceUid = rows[r] && rows[r][0]
    var settings = (rows[r] && rows[r][1]) || []
    for (var s = 0; s < settings.length; s++) {
      var setting = settings[s]
      if (!assigned(setting) || !setting.channel_name) continue
      var key = deviceUid + "/" + setting.channel_name
      var channel = byKey[key]
      if (!channel) continue
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
        pType: profile ? profile.p_type : (setting.speed_fixed !== undefined ? "Fixed" : ""),
        points: graphPoints(profile),
        fixed: setting.speed_fixed !== undefined ? Number(setting.speed_fixed) : null
      })
    }
  }
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
    var rows = (list[m] && list[m].device_settings) || []
    for (var r = 0; r < rows.length; r++) {
      var deviceUid = rows[r] && rows[r][0]
      var settings = (rows[r] && rows[r][1]) || []
      for (var s = 0; s < settings.length; s++) {
        var setting = settings[s]
        if (!assigned(setting) || !setting.channel_name) continue
        out[deviceUid + "/" + setting.channel_name] = true
      }
    }
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

function groupColor(type, name, index) {
  var text = String(type || "") + " " + String(name || "")
  if (/gpu|nvidia/i.test(text)) return "#e08a4f"
  if (/kraken|liquid/i.test(text)) return "#8b7cff"
  if (/smart|nzxtsmart/i.test(text)) return "#5dbe7a"
  if (/nct|asus|cpu/i.test(text)) return "#6aa8ff"
  var palette = ["#e08a4f", "#8b7cff", "#6aa8ff", "#5dbe7a", "#d06b8a", "#c9a227"]
  return palette[Math.abs(Number(index) || 0) % palette.length]
}

function emptyCurve() {
  return {
    key: "",
    label: "",
    deviceName: "",
    duty: null,
    rpm: null,
    isPump: false,
    minDuty: 0,
    profileUid: "",
    profileName: "",
    pType: "",
    points: [],
    fixed: null
  }
}
