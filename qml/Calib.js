// CoolerControl calibration text and batch shape. Plain functions so a
// node harness can load this file. No hardware access and no mode writes.

function emptyBatch() {
  return { active: false, started_at: "", entries: [] }
}

function normalizeBatch(body) {
  if (!body || typeof body !== "object") return emptyBatch()
  var entries = []
  var raw = body.entries || []
  var i
  for (i = 0; i < raw.length; i++) {
    var row = raw[i]
    if (!row) continue
    entries.push({
      device_uid: row.device_uid || "",
      channel_name: row.channel_name || "",
      phase: row.phase || "",
      percent: row.percent === undefined ? null : row.percent,
      stage: row.stage === undefined ? null : row.stage,
      message: row.message === undefined || row.message === null ? null : String(row.message)
    })
  }
  return {
    active: body.active === true,
    started_at: body.started_at || "",
    entries: entries
  }
}

function findEntry(batch, deviceUid, channelName) {
  var entries = batch && batch.entries ? batch.entries : []
  var i
  for (i = 0; i < entries.length; i++) {
    var row = entries[i]
    if (!row) continue
    if (String(row.device_uid) === String(deviceUid) && String(row.channel_name) === String(channelName))
      return row
  }
  return null
}

function findCalibration(list, deviceUid, channelName) {
  var rows = list || []
  var i
  for (i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row) continue
    if (String(row.device_uid) === String(deviceUid) && String(row.channel_name) === String(channelName))
      return row.calibration || null
  }
  return null
}

function statusOf(map, deviceUid, channelName) {
  if (!map) return null
  var hit = map[String(deviceUid) + "\n" + String(channelName)]
  return hit || null
}

function stageLabel(stage, phase) {
  if (String(phase || "") === "queued") return "Waiting"
  var name = String(stage || "")
  if (name === "preflight") return "Checking"
  if (name === "up_sweep") return "Sweeping up"
  if (name === "down_sweep") return "Sweeping down"
  if (name === "finalizing") return "Saving"
  if (String(phase || "") === "running") return "Calibrating"
  return ""
}

function finiteNum(value) {
  if (value === null || value === undefined || value === "") return null
  var n = Number(value)
  return isFinite(n) ? n : null
}

function progressLine(entry, status) {
  if (!entry) return ""
  var phase = String(entry.phase || "")
  if (phase !== "queued" && phase !== "running") return ""
  var stage = status && status.stage ? status.stage : entry.stage
  var label = stageLabel(stage, phase)
  if (!label) return ""
  var parts = [label]
  var percent = status && status.percent !== undefined && status.percent !== null ? status.percent : entry.percent
  var percentN = finiteNum(percent)
  if (percentN !== null) parts.push(Math.round(percentN) + "%")
  var duty = status ? finiteNum(status.current_duty) : null
  if (duty !== null) parts.push(Math.round(duty) + "%")
  var rpm = status ? finiteNum(status.current_rpm) : null
  if (rpm !== null) parts.push(Math.round(rpm) + " rpm")
  return parts.join("  ")
}

function failureLine(entry) {
  if (!entry) return ""
  var phase = String(entry.phase || "")
  if (phase !== "failed" && phase !== "cancelled") return ""
  if (entry.message) return String(entry.message)
  if (phase === "cancelled") return "Calibration was cancelled."
  return "Calibration failed."
}

function curveKind(cal) {
  if (!cal) return ""
  var raw = String(cal.curve_kind || cal.curveKind || "").toLowerCase()
  if (raw === "smooth") return "Smooth"
  if (raw === "stepped") return "Stepped"
  return ""
}

function summaryLine(cal) {
  if (!cal) return ""
  var bits = []
  var kind = curveKind(cal)
  if (kind) bits.push(kind)
  var rpm = finiteNum(cal.rpm_max)
  if (rpm !== null) bits.push(Math.round(rpm) + " rpm")
  var start = finiteNum(cal.min_start_duty)
  if (start !== null) bits.push("Starts at " + Math.round(start) + "%")
  var full = finiteNum(cal.max_eff_duty)
  if (full !== null) bits.push("Full speed by " + Math.round(full) + "%")
  return bits.join(". ")
}

function warningFields(warning) {
  if (!warning || typeof warning !== "object") return { kind: "", fields: {} }
  if (warning.kind) return { kind: String(warning.kind).toLowerCase(), fields: warning }
  var keys = []
  var key
  for (key in warning) {
    if (Object.prototype.hasOwnProperty.call(warning, key)) keys.push(key)
  }
  if (keys.length !== 1) return { kind: "", fields: warning }
  var inner = warning[keys[0]]
  var fields = inner && typeof inner === "object" ? inner : warning
  return { kind: String(keys[0]).toLowerCase(), fields: fields }
}

function warningLines(cal) {
  var list = cal && cal.warnings ? cal.warnings : []
  var out = []
  var i
  for (i = 0; i < list.length; i++) {
    var parsed = warningFields(list[i])
    var fields = parsed.fields || {}
    var line = ""
    if (parsed.kind === "no_tachometer") line = "No RPM reading."
    else if (parsed.kind === "not_controllable")
      line = "This fan ignores duty. That is often the BIOS holding the speed."
    else if (parsed.kind === "limited_range") {
      var span = finiteNum(fields.rpm_span)
      var max = finiteNum(fields.rpm_max)
      if (span !== null && max !== null)
        line = "Narrow range, " + Math.round(span) + " rpm of " + Math.round(max) + "."
      else line = "Narrow range."
    } else if (parsed.kind === "oscillating") {
      var lo = finiteNum(fields.lower_duty)
      var hi = finiteNum(fields.upper_duty)
      if (lo !== null && hi !== null)
        line = "Hunts between " + Math.round(lo) + "% and " + Math.round(hi) + "%."
      else line = "Hunts between two duties."
    } else if (parsed.kind === "implausible_curve") line = "The curve is not believable."
    if (line) out.push(line)
  }
  return out
}

function nextLine(cal) {
  var kind = curveKind(cal)
  if (kind === "Stepped")
    return "This fan only has plateaus, so duty is left as raw duty. The map is off."
  if (kind === "Smooth" && warningLines(cal).length === 0)
    return "Duty is now this fan's real speed. 0% is stopped and 100% is as fast as it usefully goes. Saved modes keep their numbers, and those numbers now mean that."
  return ""
}

function upSamples(cal) {
  var src = cal && cal.up_curve ? cal.up_curve : []
  var out = []
  var i
  for (i = 0; i < src.length; i++) {
    var row = src[i]
    if (!row) continue
    var duty = finiteNum(row.duty)
    var rpm = finiteNum(row.rpm)
    if (duty === null || rpm === null) continue
    out.push({ duty: duty, rpm: rpm })
  }
  out.sort(function(a, b) { return a.duty - b.duty })
  return out
}
