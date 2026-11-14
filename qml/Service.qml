import QtQuick
import Quickshell
import Quickshell.Io
import "CcMap.js" as Cc
import "Calib.js" as Calib
import "RepoPath.js" as Repo

// Headless CoolerControl client. The window and the bar each load their
// own copy. Fan writes and sensor polls stay on coolercontrold's own
// poll_rate. This service never changes it and never writes PWM itself.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string clientPath: Repo.rootFile("scripts/cc_client.py")
  property bool pumpFloor: true
  property bool pumpFloorHeld: false
  property bool pumpFloorBusy: false
  property bool pumpFloorLiftPending: false
  property string pumpFloorNote: ""
  property bool silentRamp: false
  property bool silentRampHeld: false
  property bool silentRampBusy: false
  property string silentRampNote: ""
  property string silentRampUid: ""
  property var silentRampBinds: []
  // 0 is a real floor. The property stays 50 until the user turns it off.
  readonly property int pumpMin: pumpFloor ? 50 : 0

  onPumpFloorChanged: if (!stopping) rebuild()
  onCalibrationBusyChanged: {
    if (stopping || calibrationBusy || !pumpFloorLiftPending) return
    pumpFloorLiftPending = false
    if (pumpFloor) liftPumpProfiles()
  }

  property string connection: "down"
  property bool streamHold: false
  property string heldError: ""
  property double clientStartedMs: 0
  property bool sawHello: false
  property double lastStatusMs: 0
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
  property bool lcdLive: true
  property string lcdPicture: ""
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
  // Duty and RPM for those channels. The row objects stay put while only
  // these numbers change.
  property var channelLive: ({})
  property var lcdChannels: []
  property var temps: ({ cpu: null, gpu: null, coolant: null, hottest: null })
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
  property bool pinGroups: false
  property bool textFollow: true
  property int textSize: 12
  property bool showBar: true
  property bool watchProcesses: false
  // Bumped only after a process poll is accepted. A failed send leaves it alone.
  property int processEpoch: 0
  property var processCpu: []
  property var processGpu: []
  property real processCpuTotal: 0
  property real processGpuTotal: 0
  property bool processGpuOk: true
  property bool uiReady: false
  property bool showBarHeld: false
  property bool pinGroupsHeld: false
  property var curvePack: ({})
  property bool modesKnown: false
  property bool catalogBusy: false
  property bool catalogAgain: false
  property bool catalogIfStale: false
  // The process start emits hello and then the stream's first up. One catalog
  // covers both. A later up is a new stream and loads the catalog again.
  property bool skipNextUp: false
  // Status arrives about once a second. A new channel, a missing channel, or
  // a fan that starts or stops rebuilds the rows. A duty or RPM change replaces
  // channelLive only, so the open lists are not rebuilt on every sample.
  property string channelsSig: ""
  property string channelLiveSig: ""
  property string lcdSig: ""
  property string tempsSig: ""
  property bool defaultsPlanted: false

  property bool stopping: false
  property int restartDelayMs: 2000
  property int rpcId: 1
  property var pending: ({})

  function send(obj) {
    if (!client.running) return false
    client.write(JSON.stringify(obj) + "\n")
    return true
  }

  // QML replaces `pending`. Each call copies the map and stores one callback.
  function track(done) {
    var id = rpcId
    rpcId = rpcId + 1
    var next = Cc.copyMap(pending)
    if (done) next[id] = done
    pending = next
    return id
  }

  // `report` is set only where a failed send already called the callback.
  function dispatch(msg, done, report) {
    var id = track(done)
    msg.id = id
    if (send(msg)) return true
    dropPending(id)
    if (report && done) done({ ok: false, status: 0, error: "not connected" })
    return false
  }

  // Fire-and-forget. A failed send does not call back and does not change connection.
  function post(msg) {
    msg.id = rpcId
    rpcId = rpcId + 1
    send(msg)
  }

  function call(method, path, body, done) {
    dispatch({
      op: "call",
      method: method,
      path: path,
      body: body === undefined ? null : body
    }, done, true)
  }

  function deviceSettingPath(deviceUid, channel, tail) {
    return "/devices/" + encodeURIComponent(deviceUid) + "/settings/" + encodeURIComponent(channel) + "/" + tail
  }

  function dropPending(id) {
    var next = ({})
    for (var k in pending) if (String(k) !== String(id)) next[k] = pending[k]
    pending = next
  }

  // A daemon body is often JSON or an HTML page. The chip shows one sentence.
  function plainError(error, fallback) {
    var err = String(error || "").replace(/^\s+|\s+$/g, "")
    if (err.charAt(0) === "{") {
      try {
        var obj = JSON.parse(err)
        var inner = obj && typeof obj.error === "string" ? obj.error : ""
        inner = inner.replace(/^\s+|\s+$/g, "")
        if (inner && inner.length <= 140 && inner.indexOf("<") < 0 && inner.indexOf("{") < 0 && inner.indexOf("\n") < 0)
          return inner
      } catch (e) {}
      return fallback
    }
    if (!err || err.length > 140 || err.indexOf("<") >= 0 || err.indexOf("{") >= 0 || err.indexOf("\n") >= 0)
      return fallback
    return err
  }

  function fail(res) {
    cancelHold()
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
    if (status === 429) {
      connection = "unauthorized"
      transportError = false
      lastError = "CoolerControl is rate limiting logins"
      return
    }
    if (status === 0) {
      connection = "down"
      transportError = true
      lastError = plainError(error, "coolercontrold is not running")
      return
    }
    transportError = false
    lastError = plainError(error, "HTTP " + status)
    notice = lastError
  }

  // A successful read means the refused connection is over. Leave a real
  // action error, such as a rejected curve, where the page can still show it.
  function noteReady() {
    if (connection === "need-token" || connection === "unauthorized") return
    connection = "ready"
    if (!lastStatusMs) lastStatusMs = Date.now()
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

  // Shared by the keep timer and an explicit face command. The keep path
  // does not send a face; the helper reads the saved one.
  function fillLcd(msg, screen, interval) {
    var sample = temps || ({})
    msg.device = screen.deviceUid
    msg.channel = screen.name
    msg.deviceName = screen.deviceName || ""
    msg.width = Math.round(Number(screen.screenWidth) || 0)
    msg.height = Math.round(Number(screen.screenHeight) || 0)
    msg.cpu = sample.cpu === undefined ? null : sample.cpu
    msg.gpu = sample.gpu === undefined ? null : sample.gpu
    msg.coolant = sample.coolant === undefined ? null : sample.coolant
    msg.interval = interval
    return msg
  }

  function keepLcd() {
    if (stopping || !lcdBackground || connection !== "ready" || lcdKeepBusy) return
    if (lcdFace === "picture" || lcdSeconds === 0) return
    if (!lcdChannels || !lcdChannels.length) return
    var screen = lcdChannels[0]
    if (!screen || !screen.deviceUid || !screen.name) return
    var id = track(function(res) {
      root.lcdKeepBusy = false
      if (res && res.ok === false) console.warn("omaflow lcd: " + (res.error || "image rejected"))
    })
    lcdKeepBusy = true
    if (!send(fillLcd({ op: "lcd-keep", id: id }, screen, lcdFace === "omarchy-time" ? 60 : lcdSeconds))) {
      dropPending(id)
      lcdKeepBusy = false
    }
  }

  function rebuild() {
    var shaped = Cc.view(devices, statusDevices, modes, activeModeUid, pumpMin)
    var nextShape = JSON.stringify(Cc.channelShape(shaped.channels))
    if (nextShape !== channelsSig) {
      channelsSig = nextShape
      channels = shaped.channels
    } else {
      Cc.paintLive(channels, shaped.channels)
    }
    var live = Cc.channelLive(shaped.channels)
    var nextLive = JSON.stringify(live)
    if (nextLive !== channelLiveSig) {
      channelLiveSig = nextLive
      channelLive = live
    }
    var nextLcd = JSON.stringify(shaped.lcdChannels)
    if (nextLcd !== lcdSig) {
      lcdSig = nextLcd
      lcdChannels = shaped.lcdChannels
    }
    var nextTemps = JSON.stringify(shaped.temps)
    if (nextTemps !== tempsSig) {
      tempsSig = nextTemps
      temps = shaped.temps
    }
    if (shaped.activeModeName !== activeModeName) activeModeName = shaped.activeModeName
  }

  function partOk(part) {
    return !!(part && part.ok)
  }

  function applyCatalog(body) {
    var parts = body || ({})
    var order = ["devices", "profiles", "modes", "modesActive", "settings", "functions", "alerts", "status"]
    var i
    for (i = 0; i < order.length; i++) {
      var blocked = parts[order[i]]
      if (!blocked) continue
      if (blocked.error === "need-token" || blocked.status === 401 || blocked.status === 403) {
        fail(blocked)
        return
      }
    }
    var devicesOk = partOk(parts.devices)
    var statusOk = partOk(parts.status)
    if (devicesOk) {
      devices = (parts.devices.body && parts.devices.body.devices) || []
      noteReady()
    }
    if (partOk(parts.profiles))
      profiles = (parts.profiles.body && parts.profiles.body.profiles) || []
    if (partOk(parts.modes)) {
      modes = (parts.modes.body && parts.modes.body.modes) || []
      modesKnown = true
    }
    if (partOk(parts.modesActive)) {
      var uid = parts.modesActive.body && parts.modesActive.body.current_mode_uid
        ? String(parts.modesActive.body.current_mode_uid) : ""
      // An empty read follows the pump-image upload. It is not "no mode".
      if (uid) activeModeUid = uid
    }
    if (partOk(parts.settings))
      daemonSettings = parts.settings.body || ({})
    if (partOk(parts.functions))
      functions = (parts.functions.body && parts.functions.body.functions) || []
    if (partOk(parts.alerts))
      alerts = (parts.alerts.body && parts.alerts.body.alerts) || []
    if (partOk(parts.status)) {
      // An empty status body is a glitch, the same as a live tick. Keep the
      // readings already on screen. A later tick with devices replaces them.
      var nextStatus = parts.status.body && parts.status.body.devices
      if (nextStatus && nextStatus.length) statusDevices = nextStatus
      noteReady()
      notice = ""
    }
    rebuild()
    if (devicesOk && modesKnown) ensureDefaultModes()
    if (devicesOk) lcdKick.restart()
    if (parts.calibrations) takeCalibrationList(parts.calibrations)
    if (parts.calibrationBatch) takeCalibrationBatch(parts.calibrationBatch)
    if (!devicesOk || !statusOk) {
      fail((!devicesOk ? parts.devices : parts.status) || { ok: false, status: 0, error: "" })
      return
    }
    for (i = 0; i < order.length; i++) {
      if (order[i] === "devices" || order[i] === "status") continue
      var missed = parts[order[i]]
      if (!missed || missed.ok) continue
      if (missed.error === "need-token" || Number(missed.status) === 401 || Number(missed.status) === 403) {
        fail(missed)
        return
      }
      // A side read can fail without dropping a session that already has devices and status.
      lastError = plainError(missed.error, "HTTP " + (Number(missed.status) || 0))
      notice = lastError
      return
    }
  }

  function finishCatalog() {
    catalogBusy = false
    if (catalogAgain) {
      catalogAgain = false
      catalogIfStale = false
      beginCatalog()
      return
    }
    if (catalogIfStale) {
      catalogIfStale = false
      if (!(connection === "ready" && modesKnown)) beginCatalog()
    }
  }

  function beginCatalog() {
    catalogBusy = true
    var id = track(function(res) {
      if (res && res.ok) applyCatalog(res.body || ({}))
      else if (res) fail(res)
      finishCatalog()
    })
    if (send({ op: "catalog", id: id })) return
    dropPending(id)
    catalogBusy = false
    catalogAgain = false
    catalogIfStale = false
    fail({ ok: false, status: 0, error: "not connected" })
  }

  function refresh() {
    loadGroups()
    loadLinks()
    loadHidden()
    if (catalogBusy) {
      catalogAgain = true
      return
    }
    beginCatalog()
  }

  function pair(password) {
    dispatch({ op: "pair", password: String(password || "") }, function(res) {
      if (!res.ok) fail(res)
    }, true)
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

  function newUid() {
    var hex = ""
    for (var i = 0; i < 32; i++) hex += Math.floor(Math.random() * 16).toString(16)
    return hex.slice(0, 8) + "-" + hex.slice(8, 12) + "-" + hex.slice(12, 16) + "-" + hex.slice(16, 20) + "-" + hex.slice(20)
  }

  function loadGroups() {
    dispatch({ op: "groups-get" }, function(res) {
      if (!res || res.ok === false) return
      groups = Cc.cleanGroupList(res.body && res.body.groups)
    })
  }

  function saveGroups(nextGroups) {
    var prev = groups
    groups = Cc.cleanGroupList(nextGroups)
    dispatch({ op: "groups-set", body: { groups: groups } }, function(res) {
      if (res && res.ok === false) {
        groups = prev
        root.lastError = root.plainError(res.error, "Groups could not be saved.")
      } else if (res && res.ok && root.lastError === "Groups could not be saved.")
        root.lastError = ""
    })
  }

  function loadLinks() {
    dispatch({ op: "links-get" }, function(res) {
      if (!res || res.ok === false) return
      links = (res.body && res.body.links) || ({})
    })
  }

  function saveLinks(nextLinks) {
    var prev = links
    links = nextLinks || ({})
    dispatch({ op: "links-set", body: { links: links } }, function(res) {
      if (res && res.ok === false) {
        links = prev
        root.lastError = root.plainError(res.error, "Links could not be saved.")
      } else if (res && res.ok && root.lastError === "Links could not be saved.")
        root.lastError = ""
    })
  }

  function loadHidden() {
    dispatch({ op: "hidden-get" }, function(res) {
      if (!res || res.ok === false) return
      hiddenDevices = (res.body && res.body.devices) || ({})
    })
  }

  function saveHidden(nextHidden) {
    var prev = hiddenDevices
    hiddenDevices = nextHidden || ({})
    dispatch({ op: "hidden-set", body: { devices: hiddenDevices } }, function(res) {
      if (res && res.ok === false) {
        hiddenDevices = prev
        root.lastError = root.plainError(res.error, "Hidden devices could not be saved.")
      } else if (res && res.ok && root.lastError === "Hidden devices could not be saved.")
        root.lastError = ""
    })
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
    var channels = Cc.speedChannels(devices, pumpMin)
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
    function plantPumps() {
      if (!pumps.length) {
        if (done) done()
        return
      }
      createGraph(modeName + " pump", Cc.modeDefaultPoints(modeName, true), temp, pumpMin, function(uid) {
        assignChannels(pumps, uid, done)
      })
    }
    if (!fans.length) {
      plantPumps()
      return
    }
    createGraph(modeName + " fans", Cc.modeDefaultPoints(modeName, false), temp, 0, function(uid) {
      assignChannels(fans, uid, plantPumps)
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
      var copy = Cc.copyMap(group)
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
        var copy = Cc.copyMap(group)
        copy.members = members
        next.push(copy)
      }
    }
    saveGroups(next)
  }

  function createGraph(name, points, tempSource, minDuty, done, functionUid) {
    if (!tempSource) {
      lastError = "No temperature source is available for a new curve"
      return
    }
    var uid = newUid()
    var pace = functionUid ? String(functionUid) : "0"
    var draft = { uid: uid, name: name, function_uid: pace, p_type: "Graph", speed_profile: points }
    var shaped = Cc.withGraphPoints(draft, points, minDuty)
    shaped.temp_source = tempSource
    shaped.temp_min = 0
    shaped.temp_max = 100
    call("POST", "/profiles", shaped, function(res) {
      if (!res.ok) return fail(res)
      if (done) done(uid)
    })
  }

  function snapshotMode(modeUid, done, clearNotice) {
    call("PUT", "/modes/" + encodeURIComponent(modeUid) + "/settings", {}, function(saved) {
      if (!saved.ok) return fail(saved)
      if (clearNotice) notice = ""
      refresh()
      if (done) done()
    })
  }

  function bindChannel(modeUid, deviceUid, channel, profileUid, done) {
    call("PUT", deviceSettingPath(deviceUid, channel, "profile"), { profile_uid: profileUid }, function(res) {
      if (!res.ok) return fail(res)
      snapshotMode(modeUid, done, true)
    })
  }

  function bindMany(modeUid, members, profileUid, done) {
    assignChannels(members, profileUid, function() {
      snapshotMode(modeUid, done)
    })
  }

  function resetThen(modeUid, deviceUid, channel, after) {
    call("PUT", deviceSettingPath(deviceUid, channel, "reset"), {}, function(res) {
      if (!res.ok) return fail(res)
      if (after) after()
      snapshotMode(modeUid)
    })
  }

  function resetChannel(modeUid, deviceUid, channel, memberKey) {
    resetThen(modeUid, deviceUid, channel, function() { forgetMember(memberKey) })
  }

  // Drop a mode assignment without removing the fan from a shared group.
  function releaseChannel(modeUid, deviceUid, channel) {
    resetThen(modeUid, deviceUid, channel)
  }

  function saveDaemon(next) {
    var body = Cc.copyMap(next)
    // Poll interval stays with coolercontrold. A settings write keeps the
    // rate the daemon already reported.
    if (daemonSettings && daemonSettings.poll_rate !== undefined)
      body.poll_rate = daemonSettings.poll_rate
    call("PUT", "/settings", body, function(res) {
      if (!res.ok) return fail(res)
      daemonSettings = body
      notice = ""
    })
  }

  function saveFunction(fn) {
    call("PUT", "/functions", fn, function(res) {
      if (!res.ok) return fail(res)
      refresh()
    })
  }

  function refreshAlerts() {
    call("GET", "/alerts", null, function(res) {
      if (!res.ok) return fail(res)
      alerts = (res.body && res.body.alerts) || []
      notice = ""
    })
  }

  // The daemon rejects PUT /alerts/{uid}. The collection accepts a clean body.
  function saveAlert(alert) {
    var enabled = !alert || alert.enabled !== false
    call("PUT", "/alerts", Cc.alertWriteBody(alert, enabled), function(res) {
      if (!res.ok) return fail(res)
      refreshAlerts()
    })
  }

  function setAlertEnabled(alert, enabled) {
    if (!alert || !alert.uid) return
    var next = Cc.copyMap(alert)
    next.enabled = enabled === true
    saveAlert(next)
  }

  function createAlert(name, max, source) {
    if (!source || !source.device_uid || !source.channel_name) return
    var existing = Cc.alertNamed(alerts, name)
    if (existing) {
      setAlertEnabled(existing, true)
      return
    }
    var body = Cc.alertWriteBody({
      uid: newUid(),
      name: name,
      channel_source: source,
      min: 0,
      max: max,
      warmup_duration: 12,
      desktop_notify: true,
      desktop_notify_audio: false,
      desktop_notify_recovery: true
    }, true)
    call("POST", "/alerts", body, function(res) {
      if (!res.ok) return fail(res)
      refreshAlerts()
    })
  }

  // Turning the floor off does not rewrite curves. Turning it on raises
  // pump points that sit below 50. A profile is one object, so that write
  // changes every mode that still stores the same uid.
  function requestPumpFloorOff() {
    if (!pumpFloor || pumpFloorBusy || floorConfirm.running) return
    pumpFloorNote = ""
    pumpFloorBusy = true
    floorConfirm.running = true
  }

  function finishPumpFloorOff(code) {
    pumpFloorBusy = false
    if (Number(code) === 0) {
      setUi({ pumpFloor: false })
      pumpFloorNote = ""
      return
    }
    pumpFloorNote = "The pump floor stays on."
  }

  function enablePumpFloor() {
    if (pumpFloorBusy) return
    pumpFloorNote = ""
    setUi({ pumpFloor: true })
    if (calibrationBusy) {
      pumpFloorLiftPending = true
      pumpFloorNote = "Low pump points rise after the sweep."
      return
    }
    liftPumpProfiles()
  }

  function liftPumpProfiles() {
    var list = Cc.pumpProfilesToLift(modes, profiles, channels)
    var index = 0
    function step() {
      if (index >= list.length) {
        if (list.length) refresh()
        return
      }
      var profile = list[index++]
      var shaped = Cc.withGraphPoints(profile, profile.speed_profile || [], 50)
      call("PUT", "/profiles", shaped, function(res) {
        if (!res.ok) return fail(res)
        step()
      })
    }
    step()
  }

  function persistRamp(on, uid, binds) {
    var next = []
    var list = binds || []
    var i
    for (i = 0; i < list.length; i++) if (list[i]) next.push(list[i])
    setUi({
      silentRamp: on === true,
      silentRampUid: String(uid || ""),
      silentRampBinds: next
    })
  }

  function rampBindKey(row) {
    if (!row) return ""
    if (row.cloneUid && row.deviceUid && row.channel)
      return "c:" + row.cloneUid + ":" + row.deviceUid + ":" + row.channel
    if (row.cloneUid) return "o:" + row.cloneUid
    if (row.profileUid) return "p:" + row.profileUid
    return ""
  }

  function unionRampBinds(primary, extra) {
    var out = []
    var seen = ({})
    var lists = [primary || [], extra || []]
    var n
    var i
    for (n = 0; n < lists.length; n++) {
      var list = lists[n]
      for (i = 0; i < list.length; i++) {
        var row = list[i]
        var key = rampBindKey(row)
        if (!key || seen[key]) continue
        seen[key] = true
        out.push(row)
      }
    }
    return out
  }

  function findStoredBind(stored, row) {
    var list = stored || []
    var i
    for (i = 0; i < list.length; i++) {
      var item = list[i]
      if (!item) continue
      if (row.cloneUid && item.cloneUid === row.cloneUid && item.deviceUid === row.deviceUid && item.channel === row.channel)
        return item
      if (row.cloneUid && item.cloneUid === row.cloneUid && !row.deviceUid) return item
      if (row.profileUid && !row.cloneUid && !item.cloneUid && item.profileUid === row.profileUid) return item
      if (row.deviceUid && row.channel && item.deviceUid === row.deviceUid && item.channel === row.channel) return item
    }
    return null
  }

  function mergeRampBinds(already, stored) {
    var out = []
    var list = already || []
    var i
    for (i = 0; i < list.length; i++) {
      var row = list[i]
      if (!row) continue
      var prev = findStoredBind(stored, row)
      var profileUid = String(row.profileUid || "")
      var prevFunction = String(row.prevFunction || "0")
      if (prev) {
        if (!profileUid && prev.profileUid) profileUid = String(prev.profileUid)
        if ((!prevFunction || prevFunction === "0") && prev.prevFunction && String(prev.prevFunction) !== "0")
          prevFunction = String(prev.prevFunction)
      }
      out.push({
        deviceUid: String(row.deviceUid || ""),
        channel: String(row.channel || ""),
        profileUid: profileUid,
        cloneUid: String(row.cloneUid || ""),
        prevFunction: prevFunction || "0"
      })
    }
    return unionRampBinds(out, stored)
  }

  function dropProfiles(uids, done) {
    var index = 0
    var list = uids || []
    var failed = ({})
    function step() {
      if (index >= list.length) {
        if (done) done(failed)
        return
      }
      var uid = list[index++]
      if (!uid || uid === "0") {
        step()
        return
      }
      call("DELETE", "/profiles/" + encodeURIComponent(uid), null, function(res) {
        if (!res || (!res.ok && Number(res.status) !== 404)) failed[uid] = true
        step()
      })
    }
    step()
  }

  function removeRampFunction(uid, done) {
    if (!uid || uid === "0") {
      if (done) done(true)
      return
    }
    call("DELETE", "/functions/" + encodeURIComponent(uid), null, function(res) {
      if (done) done(!!(res && (res.ok || Number(res.status) === 404)))
    })
  }

  function rampStop(note, res, uid, binds, orphans) {
    if (note) silentRampNote = note
    if (res && !res.ok) fail(res)
    var kept = []
    var used = ({})
    var i
    for (i = 0; i < (binds || []).length; i++) {
      if (!binds[i]) continue
      kept.push(binds[i])
      if (binds[i].cloneUid) used[binds[i].cloneUid] = true
    }
    var drop = []
    for (i = 0; i < (orphans || []).length; i++) {
      var id = orphans[i]
      if (id && !used[id]) drop.push(id)
    }
    dropProfiles(drop, function(failed) {
      for (i = 0; i < drop.length; i++) {
        if (!failed[drop[i]]) continue
        kept.push({
          deviceUid: "",
          channel: "",
          profileUid: "",
          cloneUid: drop[i],
          prevFunction: "0"
        })
      }
      if (kept.length) persistRamp(true, uid, kept)
      else if (uid) removeRampFunction(uid, function() {})
      silentRampBusy = false
      refresh()
    })
  }

  function activateModeRaw(uid, done) {
    if (!uid || String(activeModeUid) === String(uid)) {
      if (done) done({ ok: true })
      return
    }
    call("POST", "/modes-active/" + encodeURIComponent(uid), {}, function(res) {
      if (res && res.ok) {
        activeModeUid = String(uid)
        rebuild()
      }
      if (done) done(res || { ok: false, status: 0, error: "not connected" })
    })
  }

  function ensureRampFunction(done) {
    var list = functions || []
    var i
    var found = ""
    if (silentRampUid && silentRampUid !== "0") {
      for (i = 0; i < list.length; i++) {
        if (list[i] && String(list[i].uid || "") === silentRampUid) {
          found = silentRampUid
          break
        }
      }
    }
    if (!found) {
      for (i = 0; i < list.length; i++) {
        var fn = list[i]
        if (!fn || String(fn.uid || "") === "0") continue
        if (String(fn.name || "") === "Omaflow silent ramp") {
          found = String(fn.uid || "")
          break
        }
      }
    }
    if (found) {
      if (done) done(found)
      return
    }
    var uid = newUid()
    call("POST", "/functions", Cc.silentRampFunction(uid), function(res) {
      if (!res.ok) {
        silentRampBusy = false
        silentRampNote = "The Silent fan pace was not saved."
        fail(res)
        if (done) done("")
        return
      }
      if (done) done(uid)
    })
  }

  function setSilentRamp(on) {
    if (silentRampBusy) return
    if (connection !== "ready") {
      silentRampNote = "CoolerControl is not connected."
      return
    }
    if (calibrationBusy) {
      silentRampNote = "A fan is being calibrated. The Silent pace waits until that sweep finishes."
      return
    }
    silentRampNote = ""
    silentRampBusy = true
    if (on) applySilentRamp()
    else clearSilentRamp()
  }

  function applySilentRamp() {
    var mode = Cc.modeNamed(modes, "silent")
    if (!mode || !mode.uid) {
      silentRampBusy = false
      silentRampNote = "Silent mode is not on this daemon."
      return
    }
    ensureRampFunction(function(uid) {
      if (!uid) return
      var plan = Cc.planSilentRamp(mode, modes, profiles, channels, uid)
      var binds = mergeRampBinds(plan.already, silentRampBinds)
      var orphans = []
      putRampInPlace(plan.inplace || [], uid, binds, function(ok, res) {
        if (!ok) {
          rampStop("The Silent fan pace was not saved.", res, uid, binds, orphans)
          return
        }
        postRampClones(plan.clones || [], uid, mode, binds, orphans, function(ok2, res2, note) {
          if (!ok2) {
            rampStop(note || "The Silent fan pace was not saved.", res2, uid, binds, orphans)
            return
          }
          var leaked = []
          var used = ({})
          var i
          for (i = 0; i < binds.length; i++) if (binds[i] && binds[i].cloneUid) used[binds[i].cloneUid] = true
          for (i = 0; i < orphans.length; i++) if (orphans[i] && !used[orphans[i]]) leaked.push(orphans[i])
          dropProfiles(leaked, function(failed) {
            for (i = 0; i < leaked.length; i++) {
              if (!failed[leaked[i]]) continue
              binds.push({
                deviceUid: "",
                channel: "",
                profileUid: "",
                cloneUid: leaked[i],
                prevFunction: "0"
              })
            }
            persistRamp(true, uid, binds)
            silentRampBusy = false
            if (!(plan.inplace || []).length && !(plan.clones || []).length && !(plan.already || []).length)
              silentRampNote = "Silent has no fan curves to ease."
            else silentRampNote = note || ""
            refresh()
          })
        })
      })
    })
  }

  function putRampInPlace(jobs, uid, binds, done) {
    var index = 0
    function step() {
      if (index >= jobs.length) {
        if (done) done(true, null)
        return
      }
      var job = jobs[index++]
      var profile = Cc.profileByUid(profiles, job.profileUid)
      if (!profile) {
        if (done) done(false, { ok: false, status: 0, error: "That curve is not a saved profile" })
        return
      }
      var draft = JSON.parse(JSON.stringify(profile))
      draft.function_uid = uid
      call("PUT", "/profiles", draft, function(res) {
        if (!res.ok) {
          if (done) done(false, res)
          return
        }
        binds.push({
          deviceUid: "",
          channel: "",
          profileUid: String(job.profileUid || ""),
          cloneUid: "",
          prevFunction: String(job.prevFunction || "0")
        })
        step()
      })
    }
    step()
  }

  function restoreSharedFunction(job, done) {
    if (!job || !job.restore) {
      if (done) done(true, null)
      return
    }
    var profile = Cc.profileByUid(profiles, job.profileUid)
    if (!profile) {
      if (done) done(false, { ok: false, status: 0, error: "That curve is not a saved profile" })
      return
    }
    var draft = JSON.parse(JSON.stringify(profile))
    draft.function_uid = "0"
    call("PUT", "/profiles", draft, function(res) {
      if (done) done(!!(res && res.ok), res)
    })
  }

  function postRampClones(jobs, uid, mode, binds, orphans, done) {
    var index = 0
    var posted = []
    function step() {
      if (index >= jobs.length) {
        if (!posted.length) {
          if (done) done(true, null, "")
          return
        }
        attachRampClones(mode, posted, binds, orphans, done)
        return
      }
      var job = jobs[index++]
      restoreSharedFunction(job, function(ok, res) {
        if (!ok) {
          if (done) done(false, res, "The Silent fan pace was not saved.")
          return
        }
        var profile = Cc.profileByUid(profiles, job.profileUid)
        if (!profile) {
          if (done) done(false, { ok: false, status: 0, error: "That curve is not a saved profile" }, "The Silent fan pace was not saved.")
          return
        }
        var draft = JSON.parse(JSON.stringify(profile))
        var cloneUid = newUid()
        draft.uid = cloneUid
        draft.name = Cc.rampCloneName(profile.name)
        draft.function_uid = uid
        var shaped = Cc.withGraphPoints(draft, profile.speed_profile || [], 0)
        shaped.function_uid = uid
        call("POST", "/profiles", shaped, function(res) {
          if (!res.ok) {
            if (done) done(false, res, "The Silent fan pace was not saved.")
            return
          }
          orphans.push(cloneUid)
          posted.push({
            cloneUid: cloneUid,
            profileUid: String(job.profileUid || ""),
            prevFunction: String(job.prevFunction || "0"),
            channels: job.channels || []
          })
          step()
        })
      })
    }
    step()
  }

  function bindRampChannels(job, binds, done) {
    var index = 0
    var list = job.channels || []
    function step() {
      if (index >= list.length) {
        if (done) done(true, null)
        return
      }
      var channel = list[index++]
      if (!channel || !channel.deviceUid || !channel.name) {
        step()
        return
      }
      call("PUT", deviceSettingPath(channel.deviceUid, channel.name, "profile"), { profile_uid: job.cloneUid }, function(res) {
        if (!res.ok) {
          var detail = res && res.error ? String(res.error) : ""
          // A hidden duplicate is still named in an old mode. The daemon has
          // no such device, so this channel cannot take the Silent copy.
          if (Number(res.status) === 404 || /device not found/i.test(detail)) {
            step()
            return
          }
          if (done) done(false, res)
          return
        }
        binds.push({
          deviceUid: String(channel.deviceUid),
          channel: String(channel.name),
          profileUid: String(job.profileUid || ""),
          cloneUid: String(job.cloneUid || ""),
          prevFunction: String(job.prevFunction || "0")
        })
        step()
      })
    }
    step()
  }

  // Silent has to be the running mode before a snapshot, or the snapshot
  // would store the other mode's live fans inside Silent.
  function attachRampClones(mode, posted, binds, orphans, done) {
    var previous = String(activeModeUid || "")
    var silentUid = String(mode.uid)
    activateModeRaw(silentUid, function(res) {
      if (!res || !res.ok) {
        if (done) done(false, res, "Silent could not be selected.")
        return
      }
      var index = 0
      function finish(ok, failed, note) {
        call("PUT", "/modes/" + encodeURIComponent(silentUid) + "/settings", {}, function(saved) {
          var modeNote = note || ""
          if (!saved.ok) {
            if (!previous || previous === silentUid) {
              if (done) done(false, saved, "Silent did not keep the eased fans.")
              return
            }
            activateModeRaw(previous, function(back) {
              var text = "Silent did not keep the eased fans."
              if (!back.ok) text = "Silent is running. Apply the previous mode again."
              if (done) done(false, saved, text)
            })
            return
          }
          if (!previous || previous === silentUid) {
            if (done) done(ok, failed, modeNote)
            return
          }
          activateModeRaw(previous, function(back) {
            if (!back.ok) modeNote = "Silent is running. Apply the previous mode again."
            if (done) done(ok, failed, modeNote)
          })
        })
      }
      function step() {
        if (index >= posted.length) {
          finish(true, null, "")
          return
        }
        bindRampChannels(posted[index++], binds, function(ok, res2) {
          if (!ok) {
            finish(false, res2, "The Silent fan pace was not saved.")
            return
          }
          step()
        })
      }
      step()
    })
  }

  function clearSilentRamp() {
    var fnUid = String(silentRampUid || "")
    var rows = silentRampBinds || []
    var inplace = []
    var clones = []
    var loose = []
    var seen = ({})
    var i
    for (i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (!row) continue
      if (row.cloneUid) {
        if (!row.profileUid || !row.deviceUid || !row.channel) loose.push(row)
        else clones.push(row)
        continue
      }
      if (!row.profileUid || seen[row.profileUid]) continue
      seen[row.profileUid] = true
      inplace.push({ profileUid: String(row.profileUid), prevFunction: String(row.prevFunction || "0") })
    }
    restoreRampFunctions(inplace, function(leftIn) {
      undoRampClones(clones, function(leftClones, modeNote) {
        var looseIds = []
        for (i = 0; i < loose.length; i++) looseIds.push(loose[i].cloneUid)
        dropProfiles(looseIds, function(failed) {
          var kept = []
          var keepUids = ({})
          var n
          for (n = 0; n < leftIn.length; n++) {
            kept.push(leftIn[n])
            if (leftIn[n].profileUid) keepUids[leftIn[n].profileUid] = true
          }
          for (n = 0; n < leftClones.length; n++) {
            kept.push(leftClones[n])
            if (leftClones[n].cloneUid) keepUids[leftClones[n].cloneUid] = true
          }
          for (n = 0; n < loose.length; n++) {
            if (!failed[loose[n].cloneUid]) continue
            kept.push(loose[n])
            keepUids[loose[n].cloneUid] = true
          }
          if (kept.length) {
            persistRamp(true, fnUid, kept)
            silentRampNote = modeNote || "A Silent copy could not be put back."
            silentRampBusy = false
            refresh()
            return
          }
          detachOtherRampProfiles(fnUid, keepUids, function(leftOther) {
            if (leftOther.length) {
              persistRamp(true, fnUid, leftOther)
              silentRampNote = modeNote || "A Silent copy could not be put back."
              silentRampBusy = false
              refresh()
              return
            }
            removeRampFunction(fnUid, function(ok) {
              if (!ok) {
                persistRamp(true, fnUid, [])
                silentRampNote = modeNote || "The Silent fan pace could not be removed."
                silentRampBusy = false
                refresh()
                return
              }
              persistRamp(false, "", [])
              silentRampNote = modeNote || ""
              silentRampBusy = false
              refresh()
            })
          })
        })
      })
    })
  }

  // A Silent fan curve made while the pace is on has no undo row. Put it
  // back on the default response before the pace function is removed.
  function detachOtherRampProfiles(fnUid, keepUids, done) {
    if (!fnUid || fnUid === "0") {
      if (done) done([])
      return
    }
    var jobs = []
    var list = profiles || []
    var i
    for (i = 0; i < list.length; i++) {
      var profile = list[i]
      if (!profile || String(profile.function_uid || "0") !== String(fnUid)) continue
      if (keepUids && keepUids[profile.uid]) continue
      jobs.push({ profileUid: String(profile.uid), prevFunction: "0" })
    }
    restoreRampFunctions(jobs, done)
  }

  function restoreRampFunctions(jobs, done) {
    var index = 0
    var left = []
    function step() {
      if (index >= jobs.length) {
        if (done) done(left)
        return
      }
      var job = jobs[index++]
      var profile = Cc.profileByUid(profiles, job.profileUid)
      if (!profile) {
        step()
        return
      }
      var draft = JSON.parse(JSON.stringify(profile))
      draft.function_uid = job.prevFunction ? String(job.prevFunction) : "0"
      call("PUT", "/profiles", draft, function(res) {
        if (!res.ok && Number(res.status) !== 404) {
          left.push({
            deviceUid: "",
            channel: "",
            profileUid: job.profileUid,
            cloneUid: "",
            prevFunction: job.prevFunction || "0"
          })
        }
        step()
      })
    }
    step()
  }

  function undoRampClones(rows, done) {
    if (!rows.length) {
      if (done) done([], "")
      return
    }
    var mode = Cc.modeNamed(modes, "silent")
    if (!mode || !mode.uid) {
      if (done) done(rows, "Silent mode is not on this daemon.")
      return
    }
    var previous = String(activeModeUid || "")
    var silentUid = String(mode.uid)
    activateModeRaw(silentUid, function(res) {
      if (!res || !res.ok) {
        if (done) done(rows, "Silent could not be selected.")
        return
      }
      var index = 0
      var left = []
      function restorePrevious(note, kept) {
        if (!previous || previous === silentUid) {
          if (done) done(kept, note)
          return
        }
        activateModeRaw(previous, function(back) {
          var text = note
          if (!back.ok) text = "Silent is running. Apply the previous mode again."
          if (done) done(kept, text)
        })
      }
      function finish() {
        call("PUT", "/modes/" + encodeURIComponent(silentUid) + "/settings", {}, function(saved) {
          if (!saved.ok) {
            restorePrevious("Silent did not keep the restored fans.", rows)
            return
          }
          var removable = []
          var seenClone = ({})
          var c
          for (c = 0; c < rows.length; c++) {
            var id = rows[c].cloneUid
            if (!id || seenClone[id]) continue
            seenClone[id] = true
            var still = false
            var k
            for (k = 0; k < left.length; k++) if (left[k].cloneUid === id) still = true
            if (!still) removable.push(id)
          }
          dropProfiles(removable, function(failed) {
            var kept = []
            var n
            for (n = 0; n < left.length; n++) kept.push(left[n])
            for (n = 0; n < rows.length; n++) {
              if (failed[rows[n].cloneUid]) kept.push(rows[n])
            }
            restorePrevious("", unionRampBinds(kept, []))
          })
        })
      }
      function step() {
        if (index >= rows.length) {
          finish()
          return
        }
        var row = rows[index++]
        call("PUT", deviceSettingPath(row.deviceUid, row.channel, "profile"), { profile_uid: row.profileUid }, function(put) {
          if (!put.ok && Number(put.status) !== 404) left.push(row)
          step()
        })
      }
      step()
    })
  }

  function loadUi() {
    dispatch({ op: "ui-get" }, function(res) {
      if (!res || res.ok === false) return
      var body = res.body ? res.body : ({})
      dynamicScale = body.dynamicScale === true
      // A toggle that landed before this read must not be put back.
      if (!pinGroupsHeld) pinGroups = body.pinGroups === true
      textFollow = body.textFollow !== false
      var size = Number(body.textSize)
      if (isFinite(size) && size > 0) textSize = size
      // A toggle that landed before this read must not be put back.
      if (!showBarHeld) showBar = body.showBar !== false
      lcdBackground = body.lcdBackground !== false
      // Number(null) is 0, and 0 is the Never stop. A missing value stays at 5.
      var seconds = body.lcdSeconds
      if (seconds === null || seconds === undefined || seconds === "") lcdSeconds = 5
      else {
        seconds = Number(seconds)
        lcdSeconds = root.lcdSecondsOk(seconds) ? seconds : 5
      }
      lcdThemeSync = body.lcdThemeSync === true
      if (!pumpFloorHeld) pumpFloor = body.pumpFloor !== false
      if (!silentRampHeld) {
        silentRamp = body.silentRamp === true
        silentRampUid = String(body.silentRampUid || "")
        var binds = body.silentRampBinds
        silentRampBinds = binds && binds.length !== undefined ? binds : []
      }
      uiReady = true
    })
  }

  function setUi(patch) {
    var prev = {
      dynamicScale: dynamicScale,
      pinGroups: pinGroups,
      textFollow: textFollow,
      textSize: textSize,
      showBar: showBar,
      lcdBackground: lcdBackground,
      lcdSeconds: lcdSeconds,
      lcdThemeSync: lcdThemeSync,
      pumpFloor: pumpFloor,
      silentRamp: silentRamp,
      silentRampUid: silentRampUid,
      silentRampBinds: silentRampBinds,
      pinGroupsHeld: pinGroupsHeld,
      showBarHeld: showBarHeld,
      pumpFloorHeld: pumpFloorHeld,
      silentRampHeld: silentRampHeld
    }
    var src = patch || ({})
    // Only the keys in this patch. A full snapshot would write defaults over a file
    // that was torn when the window started and readable again by the time this lands.
    var body = ({})
    var sending = false
    var exact = ["dynamicScale", "pinGroups", "lcdThemeSync", "silentRamp"]
    var loose = ["textFollow", "showBar", "lcdBackground", "pumpFloor"]
    var i
    for (i = 0; i < exact.length; i++) {
      if (src[exact[i]] === undefined) continue
      body[exact[i]] = src[exact[i]] === true
      sending = true
    }
    for (i = 0; i < loose.length; i++) {
      if (src[loose[i]] === undefined) continue
      body[loose[i]] = src[loose[i]] !== false
      sending = true
    }
    if (src.textSize !== undefined) {
      var size = Number(src.textSize)
      if (isFinite(size) && size > 0) {
        body.textSize = size
        sending = true
      }
    }
    if (src.lcdSeconds !== undefined) {
      var seconds = Number(src.lcdSeconds)
      if (lcdSecondsOk(seconds)) {
        body.lcdSeconds = seconds
        sending = true
      }
    }
    if (src.silentRampUid !== undefined) {
      body.silentRampUid = String(src.silentRampUid || "")
      sending = true
    }
    if (src.silentRampBinds !== undefined) {
      body.silentRampBinds = src.silentRampBinds || []
      sending = true
    }
    if (!sending) return
    if (src.pinGroups !== undefined) pinGroupsHeld = true
    if (src.showBar !== undefined) showBarHeld = true
    if (src.pumpFloor !== undefined) pumpFloorHeld = true
    if (src.silentRamp !== undefined || src.silentRampUid !== undefined || src.silentRampBinds !== undefined)
      silentRampHeld = true
    if (body.dynamicScale !== undefined) dynamicScale = body.dynamicScale
    if (body.pinGroups !== undefined) pinGroups = body.pinGroups === true
    if (body.textFollow !== undefined) textFollow = body.textFollow
    if (body.textSize !== undefined) textSize = body.textSize
    if (body.lcdBackground !== undefined) lcdBackground = body.lcdBackground !== false
    if (body.lcdSeconds !== undefined) lcdSeconds = body.lcdSeconds
    if (body.lcdThemeSync !== undefined) lcdThemeSync = body.lcdThemeSync === true
    if (body.showBar !== undefined) showBar = body.showBar
    if (body.pumpFloor !== undefined) pumpFloor = body.pumpFloor !== false
    if (body.silentRamp !== undefined) silentRamp = body.silentRamp === true
    if (body.silentRampUid !== undefined) silentRampUid = String(body.silentRampUid || "")
    if (body.silentRampBinds !== undefined) silentRampBinds = body.silentRampBinds || []
    dispatch({ op: "ui-set", body: body }, function(res) {
      if (res && res.ok === false) {
        dynamicScale = prev.dynamicScale
        pinGroups = prev.pinGroups
        textFollow = prev.textFollow
        textSize = prev.textSize
        showBar = prev.showBar
        lcdBackground = prev.lcdBackground
        lcdSeconds = prev.lcdSeconds
        lcdThemeSync = prev.lcdThemeSync
        pumpFloor = prev.pumpFloor
        silentRamp = prev.silentRamp
        silentRampUid = prev.silentRampUid
        silentRampBinds = prev.silentRampBinds
        pinGroupsHeld = prev.pinGroupsHeld
        showBarHeld = prev.showBarHeld
        pumpFloorHeld = prev.pumpFloorHeld
        silentRampHeld = prev.silentRampHeld
        root.lastError = root.plainError(res.error, "Settings could not be read.")
      } else if (res && res.ok && root.lastError === "Settings could not be read.")
        root.lastError = ""
    })
  }

  function loadPack() {
    dispatch({ op: "pack-get" }, function(res) {
      var body = res && res.body ? res.body : ({})
      curvePack = Cc.validCurvePack(body) ? body : ({})
    })
  }

  function setCurvePack(pack) {
    if (!Cc.validCurvePack(pack)) return
    curvePack = pack || ({})
    dispatch({ op: "pack-set", body: pack }, function(res) {
      if (!res.ok) fail(res)
    })
  }

  function clearCurvePack() {
    curvePack = ({})
    post({ op: "pack-clear" })
  }

  function consumePackMode(name) {
    var pack = curvePack
    if (!Cc.validCurvePack(pack)) return
    var want = String(name || "").toLowerCase()
    var kept = []
    var modesIn = pack.modes
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
    var next = Cc.copyMap(pack)
    next.modes = kept
    setCurvePack(next)
  }

  function writeUserFile(path, body, done) {
    dispatch({ op: "file-write", path: path, body: body }, function(res) {
      if (done) done(res)
    }, true)
  }

  function readUserFile(path, done) {
    dispatch({ op: "file-read", path: path }, function(res) {
      if (done) done(res)
    }, true)
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
      call("PUT", deviceSettingPath(channel.deviceUid, channel.name, "profile"), { profile_uid: profileUid }, function(res) {
        if (!res.ok) return fail(res)
        step()
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
  function finishApplyBurst(uid, expect, res, done) {
    if (!res || res.ok !== true) {
      fail(res || { ok: false, status: 0, error: "not connected" })
      refresh()
      return
    }
    var results = (res.body && res.body.results) || []
    if (results.length < 3) {
      lastError = "The running curves do not match what was sent."
      notice = lastError
      refresh()
      return
    }
    var profilesRes = results[results.length - 3]
    var modesRes = results[results.length - 2]
    var activeRes = results[results.length - 1]
    if (!profilesRes || !profilesRes.ok || !modesRes || !modesRes.ok || !activeRes || !activeRes.ok) {
      fail((profilesRes && !profilesRes.ok) ? profilesRes : ((modesRes && !modesRes.ok) ? modesRes : activeRes))
      refresh()
      return
    }
    var nextProfiles = (profilesRes.body && profilesRes.body.profiles) || []
    var nextModes = (modesRes.body && modesRes.body.modes) || []
    var mode = Cc.modeByUid(nextModes, uid)
    var reported = activeRes.body && activeRes.body.current_mode_uid
      ? String(activeRes.body.current_mode_uid) : ""
    if (!mode || !Cc.appliedCurvesMatch(mode, nextProfiles, expect)) {
      lastError = "The running curves do not match what was sent."
      notice = lastError
      refresh()
      return
    }
    profiles = nextProfiles
    modes = nextModes
    modesKnown = true
    activeModeUid = reported || String(uid)
    rebuild()
    notice = ""
    lastError = ""
    if (done) done()
  }

  // One connection: owned curves, the mode, any copied shared curves, then
  // a read-back. A match skips the full catalog. A miss reloads the daemon.
  function applyModeCurves(uid, jobs, done) {
    if (!uid) return
    if (calibrationBusy) {
      lastError = "A fan is being calibrated. Apply waits until that sweep finishes."
      notice = lastError
      return
    }
    var split = splitCurveJobs(uid, jobs)
    var steps = []
    var expect = []
    var list = split.own || []
    var i
    for (i = 0; i < list.length; i++) {
      var job = list[i]
      if (!job || Cc.otherModeUsesProfile(modes, job.profileUid, uid)) continue
      var profile = Cc.profileByUid(profiles, job.profileUid)
      if (!profile) {
        lastError = "That curve is not a saved profile"
        notice = lastError
        return
      }
      var next = Cc.withGraphPoints(profile, job.points, job.minDuty)
      steps.push({ method: "PUT", path: "/profiles", body: next })
      expect.push({ profileUid: String(next.uid || job.profileUid), points: next.speed_profile })
    }
    steps.push({ method: "POST", path: "/modes-active/" + encodeURIComponent(uid), body: {} })
    var shared = []
    var seen = ({})
    var raw = split.shared || []
    for (i = 0; i < raw.length; i++) {
      var item = raw[i]
      if (!item || !item.profileUid || seen[item.profileUid]) continue
      seen[item.profileUid] = true
      shared.push(item)
    }
    var mode = Cc.modeByUid(modes, uid)
    var modeName = mode && mode.name ? mode.name : "Mode"
    var known = ({})
    var live = channels || []
    for (i = 0; i < live.length; i++) if (live[i] && live[i].key) known[live[i].key] = true
    var cloned = false
    for (i = 0; i < shared.length; i++) {
      var sharedJob = shared[i]
      var sharedProfile = Cc.profileByUid(profiles, sharedJob.profileUid)
      if (!sharedProfile) {
        lastError = "That curve is not a saved profile"
        notice = lastError
        return
      }
      var stored = Cc.modeProfileChannels(mode, sharedJob.profileUid)
      var present = []
      var c
      for (c = 0; c < stored.length; c++) {
        var one = stored[c]
        if (!one || !one.deviceUid || !one.name) continue
        if (!known[String(one.deviceUid) + "/" + String(one.name)]) continue
        present.push(one)
      }
      if (!present.length) continue
      var draft = JSON.parse(JSON.stringify(sharedProfile))
      var cloneUid = newUid()
      draft.uid = cloneUid
      var copyName = (modeName + " " + (sharedProfile.name || "curve") + " " + cloneUid.slice(0, 4)).replace(/\s+/g, " ")
      draft.name = String(copyName).slice(0, 48)
      var shaped = Cc.withGraphPoints(draft, sharedJob.points, sharedJob.minDuty)
      shaped.uid = cloneUid
      steps.push({ method: "POST", path: "/profiles", body: shaped })
      expect.push({ profileUid: cloneUid, points: shaped.speed_profile, channels: present })
      for (c = 0; c < present.length; c++) {
        steps.push({
          method: "PUT",
          path: deviceSettingPath(present[c].deviceUid, present[c].name, "profile"),
          body: { profile_uid: cloneUid }
        })
      }
      cloned = true
    }
    if (cloned)
      steps.push({ method: "PUT", path: "/modes/" + encodeURIComponent(uid) + "/settings", body: {} })
    steps.push({ method: "GET", path: "/profiles", body: null })
    steps.push({ method: "GET", path: "/modes", body: null })
    steps.push({ method: "GET", path: "/modes-active", body: null })
    var token = track(function(res) { root.finishApplyBurst(uid, expect, res, done) })
    if (!send({ op: "burst", id: token, steps: steps })) {
      dropPending(token)
      fail({ ok: false, status: 0, error: "not connected" })
    }
  }

  function takeCalibrationList(res) {
    if (!res || !res.ok) {
      if (res && Number(res.status) === 404) {
        calibrations = []
        return
      }
      if (res) fail(res)
      return
    }
    calibrations = (res.body && res.body.calibrations) || []
  }

  function loadCalibrations() {
    call("GET", "/calibrations", null, function(res) { root.takeCalibrationList(res) })
  }

  // GET /calibrations/batch is JSON null when this daemon has never swept.
  // A start that just returned 202 can beat the first read, so a few empty
  // replies keep the queued card instead of dropping the sweep.
  function takeCalibrationBatch(res) {
    if (!res || !res.ok) {
      if (res && Number(res.status) === 404) {
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
      if (res) fail(res)
      return
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
      var failed = ""
      var doneEntries = next.entries || []
      for (i = 0; i < doneEntries.length; i++) {
        var line = Calib.failureLine(doneEntries[i])
        if (line) {
          failed = line
          break
        }
      }
      notice = failed || "Calibration finished"
    }
  }

  function loadCalibrationBatch() {
    call("GET", "/calibrations/batch", null, function(res) { root.takeCalibrationBatch(res) })
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
    return seconds === 0 || seconds === 2 || seconds === 5 || seconds === 10 || seconds === 30 || seconds === 60
  }

  function msUntilNextMinute() {
    var now = new Date()
    var wait = (60 - now.getSeconds()) * 1000 - now.getMilliseconds() + 250
    if (wait < 1000) wait = wait + 60000
    return wait
  }

  function lcdFaceKnown(face) {
    return face === "liquid" || face === "cpu" || face === "cpu-gpu" || face === "cpu-liquid" || face === "omarchy" || face === "omarchy-time" || face === "picture"
  }

  // An empty or half-written file is the truncate window of the same inode.
  // Keep the face already shown. A later complete write still replaces it.
  function readLcdFace(raw) {
    var text = String(raw || "").replace(/^\s+|\s+$/g, "")
    if (!text) return
    var obj
    try {
      obj = JSON.parse(text)
    } catch (e) {
      return
    }
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) return
    if (obj.face) {
      var face = String(obj.face)
      // An unknown face stays where it is. Substituting Liquid is what
      // painted over a face this build does not know.
      if (lcdFaceKnown(face)) {
        lcdFace = face
        if (face === "omarchy-time") lcdClockWait = msUntilNextMinute()
      }
    }
    if (obj.picture !== undefined) lcdPicture = String(obj.picture || "")
    if (obj.live !== undefined) lcdLive = obj.live === true
  }

  function lcdNote(res) {
    return plainError(res && res.error, "The LCD was not changed.")
  }

  // Saves the face and shows it. "off" leaves the saved face and blanks the screen.
  // The helper writes the view, then uploads, so a deck key does not depend on
  // the window being open.
  function showLcd(face) {
    var id = String(face || "")
    if (stopping || connection !== "ready") return "coolercontrold is not connected."
    var screen = lcdChannels && lcdChannels.length ? lcdChannels[0] : null
    if (!screen || !screen.deviceUid || !screen.name) return "No AIO LCD."
    if (id === "picture") {
      if (!screen.hasImage) return "This cooler has no picture mode."
      if (!String(lcdPicture || "")) return "No picture is saved."
    } else if (id !== "off" && !lcdFaceKnown(id)) return "Unknown LCD face."
    var msg = fillLcd({
      op: "lcd-face",
      face: id
    }, screen, id === "omarchy-time" ? 60 : lcdSeconds)
    var prevFace = lcdFace
    var prevLive = lcdLive
    var prevPicture = lcdPicture
    var token = track(function(res) {
      if (res && res.ok === false) {
        root.lastError = root.lcdNote(res)
        root.lcdFace = prevFace
        root.lcdLive = prevLive
        root.lcdPicture = prevPicture
        if (prevFace === "omarchy-time") root.lcdClockWait = root.msUntilNextMinute()
      } else if (res && res.ok) root.lastError = ""
    })
    msg.id = token
    if (!send(msg)) {
      dropPending(token)
      return "coolercontrold is not connected."
    }
    if (id === "off") lcdLive = false
    else {
      lcdFace = id
      lcdLive = true
      if (id === "omarchy-time") lcdClockWait = msUntilNextMinute()
    }
    return "ok"
  }

  function themeLcd() {
    if (stopping || !lcdBackground || lcdFace !== "omarchy" || !lcdThemeSync) return
    if (connection !== "ready") return
    themeLcdDelay.restart()
  }

  function previewLcd(deviceName, width, height, face, accent, done, picture, scale) {
    dispatch({
      op: "lcd-preview",
      deviceName: String(deviceName || ""),
      width: Math.max(0, Math.round(Number(width) || 0)),
      height: Math.max(0, Math.round(Number(height) || 0)),
      face: String(face || "omarchy"),
      accent: String(accent || ""),
      picture: String(picture || ""),
      scale: Math.max(50, Math.min(300, Math.round(Number(scale) || 100)))
    }, function(res) {
      if (done) done(res)
    }, true)
  }

  function pushLcdImage(deviceUid, channel, brightness, face, angle, accent, accent2, tempText, temp2, shape, width, height, deviceName, done, picture, scale) {
    if (!deviceUid || !channel) return
    var id = track(function(res) {
      if (!res.ok) fail(res)
      else notice = ""
      if (done) done(res)
    })
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
      deviceName: String(deviceName || ""),
      picture: String(picture || ""),
      scale: Math.max(50, Math.min(300, Math.round(Number(scale) || 100)))
    })) {
      dropPending(id)
      if (done) done({ ok: false, status: 0, error: "not connected" })
    }
  }

  function setLcd(deviceUid, channel, lcd) {
    if (!deviceUid || !channel || !lcd) return
    call("PUT", deviceSettingPath(deviceUid, channel, "lcd"), lcd, function(res) {
      if (!res.ok) return fail(res)
      notice = ""
    })
  }

  function loadProcesses() {
    var epoch = processEpoch + 1
    var accepted = dispatch({ op: "processes" }, function(res) {
      if (epoch !== root.processEpoch) return
      if (!res || !res.ok) return
      var body = res.body || ({})
      var cpuTotal = Number(body.cpuTotal)
      var gpuTotal = Number(body.gpuTotal)
      processCpuTotal = isFinite(cpuTotal) ? cpuTotal : 0
      processGpuTotal = isFinite(gpuTotal) ? gpuTotal : 0
      processCpu = body.cpu || []
      processGpuOk = body.gpuOk !== false
      processGpu = body.gpu || []
    })
    if (accepted) processEpoch = epoch
  }

  function sameReading(a, b) {
    if (a === b) return true
    var aEmpty = a === null || a === undefined || a === ""
    var bEmpty = b === null || b === undefined || b === ""
    if (aEmpty || bEmpty) return aEmpty && bEmpty
    var na = Number(a)
    var nb = Number(b)
    if (isFinite(na) && isFinite(nb)) return na === nb
    return String(a) === String(b)
  }

  function liveDiffer(next) {
    var cur = channelLive || ({})
    var fresh = next || ({})
    var key
    for (key in fresh) {
      if (!Object.prototype.hasOwnProperty.call(fresh, key)) continue
      var row = cur[key]
      var got = fresh[key] || ({})
      if (!row || !sameReading(row.duty, got.duty) || !sameReading(row.rpm, got.rpm)) return true
    }
    for (key in cur) {
      if (!Object.prototype.hasOwnProperty.call(cur, key)) continue
      if (!Object.prototype.hasOwnProperty.call(fresh, key)) return true
    }
    return false
  }

  function tempsDiffer(next) {
    var keys = [
      "cpu", "cpuCcd1", "cpuCcd2", "cpuName", "gpu", "gpuPower", "gpuLoad", "gpuName",
      "coolant", "liquidName", "pumpDuty", "pumpRpm", "hottest"
    ]
    var cur = temps || ({})
    var got = next || ({})
    var i
    for (i = 0; i < keys.length; i++) {
      if (!sameReading(cur[keys[i]], got[keys[i]])) return true
    }
    return false
  }

  // A refused login is not a blip. Everything else keeps the last temperatures
  // for a few seconds while the stream comes back.
  function cancelHold() {
    streamHold = false
    heldError = ""
    streamHoldTimer.stop()
  }

  function beginHold(message) {
    var text = plainError(message, "coolercontrold is not running")
    if (streamHold) {
      heldError = text
      return
    }
    if (connection !== "ready") {
      connection = "down"
      transportError = true
      lcdKeepBusy = false
      calibrationAwait = false
      calibrationMiss = 0
      lastError = text
      return
    }
    heldError = text
    streamHold = true
    streamHoldTimer.restart()
  }

  function releaseHold() {
    var text = heldError
    streamHold = false
    heldError = ""
    connection = "down"
    transportError = true
    lcdKeepBusy = false
    calibrationAwait = false
    calibrationMiss = 0
    lastError = plainError(text, "coolercontrold is not running")
  }

  function takeStatus(body) {
    var next = body && body.devices
    if (next && next.length) statusDevices = next
    lastStatusMs = Date.now()
    cancelHold()
    noteReady()
    if (!channels || !channels.length) {
      rebuild()
      return
    }
    var patch = Cc.statusPatch(devices, statusDevices, channels)
    if (!patch || patch.shapeChanged) {
      rebuild()
      return
    }
    if (liveDiffer(patch.live)) {
      channelLive = patch.live
      channelLiveSig = ""
    }
    if (tempsDiffer(patch.temps)) {
      temps = patch.temps
      tempsSig = ""
    }
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
      sawHello = true
      var keepView = streamHold || connection === "ready"
      cancelHold()
      restartDelayMs = 2000
      if (!msg.token) connection = "need-token"
      else if (!keepView) connection = "down"
      loadUi()
      loadPack()
      if (msg.token) {
        skipNextUp = true
        refresh()
      } else lastError = "Pair coolercontrold with ~/.config/omaflow/coolercontrol.token"
      return
    }
    if (msg.event === "up") {
      if (connection === "unauthorized" || connection === "need-token") return
      cancelHold()
      // Status events do not carry devices, modes, or profiles.
      if (skipNextUp) {
        skipNextUp = false
        if (catalogBusy) catalogIfStale = true
        else if (!(connection === "ready" && modesKnown)) refresh()
        return
      }
      if (catalogBusy || catalogAgain) {
        catalogAgain = true
        return
      }
      refresh()
      return
    }
    if (msg.event === "down") {
      if (msg.error === "need-token" || msg.status === 401 || msg.status === 403 || msg.status === 429)
        fail(msg)
      else
        beginHold(msg.error)
      return
    }
    if (msg.event === "status") {
      takeStatus(msg.body)
      return
    }
    if (msg.event === "mode" || msg.event === "modes") {
      var body = msg.body || {}
      if (body.uid) activeModeUid = String(body.uid)
      else if (body.current_mode_uid) activeModeUid = String(body.current_mode_uid)
      rebuild()
      return
    }
    if (msg.event === "alert" || msg.event === "alerts") {
      refreshAlerts()
      return
    }
    if (msg.id === undefined || msg.id === null) return
    var done = pending[msg.id]
    dropPending(msg.id)
    if (done) done(msg)
  }

  Timer {
    interval: 2000
    repeat: true
    triggeredOnStart: true
    running: root.watchProcesses && !root.stopping
    onTriggered: root.loadProcesses()
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
    onRunningChanged: {
      if (!client.running) return
      root.clientStartedMs = Date.now()
      root.sawHello = false
      root.lastStatusMs = 0
    }
    onExited: function() {
      root.pending = ({})
      root.catalogBusy = false
      root.catalogAgain = false
      root.catalogIfStale = false
      root.skipNextUp = false
      root.sawHello = false
      root.lcdKeepBusy = false
      if (root.stopping) return
      if (root.connection === "ready" || root.streamHold)
        root.beginHold("coolercontrold is not running")
      else {
        root.connection = "down"
        root.calibrationAwait = false
        root.calibrationMiss = 0
      }
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
  // pkexec is what shows the password dialog from the panel. The package is
  // AUR-only, so the command is `omarchy pkg aur add coolercontrold`.
  // pkexec is root, and yay will not build as root, so the shell puts the
  // approving account in SUDO_USER and HOME before that command runs.
  Process {
    id: daemonInstall
    command: [
      "pkexec", "/usr/bin/bash", "-c",
      "uid=${PKEXEC_UID:-}; user=$(id -nu \"$uid\"); home=$(getent passwd \"$user\" | cut -d: -f6); [[ -n $user && -d $home ]] || { echo 'Could not identify the account that approved the prompt.' >&2; exit 1; }; export SUDO_USER=$user HOME=$home USER=$user LOGNAME=$user; cd \"$home\" && exec /usr/share/omarchy/bin/omarchy pkg aur add coolercontrold"
    ]
    stderr: SplitParser {
      onRead: function(line) { root.daemonNote = String(line || "") }
    }
    onExited: function(code) {
      root.finishDaemonAction(code, "Omaflow could not install coolercontrold. In a terminal: omarchy pkg aur add coolercontrold")
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

  // The password stays in the polkit dialog. This command does no work.
  Process {
    id: floorConfirm
    command: ["pkexec", "/usr/bin/true"]
    onExited: function(code) { root.finishPumpFloorOff(code) }
  }

  // plugin add never runs ./install. The enabled checkout publishes the
  // launcher once it loads, and again when its commit changes. A source
  // tree and the ~/.local copy exit without copying.
  Process {
    id: windowPublish
    command: ["bash", Repo.rootFile("scripts/ensure_window.sh")]
    onExited: function(code) {
      if (code !== 0) console.warn("omaflow: window launcher was not installed")
    }
  }

  Component.onCompleted: windowPublish.running = true

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
    running: !root.stopping && root.lcdBackground && root.connection === "ready" && root.lcdChannels.length > 0 && root.lcdFace !== "picture" && root.lcdSeconds !== 0 && !(root.lcdFace === "omarchy" && root.lcdThemeSync)
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
    running: !root.stopping && root.connection === "ready" && !root.streamHold && root.calibrationBusy
    onTriggered: root.loadCalibrationBatch()
  }

  // Hello has to show up, and a live stream has to keep sending status.
  // Killing the helper is the recovery. onExited backs off and starts again.
  Timer {
    id: streamWatch
    interval: 2000
    repeat: true
    running: !root.stopping && client.running
    onTriggered: {
      if (root.stopping || !client.running) return
      var now = Date.now()
      if (!root.sawHello && root.clientStartedMs && (now - root.clientStartedMs) > 8000) {
        client.running = false
        return
      }
      if (root.streamHold || !root.sawHello || root.connection !== "ready") return
      var stamp = root.lastStatusMs || root.clientStartedMs
      if (stamp && (now - stamp) > 8000)
        client.running = false
    }
  }

  Timer {
    id: streamHoldTimer
    interval: 3000
    repeat: false
    onTriggered: root.releaseHold()
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
