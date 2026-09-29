import QtQuick
import Quickshell.Io
import "CcMap.js" as Cc

// Headless CoolerControl client. One per shell. Omaflow Plugin and
// Omaflow both read this object. Fan writes and sensor polls
// stay on coolercontrold's own poll_rate. This service never changes it
// and never writes PWM itself.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var settings: ({})

  readonly property string clientPath: Qt.resolvedUrl("scripts/cc_client.py").toString().replace(/^file:\/\//, "")
  readonly property int pumpMin: 50

  property string connection: "down"
  property string notice: ""
  property string lastError: ""
  property var modes: []
  property var profiles: []
  property var devices: []
  property var statusDevices: []
  property string activeModeUid: ""
  property string activeModeName: ""
  property var channels: []
  property var lcdChannels: []
  property var temps: ({ cpu: null, gpu: null, coolant: null, hottest: null })
  property string selectedKey: ""
  property var curve: Cc.emptyCurve()
  property var daemonSettings: ({})
  property var functions: []
  property var alerts: []
  property var groups: []
  property var links: ({})
  property var hiddenDevices: ({})
  property bool modesKnown: false
  property bool defaultsPlanted: false

  property bool stopping: false
  property int restartDelayMs: 2000
  property int rpcId: 1
  property var pending: ({})

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function send(obj) {
    if (!client.running) return false
    client.write(JSON.stringify(obj) + "\n")
    return true
  }

  function call(method, path, body, done) {
    var id = rpcId
    rpcId = rpcId + 1
    var next = ({})
    for (var k in pending) next[k] = pending[k]
    if (done) next[id] = done
    pending = next
    send({ op: "call", id: id, method: method, path: path, body: body === undefined ? null : body })
  }

  function dropPending(id) {
    var next = ({})
    for (var k in pending) if (String(k) !== String(id)) next[k] = pending[k]
    pending = next
  }

  function fail(res) {
    var status = res ? Number(res.status) || 0 : 0
    var error = res && res.error ? String(res.error) : ""
    if (error === "need-token") {
      connection = "need-token"
      lastError = "Pair coolercontrold with ~/.config/omaflow/coolercontrol.token"
      return
    }
    if (status === 401 || status === 403) {
      connection = "unauthorized"
      lastError = "CoolerControl rejected the access token"
      return
    }
    if (status === 0) {
      connection = "down"
      lastError = error || "coolercontrold is not running"
      return
    }
    lastError = error || ("HTTP " + status)
    notice = lastError
  }

  function rebuild() {
    var shaped = Cc.view(devices, statusDevices, modes, profiles, activeModeUid, selectedKey, pumpMin)
    channels = shaped.channels
    lcdChannels = shaped.lcdChannels
    temps = shaped.temps
    activeModeName = shaped.activeModeName
    curve = shaped.curve
    if (!selectedKey && shaped.channels.length) selectedKey = shaped.channels[0].key
  }

  function refresh() {
    call("GET", "/devices", null, function(res) {
      if (!res.ok) return fail(res)
      devices = (res.body && res.body.devices) || []
      if (connection !== "need-token" && connection !== "unauthorized") connection = "ready"
      rebuild()
      ensureDefaultModes()
    })
    call("GET", "/profiles", null, function(res) {
      if (!res.ok) return fail(res)
      profiles = (res.body && res.body.profiles) || []
      rebuild()
    })
    call("GET", "/modes", null, function(res) {
      if (!res.ok) return fail(res)
      modes = (res.body && res.body.modes) || []
      modesKnown = true
      rebuild()
      ensureDefaultModes()
    })
    call("GET", "/modes-active", null, function(res) {
      if (!res.ok) return fail(res)
      activeModeUid = res.body && res.body.current_mode_uid ? String(res.body.current_mode_uid) : ""
      rebuild()
    })
    call("GET", "/settings", null, function(res) {
      if (!res.ok) return fail(res)
      daemonSettings = res.body || ({})
    })
    call("GET", "/functions", null, function(res) {
      if (!res.ok) return fail(res)
      functions = (res.body && res.body.functions) || []
    })
    call("GET", "/alerts", null, function(res) {
      if (!res.ok) return fail(res)
      alerts = (res.body && res.body.alerts) || []
    })
    loadGroups()
    loadLinks()
    loadHidden()
    call("GET", "/status", null, function(res) {
      if (!res.ok) return fail(res)
      statusDevices = (res.body && res.body.devices) || []
      if (connection !== "need-token" && connection !== "unauthorized") connection = "ready"
      notice = ""
      rebuild()
    })
  }

  function pair(password) {
    var id = rpcId
    rpcId = rpcId + 1
    var next = ({})
    for (var k in pending) next[k] = pending[k]
    next[id] = function(res) {
      if (!res.ok) fail(res)
    }
    pending = next
    send({ op: "pair", id: id, password: String(password || "") })
  }

  function selectChannel(key) {
    selectedKey = String(key || "")
    rebuild()
  }

  function activateMode(uid) {
    if (!uid) return
    call("POST", "/modes-active/" + encodeURIComponent(uid), {}, function(res) {
      if (!res.ok) return fail(res)
      activeModeUid = String(uid)
      notice = ""
      rebuild()
      refresh()
    })
  }

  function createMode(name) {
    var trimmed = String(name || "").replace(/^\s+|\s+$/g, "")
    if (!trimmed) return
    call("POST", "/modes", { name: trimmed }, function(res) {
      if (!res.ok) return fail(res)
      refresh()
    })
  }

  function deleteMode(uid, done) {
    if (!uid) return
    if (uid === activeModeUid) {
      lastError = "The running mode stays"
      return
    }
    lastError = ""
    call("DELETE", "/modes/" + encodeURIComponent(uid), null, function(res) {
      if (!res.ok) return fail(res)
      refresh()
      if (done) done()
    })
  }

  function renameMode(uid, name) {
    var trimmed = String(name || "").replace(/^\s+|\s+$/g, "")
    if (!uid || !trimmed) return
    call("PUT", "/modes", { uid: uid, name: trimmed }, function(res) {
      if (!res.ok) return fail(res)
      refresh()
    })
  }

  function captureMode(uid) {
    if (!uid) return
    call("PUT", "/modes/" + encodeURIComponent(uid) + "/settings", {}, function(res) {
      if (!res.ok) return fail(res)
      refresh()
    })
  }

  function assignProfile(deviceUid, channel, profileUid) {
    if (!deviceUid || !channel || !profileUid) return
    var path = "/devices/" + encodeURIComponent(deviceUid) + "/settings/" + encodeURIComponent(channel) + "/profile"
    call("PUT", path, { profile_uid: profileUid }, function(res) {
      if (!res.ok) return fail(res)
      refresh()
    })
  }

  function newUid() {
    var hex = ""
    for (var i = 0; i < 32; i++) hex += Math.floor(Math.random() * 16).toString(16)
    return hex.slice(0, 8) + "-" + hex.slice(8, 12) + "-" + hex.slice(12, 16) + "-" + hex.slice(16, 20) + "-" + hex.slice(20)
  }

  function loadGroups() {
    var id = rpcId
    rpcId = rpcId + 1
    var next = ({})
    for (var k in pending) next[k] = pending[k]
    next[id] = function(res) {
      groups = (res.body && res.body.groups) || []
    }
    pending = next
    send({ op: "groups-get", id: id })
  }

  function saveGroups(nextGroups) {
    groups = nextGroups || []
    var id = rpcId
    rpcId = rpcId + 1
    pending = pending
    send({ op: "groups-set", id: id, body: { groups: groups } })
  }

  function loadLinks() {
    var id = rpcId
    rpcId = rpcId + 1
    var next = ({})
    for (var k in pending) next[k] = pending[k]
    next[id] = function(res) {
      links = (res.body && res.body.links) || ({})
    }
    pending = next
    send({ op: "links-get", id: id })
  }

  function saveLinks(nextLinks) {
    links = nextLinks || ({})
    var id = rpcId
    rpcId = rpcId + 1
    send({ op: "links-set", id: id, body: { links: links } })
  }

  function loadHidden() {
    var id = rpcId
    rpcId = rpcId + 1
    var next = ({})
    for (var k in pending) next[k] = pending[k]
    next[id] = function(res) {
      hiddenDevices = (res.body && res.body.devices) || ({})
    }
    pending = next
    send({ op: "hidden-get", id: id })
  }

  function saveHidden(nextHidden) {
    hiddenDevices = nextHidden || ({})
    var id = rpcId
    rpcId = rpcId + 1
    send({ op: "hidden-set", id: id, body: { devices: hiddenDevices } })
  }

  function setDeviceHidden(uid, hidden) {
    if (!uid) return
    var next = ({})
    var cur = hiddenDevices || ({})
    for (var k in cur) if (cur[k] === true) next[k] = true
    if (hidden) next[uid] = true
    else delete next[uid]
    saveHidden(next)
  }

  function deviceHidden(uid) {
    return !!(hiddenDevices && hiddenDevices[uid] === true)
  }

  // Names only, and only when the daemon has no modes at all.
  // Does not activate a mode and does not write a fan curve.
  function ensureDefaultModes() {
    if (defaultsPlanted || !modesKnown) return
    if (!devices || devices.length === 0) return
    var names = Cc.missingDefaultModes(modes)
    defaultsPlanted = true
    if (!names.length) return
    createDefaultModes(names, 0)
  }

  function createDefaultModes(names, index) {
    if (index >= names.length) {
      refresh()
      return
    }
    call("POST", "/modes", { name: names[index] }, function(res) {
      if (!res.ok) return fail(res)
      createDefaultModes(names, index + 1)
    })
  }

  // Local only. Does not assign a profile or create a group.
  function setCardLink(uid, linked) {
    if (!uid) return
    var next = ({})
    var cur = links || ({})
    for (var k in cur) {
      if (cur[k] === true || cur[k] === false) next[k] = cur[k] === true
    }
    next[uid] = linked === true
    saveLinks(next)
  }

  function rememberGroup(group) {
    var next = []
    for (var i = 0; i < groups.length; i++) if (groups[i].id !== group.id) next.push(groups[i])
    next.push(group)
    saveGroups(next)
  }

  // Drops the local grouping only. Fan profiles and duties stay as they are.
  function forgetGroup(id) {
    if (!id) return
    var next = []
    for (var i = 0; i < groups.length; i++) if (groups[i].id !== id) next.push(groups[i])
    saveGroups(next)
  }

  function renameGroup(id, name) {
    var trimmed = String(name || "").replace(/^\s+|\s+$/g, "")
    if (!id || !trimmed) return
    var next = []
    for (var i = 0; i < groups.length; i++) {
      var group = groups[i]
      if (group.id !== id) {
        next.push(group)
        continue
      }
      var copy = ({})
      for (var k in group) copy[k] = group[k]
      copy.name = trimmed
      next.push(copy)
    }
    saveGroups(next)
  }

  function forgetMember(key) {
    var next = []
    for (var i = 0; i < groups.length; i++) {
      var members = []
      var group = groups[i]
      var list = group.members || []
      for (var m = 0; m < list.length; m++) if (list[m] !== key) members.push(list[m])
      if (members.length > 1) {
        var copy = ({})
        for (var k in group) copy[k] = group[k]
        copy.members = members
        next.push(copy)
      }
    }
    saveGroups(next)
  }

  function createGraph(name, points, tempSource, minDuty, done) {
    if (!tempSource) {
      lastError = "No temperature source is available for a new curve"
      return
    }
    var uid = newUid()
    var draft = { uid: uid, name: name, function_uid: "0", p_type: "Graph", speed_profile: points }
    var shaped = Cc.withGraphPoints(draft, points, minDuty)
    shaped.temp_source = tempSource
    shaped.temp_min = 0
    shaped.temp_max = 100
    call("POST", "/profiles", shaped, function(res) {
      if (!res.ok) return fail(res)
      if (done) done(uid)
    })
  }

  function bindChannel(modeUid, deviceUid, channel, profileUid, done) {
    var path = "/devices/" + encodeURIComponent(deviceUid) + "/settings/" + encodeURIComponent(channel) + "/profile"
    call("PUT", path, { profile_uid: profileUid }, function(res) {
      if (!res.ok) return fail(res)
      call("PUT", "/modes/" + encodeURIComponent(modeUid) + "/settings", {}, function(saved) {
        if (!saved.ok) return fail(saved)
        notice = ""
        refresh()
        if (done) done()
      })
    })
  }

  function bindMany(modeUid, members, profileUid, done) {
    var index = 0
    function step() {
      if (index >= members.length) {
        call("PUT", "/modes/" + encodeURIComponent(modeUid) + "/settings", {}, function(saved) {
          if (!saved.ok) return fail(saved)
          refresh()
          if (done) done()
        })
        return
      }
      var member = members[index++]
      var path = "/devices/" + encodeURIComponent(member.deviceUid) + "/settings/" + encodeURIComponent(member.name) + "/profile"
      call("PUT", path, { profile_uid: profileUid }, function(res) {
        if (!res.ok) return fail(res)
        step()
      })
    }
    step()
  }

  function resetChannel(modeUid, deviceUid, channel, memberKey) {
    var path = "/devices/" + encodeURIComponent(deviceUid) + "/settings/" + encodeURIComponent(channel) + "/reset"
    call("PUT", path, {}, function(res) {
      if (!res.ok) return fail(res)
      forgetMember(memberKey)
      call("PUT", "/modes/" + encodeURIComponent(modeUid) + "/settings", {}, function(saved) {
        if (!saved.ok) return fail(saved)
        refresh()
      })
    })
  }

  // Drop a mode assignment without removing the fan from a shared group.
  function releaseChannel(modeUid, deviceUid, channel) {
    var path = "/devices/" + encodeURIComponent(deviceUid) + "/settings/" + encodeURIComponent(channel) + "/reset"
    call("PUT", path, {}, function(res) {
      if (!res.ok) return fail(res)
      call("PUT", "/modes/" + encodeURIComponent(modeUid) + "/settings", {}, function(saved) {
        if (!saved.ok) return fail(saved)
        refresh()
      })
    })
  }

  function saveDaemon(next) {
    call("PUT", "/settings", next, function(res) {
      if (!res.ok) return fail(res)
      daemonSettings = next
      notice = ""
    })
  }

  function saveFunction(fn) {
    call("PUT", "/functions", fn, function(res) {
      if (!res.ok) return fail(res)
      refresh()
    })
  }

  function saveAlert(alert) {
    call("PUT", "/alerts/" + encodeURIComponent(alert.uid), alert, function(res) {
      if (!res.ok) return fail(res)
      refresh()
    })
  }

  function saveGraphs(jobs, done) {
    var index = 0
    var list = jobs || []
    function step() {
      if (index >= list.length) {
        if (done) done()
        return
      }
      var job = list[index++]
      var profile = Cc.profileByUid(profiles, job.profileUid)
      if (!profile) {
        lastError = "That curve is not a saved profile"
        return
      }
      var next = Cc.withGraphPoints(profile, job.points, job.minDuty)
      call("PUT", "/profiles", next, function(res) {
        if (!res.ok) return fail(res)
        step()
      })
    }
    step()
  }

  // Writes the curves this mode is showing, then runs the mode.
  // An empty mode is refused: activating one makes the daemon reset every channel.
  function applyModeCurves(uid, jobs, done) {
    if (!uid) return
    saveGraphs(jobs || [], function() {
      call("POST", "/modes-active/" + encodeURIComponent(uid), {}, function(res) {
        if (!res.ok) return fail(res)
        activeModeUid = String(uid)
        notice = ""
        refresh()
        if (done) done()
      })
    })
  }

  function startCalibration(deviceUid, channel) {
    var path = "/calibrations/" + encodeURIComponent(deviceUid) + "/channels/" + encodeURIComponent(channel) + "/start"
    call("POST", path, {}, function(res) {
      if (!res.ok) return fail(res)
      notice = "Calibration started for " + channel
    })
  }

  function setLighting(deviceUid, channel, modeName) {
    var path = "/devices/" + encodeURIComponent(deviceUid) + "/settings/" + encodeURIComponent(channel) + "/lighting"
    call("PUT", path, { mode: modeName, speed: null, backward: false, colors: [] }, function(res) {
      if (!res.ok) return fail(res)
      notice = ""
    })
  }

  function saveGraph(profileUid, points, minDuty) {
    var profile = Cc.profileByUid(profiles, profileUid)
    if (!profile) {
      lastError = "That curve is not a saved profile"
      return
    }
    var next = Cc.withGraphPoints(profile, points, minDuty)
    call("PUT", "/profiles", next, function(res) {
      if (!res.ok) return fail(res)
      notice = "Curve saved."
      refresh()
    })
  }

  function startCalibrations(list) {
    var index = 0
    var jobs = list || []
    function step() {
      if (index >= jobs.length) {
        notice = jobs.length ? "Calibration started" : ""
        return
      }
      var item = jobs[index++]
      if (!item || !item.deviceUid || !item.name) {
        step()
        return
      }
      var path = "/calibrations/" + encodeURIComponent(item.deviceUid) + "/channels/" + encodeURIComponent(item.name) + "/start"
      call("POST", path, {}, function(res) {
        if (!res.ok) return fail(res)
        step()
      })
    }
    step()
  }

  function pushLcdImage(deviceUid, channel, brightness, face, angle, accent, accent2, tempText, temp2, shape, width, height, done) {
    if (!deviceUid || !channel) return
    var id = rpcId
    rpcId = rpcId + 1
    var next = ({})
    for (var k in pending) next[k] = pending[k]
    next[id] = function(res) {
      if (!res.ok) fail(res)
      else notice = ""
      if (done) done(res)
    }
    pending = next
    if (!send({
      op: "lcd-image",
      id: id,
      device: deviceUid,
      channel: channel,
      brightness: Math.max(0, Math.min(100, Math.round(Number(brightness) || 0))),
      face: String(face || "liquid"),
      angle: ((Math.round(Number(angle) || 0) % 360) + 360) % 360,
      accent: String(accent || ""),
      accent2: String(accent2 || ""),
      temp: String(tempText || "—"),
      temp2: String(temp2 || ""),
      shape: String(shape || "round") === "square" ? "square" : "round",
      width: Math.max(0, Math.round(Number(width) || 0)),
      height: Math.max(0, Math.round(Number(height) || 0))
    })) {
      dropPending(id)
      if (done) done({ ok: false, status: 0, error: "not connected" })
    }
  }

  function setLcd(deviceUid, channel, lcd) {
    if (!deviceUid || !channel || !lcd) return
    var path = "/devices/" + encodeURIComponent(deviceUid) + "/settings/" + encodeURIComponent(channel) + "/lcd"
    call("PUT", path, lcd, function(res) {
      if (!res.ok) return fail(res)
      notice = ""
    })
  }

  function handleLine(line) {
    var trimmed = String(line || "").replace(/^\s+|\s+$/g, "")
    if (!trimmed) return
    var msg
    try { msg = JSON.parse(trimmed) } catch (e) {
      console.warn("omaflow: unreadable client line")
      return
    }
    if (msg.event === "hello") {
      restartDelayMs = 2000
      connection = msg.token ? "down" : "need-token"
      if (msg.token) refresh()
      else lastError = "Pair coolercontrold with ~/.config/omaflow/coolercontrol.token"
      return
    }
    if (msg.event === "up") {
      if (connection !== "unauthorized" && connection !== "need-token") connection = "ready"
      return
    }
    if (msg.event === "down") {
      if (msg.error === "need-token" || msg.status === 401 || msg.status === 403) fail(msg)
      else {
        connection = "down"
        lastError = msg.error || "coolercontrold is not running"
      }
      return
    }
    if (msg.event === "status") {
      statusDevices = (msg.body && msg.body.devices) || statusDevices
      if (connection !== "need-token" && connection !== "unauthorized") connection = "ready"
      rebuild()
      return
    }
    if (msg.event === "mode" || msg.event === "modes") {
      var body = msg.body || {}
      if (body.uid) activeModeUid = String(body.uid)
      else if (body.current_mode_uid) activeModeUid = String(body.current_mode_uid)
      rebuild()
      return
    }
    if (msg.id === undefined || msg.id === null) return
    var done = pending[msg.id]
    dropPending(msg.id)
    if (done) done(msg)
  }

  Process {
    id: client
    command: ["python3", "-u", root.clientPath]
    running: !root.stopping
    stdout: SplitParser {
      onRead: function(line) { root.handleLine(line) }
    }
    stderr: SplitParser {
      onRead: function(line) { console.warn("omaflow cc: " + line) }
    }
    onExited: function() {
      if (root.stopping) return
      root.connection = "down"
      restart.interval = root.restartDelayMs
      root.restartDelayMs = Math.min(30000, root.restartDelayMs * 2)
      restart.start()
    }
  }

  Timer {
    id: restart
    repeat: false
    onTriggered: if (!root.stopping) client.running = true
  }

  Component.onDestruction: {
    stopping = true
    restart.stop()
    send({ op: "quit" })
  }
}
