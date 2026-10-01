import QtQuick
import qs.Commons
import qs.Ui
import "CcMap.js" as Cc
import "Nav.js" as Nav

// Modes page. One curve for the selected fan. Edits stay on that fan's
// profile when another fan is selected. Apply writes them and runs the mode.
// Undo and redo walk those edits. Reset restores an imported curve, or the
// curve this mode already has. A shared group keeps the switch; the original
// fan row is grey and has none.
Column {
  id: root

  property var service: null
  property bool fill: false
  property int viewHeight: 0
  property color fg: Color.foreground
  property color accent: Color.accent
  property color line: Qt.rgba(fg.r, fg.g, fg.b, 0.16)
  property color muted: Qt.darker(fg, 1.4)
  property string fontFamily: Style.font.family

  property string modeUid: ""
  property string memberKey: ""
  property var picked: ({})
  property string groupName: ""
  property string modeName: ""
  property bool keyed: false
  property int navIndex: 0
  property var drafts: ({})
  property var curveHistory: ({})
  property string renamingId: ""
  property string renameText: ""

  width: parent ? parent.width : 0
  spacing: Style.space(10)
  visible: true

  readonly property var modeList: service && service.modes ? service.modes : []
  readonly property var customModes: {
    var out = []
    for (var i = 0; i < modeList.length; i++) {
      if (isFactoryMode(modeList[i])) continue
      out.push(modeList[i])
    }
    return out
  }
  readonly property var listedGroups: {
    var saved = service && service.groups ? service.groups : []
    var present = ({})
    var list = service && service.channels ? service.channels : []
    for (var i = 0; i < list.length; i++) present[list[i].key] = true
    var out = []
    for (var g = 0; g < saved.length; g++) {
      var members = saved[g].members || []
      var live = false
      for (var m = 0; m < members.length; m++) if (present[members[m]]) live = true
      if (live) out.push(saved[g])
    }
    return out
  }
  readonly property var mode: {
    for (var i = 0; i < modeList.length; i++) if (modeList[i].uid === modeUid) return modeList[i]
    return null
  }
  readonly property var members: mode ? Cc.modeMembers(mode, service.channels, service.profiles) : []
  readonly property var memberKeys: {
    var keys = []
    for (var i = 0; i < members.length; i++) keys.push(members[i].key)
    return keys
  }
  readonly property var spinning: service ? Cc.spinningChannels(service.channels, memberKeys) : []
  readonly property var rows: {
    var out = []
    var i
    for (i = 0; i < members.length; i++) {
      var row = ({})
      var src = members[i]
      for (var k in src) row[k] = src[k]
      row.inMode = true
      out.push(row)
    }
    for (i = 0; i < spinning.length; i++) {
      var ch = spinning[i]
      out.push({
        key: ch.key,
        deviceUid: ch.deviceUid,
        name: ch.name,
        label: ch.label,
        deviceName: ch.deviceName,
        rpm: ch.rpm,
        isPump: ch.isPump,
        deviceType: ch.deviceType || "",
        minDuty: ch.minDuty,
        profileUid: "",
        profileName: "",
        points: [],
        fixed: null,
        inMode: false
      })
    }
    return out
  }
  readonly property var modeGroups: {
    var order = []
    var by = {}
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var uid = row.deviceUid || ""
      if (!by[uid]) {
        by[uid] = { uid: uid, name: row.deviceName || "Device", rows: [] }
        order.push(uid)
      }
      if (row.deviceName) by[uid].name = row.deviceName
      by[uid].rows.push(row)
    }
    var groups = []
    for (var g = 0; g < order.length; g++) {
      var group = by[order[g]]
      group.rows.sort(function(a, b) {
        var ar = Number(a.rpm) > 0 ? 0 : 1
        var br = Number(b.rpm) > 0 ? 0 : 1
        if (ar !== br) return ar - br
        return String(a.label || "").localeCompare(String(b.label || ""))
      })
      groups.push(group)
    }
    groups.sort(function(a, b) { return String(a.name).localeCompare(String(b.name)) })
    return groups
  }
  readonly property var boardGroups: {
    var out = []
    var saved = service && service.groups ? service.groups : []
    for (var s = 0; s < saved.length; s++) {
      var group = saved[s]
      var keys = group.members || []
      var sharedRows = []
      for (var m = 0; m < keys.length; m++) {
        var found = rowByKey(keys[m])
        if (!found) continue
        var copy = ({})
        for (var k in found) copy[k] = found[k]
        copy.sharedHost = true
        sharedRows.push(copy)
      }
      if (!sharedRows.length) continue
      out.push({ kind: "shared", uid: group.id, name: group.name || "Shared", rows: sharedRows })
    }
    for (var g = 0; g < modeGroups.length; g++) {
      out.push({ kind: "device", uid: modeGroups[g].uid, name: modeGroups[g].name, rows: modeGroups[g].rows })
    }
    for (var n = 0; n < out.length; n++) out[n].order = n
    out.sort(function(a, b) {
      var ah = cardConcealed(a) ? 1 : 0
      var bh = cardConcealed(b) ? 1 : 0
      if (ah !== bh) return ah - bh
      return a.order - b.order
    })
    return out
  }
  property var stableBoard: []
  readonly property string boardSig: {
    var parts = []
    var saved = service && service.groups ? service.groups : []
    var s
    for (s = 0; s < saved.length; s++) {
      var group = saved[s]
      parts.push("g" + (group.id || "") + "=" + (group.name || "") + ":" + (group.members || []).join(","))
    }
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      parts.push([
        row.key || "",
        row.inMode ? "1" : "0",
        row.label || "",
        row.deviceName || "",
        row.deviceUid || "",
        row.isPump ? "p" : "f",
        row.deviceType || "",
        row.profileUid || ""
      ].join("~"))
    }
    var hidden = service && service.hiddenDevices ? service.hiddenDevices : ({})
    var hiddenKeys = []
    for (var hk in hidden) if (hidden[hk] === true) hiddenKeys.push(hk)
    hiddenKeys.sort()
    parts.push("h:" + hiddenKeys.join(","))
    return parts.join("|")
  }
  readonly property int slotRows: {
    var max = 1
    for (var i = 0; i < boardGroups.length; i++) {
      var n = boardGroups[i].rows ? boardGroups[i].rows.length : 0
      var lines = Math.max(1, Math.ceil(n / 2))
      if (lines > max) max = lines
    }
    return max
  }
  readonly property int fanRowH: Style.space(40)
  // nf-md-link_variant U+F0339, nf-md-link_variant_off U+F033A
  readonly property string linkOn: "\uDB80\uDF39"
  readonly property string linkOff: "\uDB80\uDF3A"
  // nf-md-eye_off_outline U+F06D1
  readonly property string eyeOff: "\uDB81\uDED1"
  // nf-md-trash_can_outline U+F0A7A
  readonly property string trash: "\uDB82\uDE7A"
  // nf-md-undo U+F054C, nf-md-redo U+F044E
  readonly property string undoGlyph: "\uDB81\uDD4C"
  readonly property string redoGlyph: "\uDB81\uDC4E"
  readonly property var curveToolModel: [
    { kind: "undo" },
    { kind: "redo" },
    { kind: "reset" }
  ]
  readonly property var pickList: {
    var open = []
    var used = []
    var list = members || []
    for (var i = 0; i < list.length; i++) {
      if (groupedKey(list[i].key)) used.push(list[i])
      else open.push(list[i])
    }
    return open.concat(used)
  }
  readonly property var linkMap: service && service.links ? service.links : ({})
  readonly property int cardH: Style.space(12) + Style.space(22) + Style.space(8)
    + slotRows * fanRowH
    + Math.max(0, slotRows - 1) * Style.space(4)
    + Style.space(10)
  readonly property var navItems: {
    var out = []
    var i
    for (i = 0; i < modeList.length; i++) out.push({ kind: "mode", uid: modeList[i].uid, x: i, y: 0 })
    if (mode) out.push({ kind: "apply", x: modeList.length, y: 0 })
    var cols = columnCount(width)
    for (var g = 0; g < boardGroups.length; g++) {
      var list = boardGroups[g].rows || []
      var cardCol = g % cols
      var cardRow = Math.floor(g / cols)
      for (var r = 0; r < list.length; r++) {
        if (boardGroups[g].kind === "device" && sharedFor(list[r].key)) continue
        out.push({
          kind: "channel",
          key: list[r].key,
          x: cardCol * 2 + (r % 2),
          y: 1 + cardRow * (slotRows + 1) + Math.floor(r / 2)
        })
      }
      out.push({
        kind: "link",
        uid: boardGroups[g].uid,
        x: cardCol * 2 + 1.5,
        y: 1 + cardRow * (slotRows + 1)
      })
    }
    var saved = listedGroups
    for (var s = 0; s < saved.length; s++) out.push({ kind: "drop-group", id: saved[s].id, x: s, y: 40 })
    for (var n = 0; n < customModes.length; n++) out.push({ kind: "drop-mode", uid: customModes[n].uid, x: n, y: 41 })
    if (graphLive && graphHistKey) {
      out.push({ kind: "undo", x: 0, y: 36 })
      out.push({ kind: "redo", x: 1, y: 36 })
      out.push({ kind: "reset", x: 2, y: 36 })
    }
    return out
  }
  readonly property var selected: rowByKey(memberKey)
  readonly property var graphSubject: graphRow()
  readonly property var selectedGroup: {
    if (!selected || !selected.inMode || !service) return null
    var groups = service.groups || []
    for (var i = 0; i < groups.length; i++) {
      var list = groups[i].members || []
      for (var m = 0; m < list.length; m++) if (list[m] === selected.key) return groups[i]
    }
    return null
  }
  readonly property var graphPoints: {
    var row = graphSubject
    if (!row) return []
    var pts = pointsFor(row)
    if (pts && pts.length > 1) return pts
    if (row.fixed !== null && row.fixed !== undefined)
      return Cc.spreadPoints([[0, row.fixed], [100, row.fixed]], graphFloor())
    return []
  }
  readonly property bool graphLive: graphPoints.length > 1
  // Profiles this graph writes, under this mode. A linked card is one stack,
  // and Fixed's edits stay off Hell even when they still share a profile uid.
  readonly property string graphHistKey: {
    if (!mode || !mode.uid) return ""
    var row = graphSubject
    if (!row) return ""
    var ids = []
    var seen = ({})
    var card = cardFor(row.key)
    if (!row.isPump && card && cardLinked(card)) {
      var list = card.rows || []
      var i
      for (i = 0; i < list.length; i++) {
        var item = list[i]
        if (!fanInCard(card, item)) continue
        var uid = profileUidFor(item)
        if (!uid || seen[uid]) continue
        seen[uid] = true
        ids.push(uid)
      }
    }
    if (!ids.length) {
      var one = profileUidFor(row)
      if (one) ids.push(one)
    }
    if (!ids.length) return ""
    ids.sort()
    return mode.uid + "\n" + ids.join("\n")
  }
  readonly property bool canUndo: {
    var entry = graphHistKey ? curveHistory[graphHistKey] : null
    return !!(entry && entry.steps && entry.index > 0)
  }
  readonly property bool canRedo: {
    var entry = graphHistKey ? curveHistory[graphHistKey] : null
    return !!(entry && entry.steps && entry.index < entry.steps.length - 1)
  }
  readonly property bool canReset: {
    if (!graphLive || !graphHistKey) return false
    var base = baselinePoints()
    if (!base || base.length < 2) return false
    return !Cc.samePointList(graphPoints, base)
  }
  readonly property int modeH: Style.space(32)
  readonly property int applyWidth: modeH + Style.space(20)
  readonly property bool modeApplied: mode && service && mode.uid === service.activeModeUid
  readonly property int modeSlot: {
    var count = modeList.length
    if (!count) return Style.space(72)
    var gaps = Style.space(6) * Math.max(0, count - 1)
    return Math.max(Style.space(64), Math.floor((width - applyWidth - gaps) / count))
  }

  function rowByKey(key) {
    for (var i = 0; i < rows.length; i++) if (rows[i].key === key) return rows[i]
    return null
  }

  function chipText(row) {
    if (!row) return ""
    return row.label || row.name || ""
  }

  function liveChannel(key) {
    var list = service && service.channels ? service.channels : []
    for (var i = 0; i < list.length; i++) if (list[i].key === key) return list[i]
    return null
  }

  function rpmText(row) {
    var live = row ? liveChannel(row.key) : null
    var rpm = Number(live ? live.rpm : (row && row.rpm))
    return isFinite(rpm) ? Math.round(rpm) + " rpm" : ""
  }

  function deviceKind(row) {
    if (!row) return ""
    var live = liveChannel(row.key)
    if (live && live.deviceType) return live.deviceType
    return row.deviceType || ""
  }

  function tempNow(row) {
    if (!service || !row || !service.temps) return -1
    var temps = service.temps
    if (deviceKind(row) === "GPU" && isFinite(Number(temps.gpu))) return Number(temps.gpu)
    return isFinite(Number(temps.cpu)) ? Number(temps.cpu) : -1
  }

  function sourceFor(list) {
    var gpu = list && list.length > 0
    for (var i = 0; i < (list || []).length; i++) {
      if (!list[i] || deviceKind(list[i]) !== "GPU") gpu = false
    }
    return Cc.tempSourceFor(service.devices, gpu ? "GPU" : "CPU")
  }

  function ensureMode() {
    if (modeUid && mode) return
    if (service && service.activeModeUid) modeUid = service.activeModeUid
    else if (modeList.length) modeUid = modeList[0].uid
  }

  function selectRow(key) {
    memberKey = key
  }

  function groupedKey(key) {
    var groups = service && service.groups ? service.groups : []
    for (var i = 0; i < groups.length; i++) {
      var list = groups[i].members || []
      for (var m = 0; m < list.length; m++) if (list[m] === key) return true
    }
    return false
  }

  function togglePick(key) {
    if (groupedKey(key)) return
    var next = ({})
    for (var k in picked) next[k] = picked[k]
    next[key] = !next[key]
    picked = next
  }

  function pickedMembers() {
    var out = []
    for (var i = 0; i < members.length; i++) if (picked[members[i].key]) out.push(members[i])
    return out
  }

  function addChannel(channel) {
    if (!service || !mode) return
    var temp = sourceFor([channel])
    var points = Cc.defaultPoints(channel.isPump)
    service.createGraph(channel.label, points, temp, channel.minDuty, function(uid) {
      service.bindChannel(mode.uid, channel.deviceUid, channel.name, uid, function() {
        selectRow(channel.key)
      })
    })
  }

  function toggleChannel(row) {
    if (!service || !mode || !row) return
    if (sharedFor(row.key)) return
    if (row.inMode) service.resetChannel(mode.uid, row.deviceUid, row.name, row.key)
    else addChannel(row)
  }

  function toggleGrouped(row) {
    if (!service || !mode || !row) return
    var group = sharedFor(row.key)
    if (!group) {
      toggleChannel(row)
      return
    }
    if (row.inMode) {
      service.releaseChannel(mode.uid, row.deviceUid, row.name)
      return
    }
    var uid = group.profileUid || ""
    if (!uid) {
      ensureSharedCurve(group, row)
      return
    }
    service.bindChannel(mode.uid, row.deviceUid, row.name, uid, function() {
      selectRow(row.key)
    })
  }

  function ensureSharedCurve(group, row) {
    if (!service || !group) return
    var chosen = []
    var keys = group.members || []
    for (var i = 0; i < keys.length; i++) {
      var found = rowByKey(keys[i])
      if (found) chosen.push(found)
    }
    if (!chosen.length && row) chosen.push(row)
    var floor = 0
    for (var n = 0; n < chosen.length; n++) floor = Math.max(floor, Number(chosen[n].minDuty) || 0)
    var temp = sourceFor(chosen)
    service.createGraph(group.name || "Group", Cc.defaultPoints(floor >= 50), temp, floor, function(uid) {
      var copy = ({})
      for (var k in group) copy[k] = group[k]
      copy.profileUid = uid
      service.rememberGroup(copy)
      if (row && mode) service.bindChannel(mode.uid, row.deviceUid, row.name, uid, function() {
        selectRow(row.key)
      })
    })
  }

  function makeGroup() {
    if (!service || !mode) return
    var chosen = pickedMembers()
    if (chosen.length < 2) {
      service.lastError = "Check at least two channels to group them"
      return
    }
    var name = groupName.replace(/^\s+|\s+$/g, "")
    if (!name) name = "Group"
    var floor = 0
    for (var i = 0; i < chosen.length; i++) floor = Math.max(floor, chosen[i].minDuty || 0)
    var temp = sourceFor(chosen)
    service.createGraph(name, Cc.defaultPoints(floor >= 50), temp, floor, function(uid) {
      var keys = []
      for (var n = 0; n < chosen.length; n++) keys.push(chosen[n].key)
      service.bindMany(mode.uid, chosen, uid, function() {
        service.rememberGroup({ id: service.newUid(), name: name, profileUid: uid, members: keys })
        picked = ({})
        groupName = ""
      })
    })
  }

  function profileUidFor(row) {
    if (!row) return ""
    // The mode's own profile wins. A shared group only fills in when this
    // mode has not assigned one, so another mode's curve is not reused.
    if (row.profileUid) return row.profileUid
    if (!row.inMode) return ""
    var shared = sharedFor(row.key)
    if (shared && shared.profileUid) return shared.profileUid
    return ""
  }

  function rowFloor(row) {
    var floor = row && row.minDuty ? Number(row.minDuty) : 0
    var shared = row ? sharedFor(row.key) : null
    if (!shared) return floor
    var list = shared.members || []
    for (var i = 0; i < members.length; i++) {
      if (list.indexOf(members[i].key) >= 0) floor = Math.max(floor, Number(members[i].minDuty) || 0)
    }
    return floor
  }

  // Drafts stay on this mode. Two modes can store the same CoolerControl
  // profile uid, and a shared key would make Fixed's edit draw on Hell.
  function draftKey(profileUid) {
    if (!mode || !mode.uid || !profileUid) return ""
    return mode.uid + "\n" + profileUid
  }

  function pointsFor(row) {
    var uid = profileUidFor(row)
    var key = draftKey(uid)
    if (key && drafts[key] && drafts[key].length) return drafts[key]
    var packed = Cc.packPoints(
      service && service.curvePack,
      mode && mode.name,
      row && row.deviceName,
      row && row.name
    )
    if (packed && packed.length > 1) return packed
    if (row && row.points && row.points.length) return row.points
    return []
  }

  function rememberDraft(uid, points) {
    var key = draftKey(uid)
    if (!key) return
    var next = ({})
    for (var k in drafts) next[k] = drafts[k]
    var copy = []
    var src = points || []
    var i
    for (i = 0; i < src.length; i++) {
      if (!src[i] || src[i].length < 2) continue
      copy.push([Number(src[i][0]), Number(src[i][1])])
    }
    next[key] = copy
    drafts = next
  }

  function curveJobs() {
    var jobs = []
    var seen = ({})
    for (var i = 0; i < members.length; i++) {
      var row = members[i]
      var uid = profileUidFor(row)
      if (!uid || seen[uid]) continue
      var pts = pointsFor(row)
      if (!pts || pts.length < 2) continue
      seen[uid] = true
      jobs.push({ profileUid: uid, points: pts, minDuty: rowFloor(row) })
    }
    return jobs
  }

  function isFactoryMode(item) {
    var name = String(item && item.name || "").replace(/^\s+|\s+$/g, "").toLowerCase()
    return name === "silent" || name === "performance" || name === "fixed" || name === "hell"
  }

  function removeMode(uid) {
    var target = uid || (mode && mode.uid)
    if (!service || !target) return
    var found = null
    for (var i = 0; i < modeList.length; i++) if (modeList[i].uid === target) found = modeList[i]
    if (isFactoryMode(found)) {
      service.lastError = "Silent, Performance, Fixed, and Hell stay"
      return
    }
    if (target === service.activeModeUid) {
      service.lastError = "The running mode stays"
      return
    }
    service.deleteMode(target, function() {
      if (root.modeUid === target) {
        root.modeUid = root.service && root.service.activeModeUid ? root.service.activeModeUid : ""
        root.ensureMode()
      }
    })
  }

  function applyMode() {
    if (!service || !mode) return
    if (!members.length) {
      service.lastError = mode.name + " has no channels. Add one before applying."
      return
    }
    var jobs = curveJobs()
    var appliedUid = mode.uid
    var appliedName = mode.name
    service.lastError = ""
    service.applyModeCurves(appliedUid, jobs, function() {
      var prefix = appliedUid + "\n"
      var next = ({})
      for (var k in drafts) if (String(k).indexOf(prefix) !== 0) next[k] = drafts[k]
      drafts = next
      var hist = ({})
      for (var h in curveHistory) if (String(h).indexOf(prefix) !== 0) hist[h] = curveHistory[h]
      curveHistory = hist
      if (service.consumePackMode) service.consumePackMode(appliedName)
    })
  }

  function commitRename() {
    var id = renamingId
    var name = renameText
    renamingId = ""
    if (service && id) service.renameGroup(id, name)
  }

  function columnCount(avail) {
    var gap = Style.space(8)
    var minW = Style.space(230)
    var cols = Math.floor((avail + gap) / (minW + gap))
    if (cols < 1) return 1
    if (cols > 3) return 3
    return cols
  }

  function cardWidth(avail) {
    var gap = Style.space(8)
    var cols = columnCount(avail)
    return Math.max(1, Math.floor((avail - gap * (cols - 1)) / cols))
  }

  function fanCaption(row) {
    if (!row) return ""
    var bits = [chipText(row)]
    var now = tempNow(row)
    if (isFinite(now) && now >= 0) bits.push(Math.round(now) + "°")
    if (row.isPump) bits.push("floor 50%")
    var rpmLabel = rpmText(row)
    if (rpmLabel) bits.push(rpmLabel)
    return bits.join("  ·  ")
  }

  function navAt() {
    return navItems.length ? navItems[Math.max(0, Math.min(navItems.length - 1, navIndex))] : null
  }

  function moveNav(dx, dy) {
    navIndex = Nav.step(navItems, navIndex, dx, dy)
  }

  function activateNav() {
    var item = navAt()
    if (!item) return
    if (item.kind === "mode") {
      modeUid = item.uid
      picked = ({})
    } else if (item.kind === "channel") {
      selectRow(item.key)
    } else if (item.kind === "link") {
      toggleLink(item.uid)
    } else if (item.kind === "apply") {
      applyMode()
    } else if (item.kind === "drop-group") {
      if (service) service.forgetGroup(item.id)
    } else if (item.kind === "drop-mode") {
      removeMode(item.uid)
    } else if (item.kind === "undo" || item.kind === "redo" || item.kind === "reset") {
      useCurveTool(item.kind)
    }
  }

  function takeEscape() {
    if (!renamingId) return false
    renamingId = ""
    return true
  }

  function aimMode(uid) {
    var item = navAt()
    return keyed && item && item.kind === "mode" && item.uid === uid
  }

  function aimChannel(key) {
    var item = navAt()
    return keyed && item && item.kind === "channel" && item.key === key
  }

  function aimLink(uid) {
    var item = navAt()
    return keyed && item && item.kind === "link" && item.uid === uid
  }

  function isGpuCard(card) {
    if (!card) return false
    var rows = card.rows || []
    var fans = 0
    var gpu = 0
    for (var i = 0; i < rows.length; i++) {
      if (!rows[i] || rows[i].isPump) continue
      fans++
      if (deviceKind(rows[i]) === "GPU") gpu++
    }
    if (fans > 0 && gpu === fans) return true
    return fans > 0 && /nvidia|geforce/i.test(String(card.name || ""))
  }

  // Shared groups and GPU fans start linked. A stored flag wins.
  // The pump is never part of that shared curve.
  function deviceConcealed(uid) {
    var map = service && service.hiddenDevices ? service.hiddenDevices : null
    return !!(map && map[uid] === true)
  }

  // A device card hides with that device. A group hides when every fan in it
  // belongs to a hidden device, which covers a group of one.
  function cardConcealed(card) {
    if (!card) return false
    var rows = card.rows || []
    if (!rows.length) return false
    var seen = false
    for (var i = 0; i < rows.length; i++) {
      var uid = rows[i] && rows[i].deviceUid
      if (!uid) continue
      seen = true
      if (!deviceConcealed(uid)) return false
    }
    return seen
  }

  function revealCard(card) {
    if (!service || !card) return
    var rows = card.rows || []
    var seen = ({})
    for (var i = 0; i < rows.length; i++) {
      var uid = rows[i] && rows[i].deviceUid
      if (!uid || seen[uid] || !deviceConcealed(uid)) continue
      seen[uid] = true
      service.setDeviceHidden(uid, false)
    }
  }

  function cardLinked(card) {
    if (!card) return false
    var stored = linkMap ? linkMap[card.uid] : undefined
    if (stored === true || stored === false) return stored === true
    if (card.kind === "shared") return true
    return isGpuCard(card)
  }

  function cardFor(key) {
    if (!key) return null
    var shared = sharedFor(key)
    var board = boardGroups
    var i
    var r
    if (shared) {
      for (i = 0; i < board.length; i++) {
        if (board[i].kind === "shared" && board[i].uid === shared.id) return board[i]
      }
    }
    for (i = 0; i < board.length; i++) {
      if (board[i].kind !== "device") continue
      var list = board[i].rows || []
      for (r = 0; r < list.length; r++) if (list[r].key === key) return board[i]
    }
    return null
  }

  function fanInCard(card, row) {
    if (!card || !row || row.isPump) return false
    if (card.kind === "device" && sharedFor(row.key)) return false
    var list = card.rows || []
    for (var i = 0; i < list.length; i++) if (list[i].key === row.key) return true
    return false
  }

  function graphRow() {
    var row = selected
    if (!row) return null
    if (row.isPump) return row
    var card = cardFor(row.key)
    if (!card || !cardLinked(card)) return row
    var list = card.rows || []
    var leader = null
    for (var i = 0; i < list.length; i++) {
      var item = list[i]
      if (!fanInCard(card, item)) continue
      if (!leader) leader = item
      if (item.inMode && item.profileUid) return item
    }
    return leader || row
  }

  function graphFloor() {
    var row = graphRow()
    if (!row) return 0
    if (row.isPump) return Number(row.minDuty) || 0
    var card = cardFor(row.key)
    if (!card || !cardLinked(card)) return Number(row.minDuty) || 0
    var floor = 0
    var list = card.rows || []
    for (var i = 0; i < list.length; i++) {
      if (!fanInCard(card, list[i])) continue
      floor = Math.max(floor, Number(list[i].minDuty) || 0)
    }
    return floor
  }

  function toggleLink(uid) {
    if (!service || !uid) return
    var card = null
    var board = boardGroups
    for (var i = 0; i < board.length; i++) if (board[i].uid === uid) card = board[i]
    if (!card) return
    service.setCardLink(uid, !cardLinked(card))
  }

  // Imported points win. Otherwise the curve saved on this mode, then the
  // built-in fan or pump curve. Reset does not write coolercontrold.
  function baselinePoints() {
    var row = graphSubject
    if (!row) return []
    var packed = Cc.packPoints(
      service && service.curvePack,
      mode && mode.name,
      row.deviceName,
      row.name
    )
    if (packed && packed.length > 1) return packed
    if (row.points && row.points.length > 1) return row.points
    return Cc.defaultPoints(!!row.isPump)
  }

  function noteGraphEdit(points) {
    var key = graphHistKey
    if (!key) return false
    var entry = Cc.pushCurveHistory(curveHistory[key], graphPoints, points, 40)
    if (!entry) return false
    var next = ({})
    for (var k in curveHistory) next[k] = curveHistory[k]
    next[key] = entry
    curveHistory = next
    return true
  }

  function writeGraphDrafts(points) {
    var key = graphHistKey
    if (!key) return
    var parts = key.split("\n")
    var i
    for (i = 1; i < parts.length; i++) if (parts[i]) rememberDraft(parts[i], points)
  }

  function moveGraphHistory(dir) {
    var key = graphHistKey
    var entry = key && curveHistory[key]
    if (!entry || !entry.steps) return
    var index = (Number(entry.index) || 0) + dir
    if (index < 0 || index >= entry.steps.length) return
    var next = ({})
    for (var k in curveHistory) next[k] = curveHistory[k]
    next[key] = { steps: entry.steps, index: index }
    curveHistory = next
    writeGraphDrafts(entry.steps[index])
  }

  function undoGraph() {
    moveGraphHistory(-1)
  }

  function redoGraph() {
    moveGraphHistory(1)
  }

  function resetGraph() {
    if (!canReset) return
    var base = baselinePoints()
    if (!noteGraphEdit(base)) return
    writeGraphDrafts(base)
  }

  function useCurveTool(kind) {
    if (kind === "undo") undoGraph()
    else if (kind === "redo") redoGraph()
    else if (kind === "reset") resetGraph()
  }

  function curveToolTip(kind) {
    if (kind === "undo") return "Undo the last change to this curve"
    if (kind === "redo") return "Redo the curve change"
    return "Restore the imported curve, or the curve this mode already has"
  }

  function storeGraph(points) {
    if (!noteGraphEdit(points)) return
    writeGraphDrafts(points)
  }

  readonly property var sharedKeys: {
    var out = ({})
    var groups = service && service.groups ? service.groups : []
    for (var i = 0; i < groups.length; i++) {
      var list = groups[i].members || []
      for (var m = 0; m < list.length; m++) out[list[m]] = groups[i]
    }
    return out
  }

  function sharedFor(key) {
    return sharedKeys[key] || null
  }

  function graphCaption() {
    var row = graphSubject
    if (!row || !mode) return ""
    var card = cardFor(row.key)
    var linked = !!(card && !row.isPump && cardLinked(card))
    var bits = []
    if (linked) {
      var names = []
      var list = card.rows || []
      for (var i = 0; i < list.length; i++) {
        if (fanInCard(card, list[i])) names.push(chipText(list[i]))
      }
      bits.push(names.join(", "))
      bits.push("linked")
    } else {
      bits.push(chipText(row))
    }
    bits.push(mode.name)
    var now = tempNow(row)
    if (isFinite(now) && now >= 0) bits.push("now " + Math.round(now) + "° " + (deviceKind(row) === "GPU" ? "GPU" : "CPU"))
    if (!linked && selectedGroup) bits.push(selectedGroup.name)
    if (row.isPump) bits.push("floor 50%")
    if (!graphLive && row.fixed !== null && row.fixed !== undefined)
      bits.push("fixed " + row.fixed + "%")
    var rpmLabel = rpmText(row)
    if (rpmLabel) bits.push(rpmLabel)
    return bits.join("  ·  ")
  }

  onModeListChanged: ensureMode()
  onBoardSigChanged: stableBoard = boardGroups
  Component.onCompleted: {
    ensureMode()
    stableBoard = boardGroups
  }
  onRowsChanged: {
    if (rowByKey(memberKey)) return
    memberKey = ""
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].inMode && rows[i].profileUid) {
        memberKey = rows[i].key
        return
      }
    }
  }

  Item {
    id: modeRow
    width: parent.width
    height: root.modeH

    Row {
      spacing: Style.space(6)
      height: parent.height

      Repeater {
        model: root.modeList
        delegate: Button {
          required property var modelData
          width: root.modeSlot
          height: root.modeH
          verticalPadding: Style.space(2)
          text: modelData.name
          selected: modelData.uid === root.modeUid
          hasCursor: root.aimMode(modelData.uid)
          bordered: true
          foreground: root.fg
          accent: /hell/i.test(modelData.name) ? Color.urgent : root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(4)
          tooltipText: modelData.uid === root.service.activeModeUid ? "Running" : "Edit this mode"
          onClicked: {
            root.modeUid = modelData.uid
            root.picked = ({})
          }
        }
      }
    }

    Rectangle {
      anchors.right: applyBtn.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: 1
      height: parent.height
      visible: root.mode !== null
      color: root.line
    }

    Button {
      id: applyBtn
      anchors.right: parent.right
      visible: root.mode !== null
      width: root.modeH
      height: root.modeH
      iconText: root.modeApplied ? "\uf058" : "\uf05d"
      iconSize: Style.space(15)
      bordered: true
      hasCursor: root.keyed && root.navAt() && root.navAt().kind === "apply"
      selected: false
      background: root.modeApplied ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22) : "transparent"
      foreground: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      horizontalPadding: 0
      verticalPadding: 0
      tooltipText: !root.mode ? ""
        : (root.members.length === 0
          ? "Add a channel before applying"
          : (root.modeApplied
            ? "Save curves. " + root.mode.name + " is running"
            : "Save curves and run " + root.mode.name))
      onClicked: root.applyMode()
    }
  }

  Flow {
    id: deviceFlow
    width: parent.width
    spacing: Style.space(8)

    Repeater {
      model: root.stableBoard
      delegate: boardCard
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(6)
    visible: root.graphSubject !== null

    CurveView {
      width: parent.width
      height: {
        var base = Style.space(200)
        if (!root.graphLive) return 0
        if (!root.fill || !root.visible || root.viewHeight < 1) return base
        var above = modeRow.height + deviceFlow.height + Style.space(28)
        var below = groupCreateRow.height + modeCreateRow.height + Style.space(170)
        var room = root.viewHeight - above - below
        return room > base ? room : base
      }
      visible: height > 0
      interactive: root.graphLive
      points: root.graphPoints
      minDuty: root.graphFloor()
      currentTemp: root.graphSubject ? root.tempNow(root.graphSubject) : -1
      foreground: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      onPointsEdited: function(points) { root.storeGraph(points) }
    }

    Item {
      id: captionRow
      width: parent.width
      height: Math.max(captionText.implicitHeight, curveTools.visible ? curveTools.height : 0)

      Text {
        id: captionText
        width: curveTools.visible
          ? Math.max(0, captionRow.width - curveTools.width - Style.space(8))
          : captionRow.width
        anchors.verticalCenter: parent.verticalCenter
        elide: root.graphLive ? Text.ElideRight : Text.ElideNone
        wrapMode: root.graphLive ? Text.NoWrap : Text.WordWrap
        text: root.graphLive
          ? root.graphCaption()
          : (root.graphSubject && root.graphSubject.inMode
            ? "This channel has no curve in " + root.mode.name + " yet."
            : "Switch this fan on to keep a curve for it in " + (root.mode ? root.mode.name : "this mode") + ".")
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        id: curveTools
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: root.graphLive
        spacing: Style.space(4)
        height: Style.space(22)

        Repeater {
          model: root.curveToolModel
          delegate: Item {
            id: tool
            required property var modelData
            readonly property string kind: modelData.kind
            readonly property bool on: kind === "undo" ? root.canUndo : (kind === "redo" ? root.canRedo : root.canReset)
            readonly property bool aimed: {
              var item = root.navAt()
              return root.keyed && item && item.kind === kind
            }
            width: kind === "reset" ? toolWord.implicitWidth + Style.space(12) : Style.space(22)
            height: Style.space(22)

            Item {
              anchors.fill: parent
              opacity: tool.on ? 1 : 0.35

              Rectangle {
                anchors.fill: parent
                radius: 0
                color: tool.aimed
                  ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                  : (toolMouse.containsMouse && tool.on
                    ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
                    : "transparent")
                border.width: tool.kind === "reset" ? 1 : 0
                border.color: tool.aimed ? root.accent : root.line
              }

              OpticalGlyph {
                visible: tool.kind !== "reset"
                anchors.centerIn: parent
                width: Style.space(16)
                height: Style.space(16)
                text: tool.kind === "undo" ? root.undoGlyph : root.redoGlyph
                fontFamily: root.fontFamily
                fontSize: Style.space(16)
                color: tool.aimed || (toolMouse.containsMouse && tool.on) ? root.accent : root.fg
              }

              Text {
                id: toolWord
                anchors.centerIn: parent
                visible: tool.kind === "reset"
                text: "Reset"
                color: tool.aimed || (toolMouse.containsMouse && tool.on) ? root.accent : root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              id: toolMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: tool.on ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: {
                if (tool.on) root.useCurveTool(tool.kind)
              }
            }

            PanelToolTip {
              visible: toolMouse.containsMouse
              text: root.curveToolTip(tool.kind)
              fontFamily: root.fontFamily
              panelBackground: Color.background
              panelForeground: Color.foreground
              panelBorder: Color.accent
            }
          }
        }
      }
    }
  }

  Text {
    width: parent.width
    visible: root.modeGroups.length === 0
    text: "No spinning channels to add."
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Component {
    id: boardCard
    Rectangle {
      id: card
      required property var modelData
      required property int index
      readonly property bool holdsSelection: {
        var list = modelData.rows || []
        for (var i = 0; i < list.length; i++) {
          if (list[i].sharedHost !== true && root.sharedFor(list[i].key)) continue
          if (list[i].key === root.memberKey) return true
        }
        return false
      }
      readonly property bool concealed: root.cardConcealed(modelData)
      width: root.cardWidth(root.width)
      height: root.cardH
      radius: 0
      color: "transparent"
      opacity: concealed ? 0.38 : 1
      border.width: 1
      border.color: holdsSelection ? root.accent : root.line
      clip: true

      Column {
        id: cardCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(8)
        spacing: Style.space(6)

        Item {
          id: titleRow
          width: parent.width
          height: Style.space(22)

          Rectangle {
            id: colorDot
            width: Style.space(8)
            height: Style.space(8)
            radius: 0
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            color: card.modelData.kind === "shared" ? root.accent : Cc.groupColor("", card.modelData.name, card.index)
          }

          Item {
            id: hideHit
            anchors.right: linkHit.left
            anchors.rightMargin: card.concealed ? Style.space(2) : 0
            anchors.verticalCenter: parent.verticalCenter
            width: card.concealed ? Style.space(22) : 0
            height: Style.space(22)
            visible: card.concealed

            Rectangle {
              anchors.fill: parent
              radius: 0
              color: hideMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06) : "transparent"
            }

            OpticalGlyph {
              anchors.centerIn: parent
              width: Style.space(16)
              height: Style.space(16)
              text: root.eyeOff
              fontFamily: root.fontFamily
              fontSize: Style.space(16)
              color: hideMouse.containsMouse ? root.accent : root.fg
            }

            MouseArea {
              id: hideMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.revealCard(card.modelData)
            }

            PanelToolTip {
              visible: hideMouse.containsMouse
              text: "Hidden. Click to show it on Monitoring again."
              fontFamily: root.fontFamily
              panelBackground: Color.background
              panelForeground: Color.foreground
              panelBorder: Color.accent
            }
          }

          Item {
            id: linkHit
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(22)
            height: Style.space(22)

            Rectangle {
              anchors.fill: parent
              radius: 0
              color: root.aimLink(card.modelData.uid)
                ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                : (linkMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06) : "transparent")
            }

            OpticalGlyph {
              anchors.centerIn: parent
              width: Style.space(16)
              height: Style.space(16)
              text: root.cardLinked(card.modelData) ? root.linkOn : root.linkOff
              fontFamily: root.fontFamily
              fontSize: Style.space(16)
              color: root.aimLink(card.modelData.uid) || linkMouse.containsMouse ? root.accent : root.fg
            }

            MouseArea {
              id: linkMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleLink(card.modelData.uid)
            }

            PanelToolTip {
              visible: linkMouse.containsMouse
              text: root.cardLinked(card.modelData)
                ? "Linked curve. Click to edit each fan on its own. The pump keeps its own curve."
                : "Separate curves. Click to use one curve for these fans. The pump keeps its own curve."
              fontFamily: root.fontFamily
              panelBackground: Color.background
              panelForeground: Color.foreground
              panelBorder: Color.accent
            }
          }

          Text {
            visible: root.renamingId !== card.modelData.uid
            anchors.left: colorDot.right
            anchors.leftMargin: Style.space(8)
            anchors.right: hideHit.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            text: card.modelData.kind === "shared" ? card.modelData.name : String(card.modelData.name || "Device").toUpperCase()
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: card.modelData.kind === "shared" ? 0 : 0.6
            elide: Text.ElideRight

            MouseArea {
              anchors.fill: parent
              enabled: card.modelData.kind === "shared"
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: {
                root.renamingId = card.modelData.uid
                root.renameText = card.modelData.name || ""
              }
            }
          }

          Loader {
            active: card.modelData.kind === "shared" && root.renamingId === card.modelData.uid
            visible: active
            anchors.left: colorDot.right
            anchors.leftMargin: Style.space(8)
            anchors.right: hideHit.left
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            height: Style.space(22)
            sourceComponent: renameField
          }
        }

        Grid {
          id: fanGrid
          width: parent.width
          columns: 2
          columnSpacing: Style.space(8)
          rowSpacing: Style.space(4)

          Repeater {
            model: card.modelData.rows
            delegate: Item {
              id: fanCell
              required property var modelData
              required property int index
              readonly property bool claimed: card.modelData.kind === "device" && root.sharedFor(modelData.key) !== null
              readonly property bool showSwitch: !claimed
              readonly property bool linkedMate: {
                if (fanCell.claimed || fanCell.modelData.isPump) return false
                if (!root.cardLinked(card.modelData)) return false
                var sel = root.selected
                if (!sel || sel.isPump) return false
                var home = root.cardFor(sel.key)
                return !!(home && home.uid === card.modelData.uid && home.kind === card.modelData.kind)
              }
              readonly property bool chosen: !claimed && (root.memberKey === modelData.key || linkedMate)
              readonly property var claim: claimed ? root.sharedFor(modelData.key) : null
              width: Math.max(1, Math.floor((fanGrid.width - fanGrid.columnSpacing) / 2))
              height: root.fanRowH
              opacity: claimed ? 0.38 : 1

              Rectangle {
                anchors.fill: parent
                radius: 0
                color: fanCell.chosen || root.aimChannel(fanCell.modelData.key)
                  ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                  : (fanMouse.containsMouse && !fanCell.claimed
                    ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
                    : "transparent")
              }

              Column {
                id: fanLabel
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4)
                anchors.right: fanSwitch.visible ? fanSwitch.left : parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Text {
                  width: fanLabel.width
                  text: root.chipText(fanCell.modelData)
                  color: fanCell.claimed ? root.muted : (fanCell.chosen ? root.accent : root.fg)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  width: fanLabel.width
                  visible: text !== ""
                  text: root.rpmText(fanCell.modelData)
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(11)
                  elide: Text.ElideRight
                }
              }

              SquareSwitch {
                id: fanSwitch
                anchors.right: parent.right
                anchors.rightMargin: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                width: visible ? implicitWidth : 0
                visible: fanCell.showSwitch
                on: fanCell.modelData.inMode === true
                foreground: root.fg
                accent: root.accent
                onClicked: {
                  if (card.modelData.kind === "shared") root.toggleGrouped(fanCell.modelData)
                  else root.toggleChannel(fanCell.modelData)
                }
              }

              MouseArea {
                id: fanMouse
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.right: fanSwitch.visible ? fanSwitch.left : parent.right
                hoverEnabled: true
                cursorShape: fanCell.claimed ? Qt.ArrowCursor : Qt.PointingHandCursor
                onClicked: if (!fanCell.claimed) root.selectRow(fanCell.modelData.key)
              }

              PanelToolTip {
                visible: fanMouse.containsMouse
                text: fanCell.claimed && fanCell.claim
                  ? (root.chipText(fanCell.modelData) + " uses " + fanCell.claim.name)
                  : ((fanCell.modelData.deviceName ? fanCell.modelData.deviceName + "  " : "")
                    + fanCell.modelData.label
                    + (root.rpmText(fanCell.modelData) ? "  ·  " + root.rpmText(fanCell.modelData) : "")
                    + (fanCell.modelData.inMode ? "" : "  ·  not in this mode"))
                fontFamily: root.fontFamily
                panelBackground: Color.background
                panelForeground: Color.foreground
                panelBorder: Color.accent
              }
            }
          }
        }

      }
    }
  }

  Component {
    id: renameField
    TextField {
      width: parent ? parent.width : Style.space(140)
      text: root.renameText
      placeholderText: "Group name"
      foreground: root.fg
      accent: root.accent
      font.pixelSize: Style.font.caption
      verticalPadding: Style.space(2)
      onTextEdited: root.renameText = text
      onAccepted: root.commitRename()
      Keys.onEscapePressed: function(event) {
        root.renamingId = ""
        event.accepted = true
      }
      Component.onCompleted: forceActiveFocus()
    }
  }

  PanelSeparator { foreground: root.fg }

  PanelSectionHeader {
    text: "Shared curve"
    foreground: root.fg
    fontFamily: root.fontFamily
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Check two or more channels in this mode. They then share one curve."
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Flow {
    width: parent.width
    spacing: Style.space(6)
    visible: root.members.length > 0

    Repeater {
      model: root.pickList
      delegate: Button {
        required property var modelData
        readonly property bool used: root.groupedKey(modelData.key)
        text: root.chipText(modelData)
        selected: !used && root.picked[modelData.key] === true
        bordered: true
        opacity: used ? 0.38 : 1
        foreground: used ? root.muted : root.fg
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        onClicked: if (!used) root.togglePick(modelData.key)
      }
    }
  }

  Item {
    id: groupCreateRow
    width: parent.width
    height: Math.max(groupField.implicitHeight, groupFlow.implicitHeight)

    TextField {
      id: groupField
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(180)
      height: implicitHeight
      placeholderText: "Group name"
      foreground: root.fg
      accent: root.accent
      text: root.groupName
      onTextEdited: root.groupName = text
    }

    Button {
      id: groupButton
      anchors.left: groupField.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      height: groupField.height
      text: "Group"
      bordered: true
      enabled: root.members.length > 1
      foreground: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.body
      onClicked: root.makeGroup()
    }

    Flow {
      id: groupFlow
      anchors.left: groupButton.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      layoutDirection: Qt.RightToLeft
      spacing: Style.space(8)
      visible: root.listedGroups.length > 0

      Repeater {
        model: root.listedGroups
        delegate: Row {
          required property var modelData
          layoutDirection: Qt.LeftToRight
          spacing: Style.space(6)
          height: groupField.height

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.name || "Group"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Rectangle {
            width: groupField.height
            height: groupField.height
            radius: 0
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
            border.width: 1
            border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.28)

            OpticalGlyph {
              anchors.centerIn: parent
              width: Style.space(16)
              height: Style.space(16)
              text: root.trash
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              color: root.fg
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.service) root.service.forgetGroup(modelData.id)
            }
          }
        }
      }
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: root.service && root.service.lastError !== ""
    text: root.service ? root.service.lastError : ""
    color: Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  PanelSeparator { foreground: root.fg }

  PanelSectionHeader {
    text: "New mode"
    foreground: root.fg
    fontFamily: root.fontFamily
  }

  Item {
    id: modeCreateRow
    width: parent.width
    height: Math.max(modeField.implicitHeight, modeFlow.implicitHeight)

    TextField {
      id: modeField
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(180)
      height: implicitHeight
      placeholderText: "Mode name"
      foreground: root.fg
      accent: root.accent
      text: root.modeName
      onTextEdited: root.modeName = text
      onAccepted: {
        if (root.service) root.service.createMode(modeField.text)
        root.modeName = ""
      }
    }

    Button {
      id: modeButton
      anchors.left: modeField.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      height: modeField.height
      text: "Create"
      bordered: true
      foreground: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.body
      onClicked: {
        if (root.service) root.service.createMode(modeField.text)
        root.modeName = ""
      }
    }

    Flow {
      id: modeFlow
      anchors.left: modeButton.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      layoutDirection: Qt.RightToLeft
      spacing: Style.space(8)
      visible: root.customModes.length > 0

      Repeater {
        model: root.customModes
        delegate: Row {
          required property var modelData
          readonly property bool running: root.service && modelData.uid === root.service.activeModeUid
          layoutDirection: Qt.LeftToRight
          spacing: Style.space(6)
          height: modeField.height
          opacity: running ? 0.38 : 1

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.name || "Mode"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Rectangle {
            width: modeField.height
            height: modeField.height
            radius: 0
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, running ? 0.03 : 0.06)
            border.width: 1
            border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.28)

            OpticalGlyph {
              anchors.centerIn: parent
              width: Style.space(16)
              height: Style.space(16)
              text: root.trash
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              color: root.fg
            }

            MouseArea {
              anchors.fill: parent
              enabled: !parent.parent.running
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.removeMode(modelData.uid)
            }
          }
        }
      }
    }
  }
}
