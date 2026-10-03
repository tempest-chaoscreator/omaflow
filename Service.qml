import QtQuick
import Quickshell
import Quickshell.Io
import "CcMap.js" as Cc
import "Calib.js" as Calib

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
  // True only for a refused or dropped connection. A later successful read
  // clears it. Action errors stay on screen.
  property bool transportError: false
  property string daemonPkg: "unknown"
  property string daemonActive: "unknown"
  property bool daemonBusy: false
  property string daemonNote: ""
  property int pkgCode: -1
  property string unitBuf: ""
  property bool lcdBackground: true
  property int lcdSeconds: 5
  property bool lcdThemeSync: false
  property string lcdFace: "liquid"
  property int lcdClockWait: 60000
  property bool lcdKeepBusy: false

  onConnectionChanged: if (connection === "ready") lcdKick.restart()
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
  property var calibrations: []
  property var calibrationBatch: ({ active: false, started_at: "", entries: [] })
  property var calibrationStatus: ({})
  property bool calibrationAwait: false
  property int calibrationMiss: 0
  readonly property bool calibrationBusy: !!(calibrationBatch && calibrationBatch.active === true)
  property bool dynamicScale: false
  property bool textFollow: true
  property int textSize: 12
  property bool showBar: true
  property bool uiReady: false
  property bool showBarHeld: false
  property var curvePack: ({})
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
      transportError = false
      lastError = "Pair coolercontrold with ~/.config/omaflow/coolercontrol.token"
      return
    }
    if (status === 401 || status === 403) {
      connection = "unauthorized"
      transportError = false
      lastError = "CoolerControl rejected the access token"
      return
    }
    if (status === 0) {
      connection = "down"
      transportError = true
      lastError = error || "coolercontrold is not running"
      return
    }
    transportError = false
    lastError = error || ("HTTP " + status)
    notice = lastError
  }

  // A successful read means the refused connection is over. Leave a real
  // action error, such as a rejected curve, where the page can still show it.
  function noteReady() {
    if (connection === "need-token" || connection === "unauthorized") return
    connection = "ready"
    if (transportError) {
      transportError = false
      lastError = ""
      notice = ""
    }
  }

  readonly property string daemonGate: {
    if (daemonPkg === "missing") return "install"
    if (daemonActive === "active") return "up"
    if (daemonActive === "activating" || daemonActive === "reloading") return "starting"
    if (daemonPkg === "installed") return "start"
    return "unknown"
  }

  function probeDaemon() {
    if (pkgProbe.running || unitProbe.running || daemonBusy) return
    unitBuf = ""
    pkgCode = -1
    pkgProbe.running = true
    unitProbe.running = true
  }

  function finishProbe() {
    if (pkgProbe.running || unitProbe.running || pkgCode < 0) return
    var load = ""
    var active = ""
    var lines = unitBuf.split("\n")
    var i
    for (i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/^\s+|\s+$/g, "")
      if (line.indexOf("LoadState=") === 0) load = line.substring(10)
      else if (line.indexOf("ActiveState=") === 0) active = line.substring(12)
    }
    if (load === "loaded" || pkgCode === 0) daemonPkg = "installed"
    else daemonPkg = "missing"
    if (load === "not-found" && pkgCode !== 0) daemonPkg = "missing"
    if (active === "active") daemonActive = "active"
    else if (active === "activating" || active === "reloading") daemonActive = active
    else if (active === "failed") daemonActive = "failed"
    else if (daemonPkg === "installed") daemonActive = "inactive"
    else daemonActive = "unknown"
  }

  function installDaemon() {
    if (daemonGate !== "install" || daemonBusy || daemonInstall.running) return
    daemonBusy = true
    daemonNote = ""
    daemonInstall.running = true
  }

  function startDaemon() {
    if (daemonGate !== "start" || daemonBusy || daemonStart.running) return
    daemonBusy = true
    daemonNote = ""
    daemonStart.running = true
  }

  function finishDaemonAction(code, fallback) {
    daemonBusy = false
    if (code !== 0 && !daemonNote)
      daemonNote = fallback
    probeDaemon()
  }

  function keepLcd() {
    if (stopping || !lcdBackground || connection !== "ready" || lcdKeepBusy) return
    if (!lcdChannels || !lcdChannels.length) return
    var screen = lcdChannels[0]
    if (!screen || !screen.deviceUid || !screen.name) return
    var id = rpcId
    rpcId = rpcId + 1
    var next = ({})
    for (var k in pending) next[k] = pending[k]
    next[id] = function(res) {
      root.lcdKeepBusy = false
      if (res && res.ok === false) console.warn("omaflow lcd: " + (res.error || "image rejected"))
    }
    pending = next
    lcdKeepBusy = true
    var sample = temps || ({})
    if (!send({
      op: "lcd-keep",
      id: id,
      device: screen.deviceUid,
      channel: screen.name,
      deviceName: screen.deviceName || "",
      width: Math.round(Number(screen.screenWidth) || 0),
      height: Math.round(Number(screen.screenHeight) || 0),
      cpu: sample.cpu === undefined ? null : sample.cpu,
      gpu: sample.gpu === undefined ? null : sample.gpu,
      coolant: sample.coolant === undefined ? null : sample.coolant,
      interval: lcdFace === "omarchy-time" ? 60 : lcdSeconds
    })) {
      dropPending(id)
      lcdKeepBusy = false
    }
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
      noteReady()
      rebuild()
      ensureDefaultModes()
      lcdKick.restart()
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
    loadCalibrations()
    loadCalibrationBatch()
    call("GET", "/status", null, function(res) {
      if (!res.ok) return fail(res)
      statusDevices = (res.body && res.body.devices) || []
      noteReady()
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

  // Only when the daemon has no modes at all. A daemon that already has
  // Silent, Performance, Fixed, or Hell is left alone, including its curves.
  function ensureDefaultModes() {
    if (defaultsPlanted || !modesKnown) return
    if (!devices || devices.length === 0) return
    var names = Cc.missingDefaultModes(modes)
    defaultsPlanted = true
    if (!names.length) return
    createDefaultModes(names)
  }

  // Hell, Fixed, and Performance are snapshotted first. Silent is last and
  // is the mode left running, so a new install does not stay on Hell.
  function createDefaultModes(names) {
    var want = ({})
    var i
    for (i = 0; i < names.length; i++) want[String(names[i] || "").toLowerCase()] = true
    var order = ["Hell", "Fixed", "Performance", "Silent"]
    var list = []
    for (i = 0; i < order.length; i++) if (want[order[i].toLowerCase()]) list.push(order[i])
    plantDefaultMode(list, 0)
  }

  function plantDefaultMode(order, index) {
    if (index >= order.length) {
      finishDefaultModes()
      return
    }
    var name = order[index]
    var channels = Cc.speedChannels(devices)
    var temp = Cc.defaultTempSource(devices) || Cc.tempSourceFor(devices, "GPU")
    function snapshot() {
      call("POST", "/modes", { name: name, uid: newUid() }, function(res) {
        if (!res.ok) return fail(res)
        plantDefaultMode(order, index + 1)
      })
    }
    if (!channels.length || !temp) {
      snapshot()
      return
    }
    assignModeDefaults(name, channels, temp, snapshot)
  }

  function assignModeDefaults(modeName, channels, temp, done) {
    var fans = []
    var pumps = []
    var i
    for (i = 0; i < channels.length; i++) {
      if (channels[i].isPump) pumps.push(channels[i])
      else fans.push(channels[i])
    }
    function bindAll(uid, rows, next) {
      var at = 0
      function step() {
        if (at >= rows.length) {
          next()
          return
        }
        var channel = rows[at++]
        var path = "/devices/" + encodeURIComponent(channel.deviceUid) + "/settings/" + encodeURIComponent(channel.name) + "/profile"
        call("PUT", path, { profile_uid: uid }, function(res) {
          if (!res.ok) return fail(res)
          step()
        })
      }
      step()
    }
    function plantPumps() {
      if (!pumps.length) {
        if (done) done()
        return
      }
      createGraph(modeName + " pump", Cc.modeDefaultPoints(modeName, true), temp, 50, function(uid) {
        bindAll(uid, pumps, done)
      })
    }
    if (!fans.length) {
      plantPumps()
      return
    }
    createGraph(modeName + " fans", Cc.modeDefaultPoints(modeName, false), temp, 0, function(uid) {
      bindAll(uid, fans, plantPumps)
    })
  }

  function finishDefaultModes() {
    call("GET", "/modes", null, function(res) {
      if (!res.ok) return fail(res)
      var found = (res.body && res.body.modes) || []
      var silent = ""
      var i
      for (i = 0; i < found.length; i++) {
        if (found[i] && String(found[i].name || "").toLowerCase() === "silent") silent = found[i].uid || ""
      }
      if (!silent) {
        refresh()
        return
      }
      call("POST", "/modes-active/" + encodeURIComponent(silent), {}, function(active) {
        if (!active.ok) return fail(active)
        refresh()
      })
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

  function loadUi() {
    var id = rpcId
    rpcId = rpcId + 1
    var next = ({})
    for (var k in pending) next[k] = pending[k]
    next[id] = function(res) {
      var body = res && res.body ? res.body : ({})
      dynamicScale = body.dynamicScale === true
      textFollow = body.textFollow !== false
      var size = Number(body.textSize)
      if (isFinite(size) && size > 0) textSize = size
      // A toggle that landed before this read must not be put back.
      if (!showBarHeld) showBar = body.showBar !== false
      lcdBackground = body.lcdBackground !== false
      var seconds = Number(body.lcdSeconds)
      lcdSeconds = root.lcdSecondsOk(seconds) ? seconds : 5
      lcdThemeSync = body.lcdThemeSync === true
      uiReady = true
    }
    pending = next
    send({ op: "ui-get", id: id })
  }

  function setUi(patch) {
    var body = {
      dynamicScale: dynamicScale,
      textFollow: textFollow,
      textSize: textSize,
      lcdBackground: lcdBackground,
      lcdSeconds: lcdSeconds,
      lcdThemeSync: lcdThemeSync
    }
    // Leave showBar out until the file has been read, unless this patch sets it.
    if (uiReady) body.showBar = showBar
    var src = patch || ({})
    if (src.dynamicScale !== undefined) body.dynamicScale = src.dynamicScale === true
    if (src.textFollow !== undefined) body.textFollow = src.textFollow !== false
    if (src.textSize !== undefined) body.textSize = Number(src.textSize)
    if (src.showBar !== undefined) {
      body.showBar = src.showBar !== false
      showBarHeld = true
    }
    if (src.lcdBackground !== undefined) body.lcdBackground = src.lcdBackground !== false
    if (src.lcdSeconds !== undefined) {
      var seconds = Number(src.lcdSeconds)
      if (lcdSecondsOk(seconds)) body.lcdSeconds = seconds
    }
    if (src.lcdThemeSync !== undefined) body.lcdThemeSync = src.lcdThemeSync === true
    dynamicScale = body.dynamicScale
    textFollow = body.textFollow
    textSize = body.textSize
    lcdBackground = body.lcdBackground !== false
    lcdSeconds = lcdSecondsOk(body.lcdSeconds) ? body.lcdSeconds : 5
    lcdThemeSync = body.lcdThemeSync === true
    if (body.showBar !== undefined) showBar = body.showBar
    var id = rpcId
    rpcId = rpcId + 1
    send({ op: "ui-set", id: id, body: body })
  }

  function loadPack() {
    var id = rpcId
    rpcId = rpcId + 1
    var next = ({})
    for (var k in pending) next[k] = pending[k]
    next[id] = function(res) {
      var body = res && res.body ? res.body : ({})
      curvePack = body && body.kind === "omaflow-curves" ? body : ({})
    }
    pending = next
    send({ op: "pack-get", id: id })
  }

  function setCurvePack(pack) {
    curvePack = pack || ({})
    var id = rpcId
    rpcId = rpcId + 1
    var next = ({})
    for (var k in pending) next[k] = pending[k]
    next[id] = function(res) {
      if (!res.ok) fail(res)
    }
    pending = next
    send({ op: "pack-set", id: id, body: pack })
  }

  function clearCurvePack() {
    curvePack = ({})
    send({ op: "pack-clear", id: rpcId })
    rpcId = rpcId + 1
  }

  function consumePackMode(name) {
    var pack = curvePack
    if (!pack || pack.kind !== "omaflow-curves") return
    var want = String(name || "").toLowerCase()
    var kept = []
    var modesIn = pack.modes || []
    var i
    for (i = 0; i < modesIn.length; i++) {
      var mode = modesIn[i]
      if (!mode || String(mode.name || "").toLowerCase() === want) continue
      kept.push(mode)
    }
    if (kept.length === (pack.modes || []).length) return
    if (!kept.length) {
      clearCurvePack()
      return
    }
    var next = ({})
    for (var k in pack) next[k] = pack[k]
    next.modes = kept
    setCurvePack(next)
  }

  function writeUserFile(path, body, done) {
    var id = rpcId
    rpcId = rpcId + 1
    var next = ({})
    for (var k in pending) next[k] = pending[k]
    next[id] = function(res) {
      if (done) done(res)
    }
    pending = next
    send({ op: "file-write", id: id, path: path, body: body })
  }

  function readUserFile(path, done) {
    var id = rpcId
    rpcId = rpcId + 1
    var next = ({})
    for (var k in pending) next[k] = pending[k]
    next[id] = function(res) {
      if (done) done(res)
    }
    pending = next
    send({ op: "file-read", id: id, path: path })
  }

  function saveGraphs(modeUid, jobs, done) {
    var index = 0
    var list = jobs || []
    function step() {
      if (index >= list.length) {
        if (done) done()
        return
      }
      var job = list[index++]
      // A shared profile is one object. Writing it would move every mode
      // that still points at it. Those jobs are copied instead.
      if (Cc.otherModeUsesProfile(modes, job.profileUid, modeUid)) {
        lastError = "That curve is used by another mode, so it was not written"
        return
      }
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

  // A CoolerControl profile is one object. Two modes that store the same
  // profile uid share that curve, so a write moves both. Copy the profile
  // and point only this mode at the copy.
  function splitCurveJobs(uid, jobs) {
    var own = []
    var shared = []
    var list = jobs || []
    var i
    for (i = 0; i < list.length; i++) {
      var job = list[i]
      if (!job || !job.profileUid) continue
      if (Cc.otherModeUsesProfile(modes, job.profileUid, uid)) shared.push(job)
      else own.push(job)
    }
    return { own: own, shared: shared }
  }

  function cloneGraph(profile, points, minDuty, name, done) {
    var draft = JSON.parse(JSON.stringify(profile))
    draft.uid = newUid()
    draft.name = String(name || "Curve").slice(0, 48)
    var shaped = Cc.withGraphPoints(draft, points, minDuty)
    call("POST", "/profiles", shaped, function(res) {
      if (!res.ok) return fail(res)
      if (done) done(draft.uid)
    })
  }

  function assignChannels(channels, profileUid, done) {
    var index = 0
    var list = channels || []
    function step() {
      if (index >= list.length) {
        if (done) done()
        return
      }
      var channel = list[index++]
      if (!channel || !channel.deviceUid || !channel.name) {
        step()
        return
      }
      var path = "/devices/" + encodeURIComponent(channel.deviceUid) + "/settings/" + encodeURIComponent(channel.name) + "/profile"
      call("PUT", path, { profile_uid: profileUid }, function(res) {
        if (!res.ok) return fail(res)
        step()
      })
    }
    step()
  }

  // The mode is already the running one, so its live channels match what it
  // stored. Only the cloned channels differ. The snapshot writes those back.
  // CoolerControl has no call that retargets one stored channel on its own.
  function retargetShared(uid, jobs, done) {
    var index = 0
    var list = []
    var seen = ({})
    var raw = jobs || []
    var n
    for (n = 0; n < raw.length; n++) {
      var item = raw[n]
      if (!item || !item.profileUid || seen[item.profileUid]) continue
      seen[item.profileUid] = true
      list.push(item)
    }
    var mode = Cc.modeByUid(modes, uid)
    var modeName = mode && mode.name ? mode.name : "Mode"
    function step() {
      if (index >= list.length) {
        call("PUT", "/modes/" + encodeURIComponent(uid) + "/settings", {}, function(res) {
          if (!res.ok) return fail(res)
          refresh()
          if (done) done()
        })
        return
      }
      var job = list[index++]
      var profile = Cc.profileByUid(profiles, job.profileUid)
      if (!profile) {
        lastError = "That curve is not a saved profile"
        return
      }
      var channels = Cc.modeProfileChannels(mode, job.profileUid)
      if (!channels.length) {
        step()
        return
      }
      var copyName = (modeName + " " + (profile.name || "curve") + " " + newUid().slice(0, 4)).replace(/\s+/g, " ")
      cloneGraph(profile, job.points, job.minDuty, copyName, function(newId) {
        assignChannels(channels, newId, step)
      })
    }
    step()
  }

  // Writes the curves this mode is showing, then runs the mode.
  // An empty mode is refused: activating one makes the daemon reset every channel.
  // A profile another mode still uses is copied after this mode is running,
  // so the write does not move the other mode.
  // A running calibration owns the channel. The daemon rejects other writes
  // until that sweep finishes, so Apply waits.
  function applyModeCurves(uid, jobs, done) {
    if (!uid) return
    if (calibrationBusy) {
      lastError = "A fan is being calibrated. Apply waits until that sweep finishes."
      notice = lastError
      return
    }
    var split = splitCurveJobs(uid, jobs)
    saveGraphs(uid, split.own, function() {
      call("POST", "/modes-active/" + encodeURIComponent(uid), {}, function(res) {
        if (!res.ok) return fail(res)
        activeModeUid = String(uid)
        notice = ""
        if (!split.shared.length) {
          refresh()
          if (done) done()
          return
        }
        retargetShared(uid, split.shared, done)
      })
    })
  }

  function startCalibration(deviceUid, channel) {
    startCalibrations([{ deviceUid: deviceUid, name: channel }])
  }

  function loadCalibrations() {
    call("GET", "/calibrations", null, function(res) {
      if (!res.ok) {
        if (Number(res.status) === 404) {
          calibrations = []
          return
        }
        return fail(res)
      }
      calibrations = (res.body && res.body.calibrations) || []
    })
  }

  // GET /calibrations/batch is JSON null when this daemon has never swept.
  // A start that just returned 202 can beat the first read, so a few empty
  // replies keep the queued card instead of dropping the sweep.
  function loadCalibrationBatch() {
    call("GET", "/calibrations/batch", null, function(res) {
      if (!res.ok) {
        if (Number(res.status) === 404) {
          calibrationAwait = false
          calibrationMiss = 0
          calibrationBatch = Calib.emptyBatch()
          calibrationStatus = ({})
          return
        }
        if (calibrationAwait) {
          calibrationMiss = calibrationMiss + 1
          if (calibrationMiss < 3) return
          calibrationAwait = false
        }
        return fail(res)
      }
      var was = calibrationBusy
      var next = Calib.normalizeBatch(res.body)
      if (!next.active && calibrationAwait && !(next.entries && next.entries.length)) {
        calibrationMiss = calibrationMiss + 1
        if (calibrationMiss < 3) return
        calibrationAwait = false
        calibrationBatch = Calib.emptyBatch()
        calibrationStatus = ({})
        loadCalibrations()
        return
      }
      calibrationMiss = 0
      calibrationAwait = false
      calibrationBatch = next
      if (next.active) {
        var entries = next.entries || []
        var i
        for (i = 0; i < entries.length; i++) {
          var row = entries[i]
          if (row && String(row.phase) === "running")
            loadCalibrationStatus(row.device_uid, row.channel_name)
        }
      } else if (was) {
        calibrationStatus = ({})
        loadCalibrations()
      }
    })
  }

  function loadCalibrationStatus(deviceUid, channel) {
    if (!deviceUid || !channel) return
    var path = "/calibrations/" + encodeURIComponent(deviceUid) + "/channels/" + encodeURIComponent(channel) + "/status"
    call("GET", path, null, function(res) {
      if (!res.ok || !calibrationBusy) return
      var key = String(deviceUid) + "\n" + String(channel)
      var copy = ({})
      var cur = calibrationStatus || ({})
      var name
      for (name in cur) copy[name] = cur[name]
      copy[key] = res.body || ({})
      calibrationStatus = copy
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
    if (Cc.profileModeCount(modes, profileUid) > 1) {
      lastError = "That curve is used by another mode, so it was not written"
      return
    }
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

  // One batch, one fan at a time. The daemon keeps sweeping if this
  // window closes. A second start is refused until that batch ends.
  function startCalibrations(list) {
    if (calibrationBusy) {
      lastError = "A calibration is already running."
      notice = lastError
      return
    }
    var channels = []
    var jobs = list || []
    var i
    for (i = 0; i < jobs.length; i++) {
      var item = jobs[i]
      if (!item || !item.deviceUid || !item.name) continue
      channels.push({ device_uid: String(item.deviceUid), channel_name: String(item.name) })
    }
    if (!channels.length) return
    lastError = ""
    call("POST", "/calibrations/batch/start", { channels: channels, concurrency: 1 }, function(res) {
      if (!res.ok) {
        loadCalibrationBatch()
        return fail(res)
      }
      var entries = []
      var n
      for (n = 0; n < channels.length; n++) {
        entries.push({
          device_uid: channels[n].device_uid,
          channel_name: channels[n].channel_name,
          phase: "queued",
          percent: null,
          stage: null,
          message: null
        })
      }
      calibrationAwait = true
      calibrationMiss = 0
      calibrationBatch = { active: true, started_at: "", entries: entries }
      notice = "Calibration started"
      loadCalibrationBatch()
    })
  }

  function lcdSecondsOk(seconds) {
    return seconds === 2 || seconds === 5 || seconds === 10 || seconds === 30 || seconds === 60
  }

  function msUntilNextMinute() {
    var now = new Date()
    var wait = (60 - now.getSeconds()) * 1000 - now.getMilliseconds() + 250
    if (wait < 1000) wait = wait + 60000
    return wait
  }

  function readLcdFace(raw) {
    var face = "liquid"
    try {
      var obj = JSON.parse(String(raw || ""))
      face = String(obj && obj.face || "liquid")
    } catch (e) {
      face = "liquid"
    }
    if (face !== "liquid" && face !== "cpu" && face !== "cpu-gpu" && face !== "cpu-liquid" && face !== "omarchy" && face !== "omarchy-time")
      face = "liquid"
    lcdFace = face
    if (face === "omarchy-time") lcdClockWait = msUntilNextMinute()
  }

  function themeLcd() {
    if (stopping || !lcdBackground || lcdFace !== "omarchy" || !lcdThemeSync) return
    if (connection !== "ready") return
    themeLcdDelay.restart()
  }

  function previewLcd(deviceName, width, height, face, accent, done) {
    var id = rpcId
    rpcId = rpcId + 1
    var next = ({})
    for (var k in pending) next[k] = pending[k]
    next[id] = function(res) {
      if (done) done(res)
    }
    pending = next
    if (!send({
      op: "lcd-preview",
      id: id,
      deviceName: String(deviceName || ""),
      width: Math.max(0, Math.round(Number(width) || 0)),
      height: Math.max(0, Math.round(Number(height) || 0)),
      face: String(face || "omarchy"),
      accent: String(accent || "")
    })) {
      dropPending(id)
      if (done) done({ ok: false, status: 0, error: "not connected" })
    }
  }

  function pushLcdImage(deviceUid, channel, brightness, face, angle, accent, accent2, tempText, temp2, shape, width, height, deviceName, done) {
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
      height: Math.max(0, Math.round(Number(height) || 0)),
      deviceName: String(deviceName || "")
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
      loadUi()
      loadPack()
      if (msg.token) refresh()
      else lastError = "Pair coolercontrold with ~/.config/omaflow/coolercontrol.token"
      return
    }
    if (msg.event === "up") {
      if (connection !== "unauthorized" && connection !== "need-token") {
        // The daemon can appear after this process started. Status events
        // alone do not load devices, modes, or profiles.
        refresh()
      }
      return
    }
    if (msg.event === "down") {
      if (msg.error === "need-token" || msg.status === 401 || msg.status === 403) fail(msg)
      else {
        connection = "down"
        transportError = true
        lcdKeepBusy = false
        calibrationAwait = false
        calibrationMiss = 0
        lastError = msg.error || "coolercontrold is not running"
      }
      return
    }
    if (msg.event === "status") {
      statusDevices = (msg.body && msg.body.devices) || statusDevices
      noteReady()
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
      root.lcdKeepBusy = false
      restart.interval = root.restartDelayMs
      root.restartDelayMs = Math.min(30000, root.restartDelayMs * 2)
      restart.start()
    }
  }

  Process {
    id: pkgProbe
    command: ["pacman", "-Q", "coolercontrold"]
    stdout: SplitParser {
      onRead: function(line) { root.pkgCode = 0 }
    }
    onExited: function(code) {
      root.pkgCode = code
      root.finishProbe()
    }
  }

  Process {
    id: unitProbe
    command: ["systemctl", "show", "coolercontrold", "-p", "LoadState", "-p", "ActiveState", "--no-pager"]
    stdout: SplitParser {
      onRead: function(line) { root.unitBuf = root.unitBuf ? (root.unitBuf + "\n" + line) : String(line) }
    }
    onExited: function() { root.finishProbe() }
  }

  // Install asks once, the same way Start with the PC asks before enable.
  // pkexec is what shows the password dialog from the panel. omarchy pkg add
  // installs the daemon package and does not install the desktop package.
  Process {
    id: daemonInstall
    command: ["pkexec", "/usr/share/omarchy/bin/omarchy", "pkg", "add", "coolercontrold"]
    stderr: SplitParser {
      onRead: function(line) { root.daemonNote = String(line || "") }
    }
    onExited: function(code) {
      root.finishDaemonAction(code, "Omaflow could not install coolercontrold. In a terminal: omarchy pkg add coolercontrold")
    }
  }

  // Start does not enable the unit. Start with the PC stays off until that
  // switch is used. Same password dialog as the enable switch.
  Process {
    id: daemonStart
    command: ["pkexec", "systemctl", "start", "coolercontrold"]
    stderr: SplitParser {
      onRead: function(line) { root.daemonNote = String(line || "") }
    }
    onExited: function(code) {
      root.finishDaemonAction(code, "Omaflow could not start the daemon. In a terminal: sudo systemctl start coolercontrold")
    }
  }

  Timer {
    interval: 3000
    repeat: true
    triggeredOnStart: true
    running: !root.stopping && root.connection !== "ready"
    onTriggered: root.probeDaemon()
  }

  FileView {
    id: lcdViewFile
    path: Quickshell.env("HOME") + "/.config/omaflow/lcd-view.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.readLcdFace(text())
    onFileChanged: reload()
  }

  FileView {
    id: themeColorsFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: root.themeLcd()
  }

  FileView {
    id: themeNameFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: root.themeLcd()
  }

  Timer {
    id: themeLcdDelay
    interval: 400
    repeat: false
    onTriggered: root.keepLcd()
  }

  Timer {
    id: lcdKeep
    interval: root.lcdFace === "omarchy-time" ? root.lcdClockWait : Math.max(2000, root.lcdSeconds * 1000)
    repeat: true
    running: !root.stopping && root.lcdBackground && root.connection === "ready" && root.lcdChannels.length > 0 && !(root.lcdFace === "omarchy" && root.lcdThemeSync)
    onTriggered: {
      root.keepLcd()
      if (root.lcdFace === "omarchy-time") root.lcdClockWait = root.msUntilNextMinute()
    }
    onRunningChanged: {
      if (running && root.lcdFace === "omarchy-time") root.lcdClockWait = root.msUntilNextMinute()
    }
  }

  Timer {
    id: lcdKick
    interval: 400
    repeat: false
    onTriggered: root.keepLcd()
  }

  Timer {
    id: calibTimer
    interval: 1000
    repeat: true
    running: !root.stopping && root.connection === "ready" && root.calibrationBusy
    onTriggered: root.loadCalibrationBatch()
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
