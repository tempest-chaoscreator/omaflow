import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "CcMap.js" as Cc
import "Nav.js" as Nav
import "ThemePalette.js" as ThemePalette

// Device list. Custom groups are their own section. Hidden and Inactive
// are sibling folds. Stopped rows sit one step in from those labels.
// The row models stay put across polls. A fresh array each second used to
// destroy the hovered row and restart the tooltip delay.
Column {
  id: root

  property var service: null
  property bool keyed: false
  property int navIndex: 0
  property color fg: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color line: Qt.rgba(fg.r, fg.g, fg.b, 0.22)
  property color muted: Qt.darker(fg, 1.4)
  property string fontFamily: Style.font.family
  property var opened: ({})
  // Separate from the inactive fold. A hidden block starts closed.
  property var openedBlocks: ({})
  property var palette: []
  // One key list per status shape. A swatch then only looks up its color.
  readonly property var blockKeyList: ThemePalette.blockKeys(
    service && service.channels ? service.channels : [],
    service && service.groups ? service.groups : [],
    service && service.hiddenDevices,
    service && service.hiddenChannels,
    service && service.pinGroups === true
  )
  property var stableGroups: []
  property var stableShared: []
  property var sectionOrder: ["devices"]
  // nf-md-eye U+F0208, nf-md-eye_off_outline U+F06D1
  readonly property string eyeOn: "\uDB80\uDE08"
  readonly property string eyeOff: "\uDB81\uDED1"
  // nf-md-chevron_right U+F0142, nf-md-chevron_down U+F0140
  readonly property string chevronRight: "\uDB80\uDD42"
  readonly property string chevronDown: "\uDB80\uDD40"
  // nf-md-pencil U+F03EB
  readonly property string pencil: "\uDB80\uDFEB"
  property string renameKind: ""
  property string renameUid: ""
  property string renameChannel: ""
  property string renameText: ""
  property string renameDraft: ""
  property string renameOriginal: ""
  property string renamePlaceholder: "Name"
  property int renameEpoch: 0

  width: parent ? parent.width : 0
  spacing: Style.space(12)

  readonly property bool pinOn: service && service.pinGroups === true
  readonly property var groups: {
    var list = service ? Cc.deviceGroups(service.channels, service.modes) : []
    var copy = list.slice()
    copy.sort(function(a, b) {
      var ah = deviceHidden(a.uid) ? 1 : 0
      var bh = deviceHidden(b.uid) ? 1 : 0
      if (ah !== bh) return ah - bh
      return String(a.name).localeCompare(String(b.name))
    })
    return copy
  }
  readonly property var sharedCards: {
    var saved = service && service.groups ? service.groups : []
    var channels = service && service.channels ? service.channels : []
    var byKey = ({})
    for (var i = 0; i < channels.length; i++) byKey[channels[i].key] = channels[i]
    var out = []
    for (var g = 0; g < saved.length; g++) {
      var rows = []
      var keys = saved[g].members || []
      for (var m = 0; m < keys.length; m++) {
        var channel = byKey[keys[m]]
        if (channel) rows.push(channel)
      }
      if (!rows.length) continue
      rows.sort(function(a, b) {
        return String(a.label || "").localeCompare(String(b.label || ""))
      })
      out.push({ id: saved[g].id, name: saved[g].name || "Group", rows: rows })
    }
    out.sort(function(a, b) {
      var ah = rowsHidden(a.rows) ? 1 : 0
      var bh = rowsHidden(b.rows) ? 1 : 0
      if (ah !== bh) return ah - bh
      return String(a.name).localeCompare(String(b.name))
    })
    return out
  }
  readonly property var sections: sectionList(pinOn, sharedCards.length)
  // Membership, plus whether a shown fan is spinning. The rpm number stays
  // out, so a poll that only changes speed does not rebuild the rows. A quiet
  // tick can still leave the spin bit stale until the next shape change,
  // because that tick does not replace `channels`.
  readonly property string structureSig: {
    var parts = []
    var list = groups
    var i
    var n
    for (i = 0; i < list.length; i++) {
      var group = list[i]
      var shownKeys = []
      var hiddenKeys = []
      var shown = group.shown || []
      var hidden = group.hidden || []
      for (n = 0; n < shown.length; n++) shownKeys.push(shown[n].key + "=" + (shown[n].label || "") + (Number(shown[n].rpm) > 0 ? "+" : "-"))
      for (n = 0; n < hidden.length; n++) hiddenKeys.push(hidden[n].key + "=" + (hidden[n].label || ""))
      parts.push([group.uid, group.name, group.type, shownKeys.join(","), hiddenKeys.join(",")].join("~"))
    }
    var cards = sharedCards
    for (i = 0; i < cards.length; i++) {
      var memberKeys = []
      var members = cards[i].rows || []
      for (n = 0; n < members.length; n++) {
        memberKeys.push(members[n].key + "=" + (members[n].label || "") + (Number(members[n].rpm) > 0 ? "+" : "-"))
      }
      parts.push(["s", cards[i].id, cards[i].name, memberKeys.join(",")].join("~"))
    }
    parts.push(pinOn ? "pin" : "tail")
    var hiddenDevices = service && service.hiddenDevices ? service.hiddenDevices : ({})
    var hiddenNames = []
    for (var hk in hiddenDevices) if (hiddenDevices[hk] === true) hiddenNames.push(hk)
    hiddenNames.sort()
    parts.push("h:" + hiddenNames.join(","))
    var hiddenChannels = service && service.hiddenChannels ? service.hiddenChannels : ({})
    var hiddenChannelNames = []
    for (var ck in hiddenChannels) if (hiddenChannels[ck] === true) hiddenChannelNames.push(ck)
    hiddenChannelNames.sort()
    parts.push("c:" + hiddenChannelNames.join(","))
    return parts.join("|")
  }
  readonly property var navItems: {
    var out = []
    var y = 0
    function place(item) {
      item.x = 0
      item.y = y
      y += 1
      out.push(item)
    }
    function placeFans(rows, eyeOnRight) {
      var list = rows || []
      var n
      for (n = 0; n < list.length; n++) {
        if (!list[n] || !list[n].key) continue
        var rowY = y
        // A quiet device draws the eye on the right and calibrate on its left.
        if (eyeOnRight) {
          out.push({ kind: "fan", key: list[n].key, x: 0, y: rowY })
          out.push({ kind: "channelEye", key: list[n].key, x: 1, y: rowY })
        } else {
          out.push({ kind: "channelEye", key: list[n].key, x: 0, y: rowY })
          out.push({ kind: "fan", key: list[n].key, x: 1, y: rowY })
        }
        y += 1
      }
    }
    function placeDevice(group) {
      var rowY = y
      var spinning = activeOf(group).length > 0
      out.push({ kind: "eye", uid: group.uid, x: 0, y: rowY })
      if (spinning) out.push({ kind: "group", uid: group.uid, x: 1, y: rowY })
      y += 1
      var openRows = shownOpen(group.shown)
      var tuckedRows = deviceTucked(group)
      var idleRows = deviceIdle(group)
      placeFans(openRows, !spinning)
      if (tuckedRows.length) {
        place({ kind: "blockFold", key: "d:" + group.uid })
        if (openedBlocks["d:" + group.uid] === true) placeFans(tuckedRows, !spinning)
      }
      if (idleRows.length) place({ kind: "hidden", uid: group.uid })
      if (opened[group.uid] === true) placeFans(idleRows, !spinning)
    }
    function placeShared(card) {
      // Calibrate Group is on the right edge, above the channel calibrate.
      if (jobsFor(card.rows).length) {
        out.push({ kind: "shared", id: card.id, x: 1, y: y })
        y += 1
      }
      var moving = sharedOpen(card.rows)
      var tucked = sharedTucked(card.rows)
      var still = sharedIdle(card.rows)
      placeFans(moving)
      if (tucked.length) {
        place({ kind: "blockFold", key: "g:" + card.id })
        if (openedBlocks["g:" + card.id] === true) placeFans(tucked)
      }
      if (still.length) place({ kind: "groupFold", id: card.id })
      if (opened[card.id] === true) placeFans(still)
    }
    // Calibrate All sits on the right of the page title.
    if (jobsFor(everyActive()).length) {
      out.push({ kind: "all", x: 1, y: y })
      y += 1
    }
    var order = sections
    var s
    var i
    for (s = 0; s < order.length; s++) {
      if (order[s] === "devices") {
        for (i = 0; i < groups.length; i++) placeDevice(groups[i])
      } else {
        for (i = 0; i < sharedCards.length; i++) placeShared(sharedCards[i])
      }
    }
    return out
  }

  function activeOf(group) {
    var out = []
    var shown = group && group.shown ? group.shown : []
    for (var i = 0; i < shown.length; i++) if (Number(shown[i].rpm) > 0) out.push(shown[i])
    return out
  }

  function channelConcealed(channel) {
    return Cc.channelConcealed(
      service && service.hiddenDevices,
      service && service.hiddenChannels,
      channel
    )
  }

  // Eye-hidden channels. A stopped header the eye still shows stays Inactive.
  function shownTucked(rows) {
    var out = []
    var list = rows || []
    for (var i = 0; i < list.length; i++) {
      if (!list[i] || !channelConcealed(list[i])) continue
      out.push(list[i])
    }
    return out
  }

  function shownOpen(rows) {
    var out = []
    var list = rows || []
    for (var i = 0; i < list.length; i++) {
      if (!list[i] || channelConcealed(list[i])) continue
      out.push(list[i])
    }
    return out
  }

  function sharedOpen(rows) {
    var out = []
    var list = rows || []
    for (var i = 0; i < list.length; i++) {
      if (!list[i] || !(Number(list[i].rpm) > 0) || channelConcealed(list[i])) continue
      out.push(list[i])
    }
    return out
  }

  function sharedTucked(rows) {
    var out = []
    var list = rows || []
    for (var i = 0; i < list.length; i++) {
      if (!list[i] || !channelConcealed(list[i])) continue
      out.push(list[i])
    }
    return out
  }

  // Stopped headers that are still shown. An eye-hidden one is in Hidden.
  function sharedIdle(rows) {
    var out = []
    var list = rows || []
    for (var i = 0; i < list.length; i++) {
      if (!list[i] || Number(list[i].rpm) > 0 || channelConcealed(list[i])) continue
      out.push(list[i])
    }
    return out
  }

  function deviceTucked(group) {
    var shown = shownTucked(group && group.shown)
    var still = shownTucked(group && group.hidden)
    return shown.concat(still)
  }

  function deviceIdle(group) {
    return shownOpen(group && group.hidden)
  }

  function jobsFor(rows) {
    var out = []
    var seen = ({})
    var list = rows || []
    for (var i = 0; i < list.length; i++) {
      var channel = list[i]
      if (!channel || seen[channel.key] || !(Number(channel.rpm) > 0)) continue
      seen[channel.key] = true
      out.push({ deviceUid: channel.deviceUid, name: channel.name })
    }
    return out
  }

  function everyActive() {
    var rows = []
    for (var i = 0; i < groups.length; i++) {
      var active = activeOf(groups[i])
      for (var n = 0; n < active.length; n++) rows.push(active[n])
    }
    return rows
  }

  function calibrateRows(rows) {
    if (!service) return
    var jobs = jobsFor(rows)
    if (!jobs.length) return
    service.startCalibrations(jobs)
  }

  function calibrateOne(channel) {
    var live = channel && channel.key ? liveChannel(channel.key) : channel
    var src = live || channel
    if (!service || !src || !src.deviceUid || !src.name) return
    service.startCalibrations([{ deviceUid: src.deviceUid, name: src.name }])
  }

  function liveChannel(key) {
    var list = service && service.channels ? service.channels : []
    var i
    for (i = 0; i < list.length; i++) if (list[i].key === key) return list[i]
    return null
  }

  function channelOf(channel) {
    var live = channel && channel.key ? liveChannel(channel.key) : null
    return live || channel || null
  }

  function swatchFor(key) {
    return ThemePalette.swatch(palette, blockKeyList, key)
  }

  function sectionList(pinned, count) {
    if (!count) return ["devices"]
    return pinned ? ["groups", "devices"] : ["devices", "groups"]
  }

  function applyStable() {
    stableGroups = groups
    stableShared = sharedCards
    // Read the service flag here. `sections` can still be the previous
    // array when this runs from onStructureSigChanged.
    var pinned = service && service.pinGroups === true
    var next = sectionList(pinned, stableShared ? stableShared.length : 0)
    var prev = sectionOrder || []
    var same = prev.length === next.length
    for (var i = 0; same && i < next.length; i++) if (prev[i] !== next[i]) same = false
    if (!same) sectionOrder = next
  }

  function navAt() {
    return navItems.length ? navItems[Math.max(0, Math.min(navItems.length - 1, navIndex))] : null
  }

  function moveNav(dx, dy) {
    var index = navItems.length ? Math.max(0, Math.min(navItems.length - 1, navIndex)) : 0
    navIndex = Nav.step(navItems, index, dx, dy)
  }

  function activateNav() {
    var item = navAt()
    if (!item) return
    if (item.kind === "hidden" || item.kind === "groupFold") toggleFold(item.uid || item.id)
    else if (item.kind === "blockFold") toggleBlock(item.key)
    else if (item.kind === "eye") toggleDevice(item.uid)
    else if (item.kind === "channelEye") {
      var channel = liveChannel(item.key)
      if (channel && deviceHidden(channel.deviceUid)) return
      toggleChannel(channel)
    }
    else if (item.kind === "all") calibrateRows(everyActive())
    else if (item.kind === "fan") calibrateOne(liveChannel(item.key))
    else if (item.kind === "group") {
      for (var i = 0; i < groups.length; i++) if (groups[i].uid === item.uid) calibrateRows(activeOf(groups[i]))
    } else if (item.kind === "shared") {
      for (var s = 0; s < sharedCards.length; s++) if (sharedCards[s].id === item.id) calibrateRows(sharedCards[s].rows)
    }
  }

  function aimed(kind, id) {
    if (!keyed) return false
    var item = navAt()
    if (!item || item.kind !== kind) return false
    if (kind === "hidden" || kind === "group" || kind === "eye") return item.uid === id
    if (kind === "blockFold") return item.key === id
    if (kind === "shared" || kind === "groupFold") return item.id === id
    if (kind === "fan" || kind === "channelEye") return item.key === id
    return kind === "all"
  }

  function toggleFold(uid) {
    var next = Cc.copyMap(opened)
    next[uid] = next[uid] !== true
    opened = next
  }

  function blockShown(key) {
    return openedBlocks[key] === true
  }

  function toggleBlock(key) {
    if (!key) return
    var next = Cc.copyMap(openedBlocks)
    next[key] = next[key] !== true
    openedBlocks = next
  }

  function deviceHidden(uid) {
    var map = service && service.hiddenDevices ? service.hiddenDevices : null
    return !!(map && map[uid] === true)
  }

  function rowsHidden(rows) {
    var list = rows || []
    if (!list.length) return false
    var devices = service ? service.hiddenDevices : null
    var channels = service ? service.hiddenChannels : null
    var seen = false
    for (var i = 0; i < list.length; i++) {
      if (!list[i] || !list[i].deviceUid) continue
      seen = true
      if (!Cc.channelConcealed(devices, channels, list[i])) return false
    }
    return seen
  }

  function toggleDevice(uid) {
    if (!service || !uid) return
    service.setDeviceHidden(uid, !deviceHidden(uid))
  }

  function channelHidden(channel) {
    if (!channel || !channel.key) return false
    var map = service && service.hiddenChannels
    return !!(map && map[channel.key] === true)
  }

  function toggleChannel(channel) {
    if (!service || !channel || !channel.key) return
    service.setChannelHidden(channel.key, !channelHidden(channel))
  }

  function detectedName(value) {
    var text = String(value || "").replace(/[\u0000-\u001f\u007f]/g, "")
    var cut = text.indexOf(" (")
    if (cut > 0) text = text.slice(0, cut)
    return text.replace(/^\s+|\s+$/g, "")
  }

  function overrideRow(uid) {
    var doc = service && service.nameOverrides
    var devices = doc && doc.devices
    if (!devices || !uid) return null
    var row = devices[uid]
    if (!row || typeof row !== "object") return null
    return row
  }

  function deviceHint(uid, shown) {
    var row = overrideRow(uid)
    if (!row) return ""
    var detected = detectedName(row.device_name)
    if (!detected || detected === String(shown || "")) return ""
    return detected
  }

  function channelHint(channel) {
    if (!channel) return ""
    var shown = String(channel.label || channel.name || "")
    var row = overrideRow(channel.deviceUid)
    var spec = row && row.channels ? row.channels[channel.name] : null
    var detected = spec && spec.channel_label ? detectedName(spec.channel_label) : String(channel.name || "")
    detected = detected.replace(/[\u0000-\u001f\u007f]/g, "").replace(/^\s+|\s+$/g, "")
    if (!detected || detected === shown) return ""
    return detected
  }

  function editingChannel(channel) {
    return !!(channel && renameKind === "channel" && renameUid === channel.deviceUid && renameChannel === channel.name)
  }

  function editingName() {
    return renameKind !== ""
  }

  function takeEnter() {
    if (!renameKind) return false
    commitRename(renameEpoch, renameDraft)
    return true
  }

  function takeEscape() {
    if (!renameKind) return false
    cancelRename(renameEpoch)
    return true
  }

  function startRename(kind, uid, channel, text, placeholder) {
    if (renameKind) commitRename(renameEpoch, renameDraft)
    renameEpoch = renameEpoch + 1
    renameKind = kind
    renameUid = uid || ""
    renameChannel = channel || ""
    renameText = text || ""
    renameDraft = text || ""
    renameOriginal = text || ""
    renamePlaceholder = placeholder || "Name"
  }

  function cancelRename(epoch) {
    if (epoch !== renameEpoch) return
    renameEpoch = renameEpoch + 1
    renameKind = ""
    renameUid = ""
    renameChannel = ""
    renameText = ""
    if (service && service.lastError === "That name is not allowed.") service.lastError = ""
  }

  function commitRename(epoch, typed) {
    if (epoch !== renameEpoch) return
    if (!service || !renameKind) return
    var raw = typed === undefined || typed === null ? renameDraft : typed
    var cleaned = Cc.daemonName(raw)
    if (cleaned === null) {
      service.lastError = "That name is not allowed."
      return
    }
    var before = Cc.daemonName(renameOriginal)
    if (before !== null && before === cleaned) {
      renameEpoch = renameEpoch + 1
      renameKind = ""
      return
    }
    var kind = renameKind
    var uid = renameUid
    var channel = renameChannel
    renameEpoch = renameEpoch + 1
    renameKind = ""
    if (kind === "device") service.renameDevice(uid, raw)
    else service.renameChannel(uid, channel, raw)
  }

  function liveReading(channel) {
    var key = channel && channel.key
    var map = service && service.channelLive
    if (map && key && map[key]) return map[key]
    return channelOf(channel) || channel || {}
  }

  function dutyText(channel) {
    var src = liveReading(channel)
    var duty = src.duty === null || src.duty === undefined || src.duty === "" ? null : Number(src.duty)
    var rpm = src.rpm === null || src.rpm === undefined || src.rpm === "" ? null : Number(src.rpm)
    var dutyLabel = duty !== null && isFinite(duty) ? Math.round(duty) + "%" : "—"
    var rpmLabel = rpm !== null && isFinite(rpm) ? Math.round(rpm) + " rpm" : ""
    return rpmLabel ? dutyLabel + "    " + rpmLabel : dutyLabel
  }

  function fanTip(channel) {
    var src = channelOf(channel) || {}
    var name = src.label || src.name || "fan"
    return "Calibrate " + name
  }

  function fanOn(channel) {
    var src = liveReading(channel)
    return Number(src && src.rpm) > 0
  }

  function inactiveLabel(count) {
    return "Inactive " + count
  }

  component InactiveFold: Item {
    id: fold
    property int count: 0
    property string caption: ""
    property string mark: ""
    property bool hot: false
    readonly property int gap: Style.space(6)
    implicitWidth: word.implicitWidth + (markText.visible ? gap + markText.implicitWidth : 0)
    implicitHeight: Math.max(word.implicitHeight, markText.implicitHeight)

    Text {
      id: word
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: fold.caption !== "" ? fold.caption : root.inactiveLabel(fold.count)
      color: fold.hot ? root.accent : root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.space(12)
    }

    Text {
      id: markText
      visible: fold.mark !== ""
      anchors.left: word.right
      anchors.leftMargin: visible ? fold.gap : 0
      anchors.baseline: word.baseline
      text: fold.mark
      color: word.color
      font.family: root.fontFamily
      font.pixelSize: word.font.pixelSize
    }
  }

  component RenameMark: Item {
    id: mark
    signal clicked()
    width: Style.space(22)
    height: Style.space(22)

    OpticalGlyph {
      anchors.centerIn: parent
      width: Style.space(14)
      height: Style.space(14)
      text: root.pencil
      fontFamily: root.fontFamily
      fontSize: Style.space(14)
      color: markMouse.containsMouse ? root.accent : root.muted
    }

    MouseArea {
      id: markMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: mark.clicked()
    }

    PanelToolTip {
      visible: markMouse.containsMouse
      text: "Rename. Leave blank to use the detected name."
      fontFamily: root.fontFamily
      panelBackground: Commons.Color.background
      panelForeground: Commons.Color.foreground
      panelBorder: Commons.Color.accent
    }
  }

  Component {
    id: renameField
    TextField {
      id: nameField
      property int epoch: 0
      focus: true
      width: parent ? parent.width : Style.space(160)
      placeholderText: root.renamePlaceholder
      foreground: root.fg
      accent: root.accent
      font.pixelSize: Style.font.caption
      verticalPadding: Style.space(2)
      function syncDraft() {
        if (epoch === root.renameEpoch) root.renameDraft = text
      }
      onTextEdited: syncDraft()
      onTextChanged: syncDraft()
      // Enter confirms this field's text. Escape drops it. Focus loss does
      // not save, and neither key is left for the window to close on.
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.cancelRename(epoch)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.commitRename(epoch, nameField.text)
          event.accepted = true
        }
      }
      Component.onCompleted: {
        epoch = root.renameEpoch
        text = root.renameText
        forceActiveFocus()
      }
    }
  }

  component ChannelLine: Item {
    id: line
    property var channel: null
    property int indent: 0
    property bool liveTone: true
    property bool parentDim: false
    // Flush right when this block has no calibrate button, so the eye sits
    // on the same edge as the block eye. Otherwise both eyes sit one gap
    // left of a resting calibrate button.
    property bool eyeFlush: false
    readonly property bool hidden: root.channelHidden(line.channel)
    readonly property bool editing: root.editingChannel(line.channel)
    readonly property string hint: root.channelHint(line.channel)
    readonly property string title: line.channel ? (line.channel.label || line.channel.name || "") : ""
    readonly property bool deviceDim: root.deviceHidden(line.channel ? line.channel.deviceUid : "")

    width: parent ? parent.width : 0
    height: line.editing && lineEdit.item
      ? Math.max(Style.space(28), lineEdit.item.implicitHeight)
      : Style.space(28)
    // A dimmed device card already fades its rows. A device-hidden fan inside
    // a mixed group has to fade on its own, or it stays full brightness.
    opacity: line.parentDim ? 1 : ((line.deviceDim || line.hidden) ? 0.38 : 1)

    Item {
      id: titleSlot
      anchors.left: parent.left
      anchors.leftMargin: line.indent
      anchors.right: dutyText.left
      anchors.rightMargin: Style.space(8)
      anchors.top: parent.top
      anchors.bottom: parent.bottom

      Text {
        id: titleText
        visible: !line.editing
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: {
          if (line.editing) return 0
          var room = titleSlot.width
          var pen = Style.space(22) + Style.space(4)
          var hintW = line.hint !== "" ? Math.min(hintText.implicitWidth, Style.space(120)) + Style.space(8) : 0
          return Math.max(0, Math.min(implicitWidth, Math.max(0, room - pen - hintW)))
        }
        text: line.title
        textFormat: Text.PlainText
        color: line.liveTone ? (root.fanOn(line.channel) ? root.fg : root.muted) : root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.space(12)
        elide: Text.ElideRight
      }

      RenameMark {
        id: penMark
        visible: !line.editing
        anchors.left: titleText.right
        anchors.leftMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        onClicked: {
          if (!line.channel) return
          root.startRename(
            "channel",
            line.channel.deviceUid,
            line.channel.name,
            line.title,
            line.hint !== "" ? line.hint : "Channel name"
          )
        }
      }

      Text {
        id: hintText
        visible: !line.editing && text !== ""
        anchors.left: penMark.right
        anchors.leftMargin: Style.space(8)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: line.hint
        textFormat: Text.PlainText
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.space(11)
        elide: Text.ElideRight
      }

      Loader {
        id: lineEdit
        anchors.fill: parent
        active: line.editing
        visible: active
        focus: active
        sourceComponent: renameField
      }
    }

    Text {
      id: dutyText
      anchors.right: line.eyeFlush ? lineCal.left : eyeBox.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: root.dutyText(line.channel)
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.space(12)
    }

    Item {
      id: eyeBox
      anchors.right: parent.right
      anchors.rightMargin: line.eyeFlush ? 0 : (lineCal.width + Style.space(8))
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(22)
      height: Style.space(22)

      Rectangle {
        anchors.fill: parent
        color: root.aimed("channelEye", line.channel ? line.channel.key : "")
          ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
          : (eyeMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06) : "transparent")
        border.width: 1
        border.color: root.aimed("channelEye", line.channel ? line.channel.key : "") || eyeMouse.containsMouse
          ? root.accent
          : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.28)
      }

      OpticalGlyph {
        anchors.centerIn: parent
        width: Style.space(16)
        height: Style.space(16)
        text: line.hidden || line.deviceDim ? root.eyeOff : root.eyeOn
        fontFamily: root.fontFamily
        fontSize: Style.space(16)
        color: root.aimed("channelEye", line.channel ? line.channel.key : "") || eyeMouse.containsMouse ? root.accent : root.fg
      }

      MouseArea {
        id: eyeMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: line.deviceDim ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: if (!line.deviceDim) root.toggleChannel(line.channel)
      }

      PanelToolTip {
        visible: eyeMouse.containsMouse
        text: line.deviceDim
          ? "Hidden. Monitoring and the bar skip this device."
          : (line.hidden
            ? "Hidden. Monitoring and the bar skip this channel."
            : "Hide this channel from Monitoring and the bar.")
        fontFamily: root.fontFamily
        panelBackground: Commons.Color.background
        panelForeground: Commons.Color.foreground
        panelBorder: Commons.Color.accent
      }
    }

    CalGlyph {
      id: lineCal
      anchors.right: parent.right
      anchors.rightMargin: line.eyeFlush ? (Style.space(22) + Style.space(8)) : 0
      anchors.verticalCenter: parent.verticalCenter
      label: root.fanTip(line.channel)
      reveal: true
      selected: root.aimed("fan", line.channel ? line.channel.key : "")
      fg: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      onClicked: root.calibrateOne(line.channel)
    }
  }

  onStructureSigChanged: Qt.callLater(root.applyStable)
  Connections {
    target: root.service
    function onPinGroupsChanged() { root.applyStable() }
  }
  Component.onCompleted: {
    applyStable()
    if (!palette.length) palette = ThemePalette.blockInks("")
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.palette = ThemePalette.blockInks(text())
    onFileChanged: reload()
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: root.service && root.service.lastError !== ""
    text: root.service ? root.service.lastError : ""
    textFormat: Text.PlainText
    color: Commons.Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: root.service && root.service.lastError === "" && root.service.notice !== ""
    text: root.service ? root.service.notice : ""
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: root.sectionOrder
    delegate: Column {
      id: section
      required property var modelData
      width: root.width
      spacing: 0

      Column {
        width: parent.width
        spacing: Style.space(12)
        visible: section.modelData === "groups"

        Text {
          width: parent.width
          text: "Groups"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.space(13)
          font.bold: true
        }

        Repeater {
          model: root.stableShared
          delegate: Rectangle {
            id: sharedBlock
            required property var modelData
            readonly property var idle: root.sharedIdle(modelData.rows)
            readonly property var moving: root.sharedOpen(modelData.rows)
            readonly property var tucked: root.sharedTucked(modelData.rows)
            readonly property bool open: root.opened[modelData.id] === true
            readonly property bool concealed: root.rowsHidden(modelData.rows)
            readonly property bool blockOpen: root.blockShown("g:" + modelData.id)
            width: root.width
            implicitHeight: sharedCol.implicitHeight + Style.space(20)
            height: implicitHeight
            color: "transparent"
            border.width: 1
            border.color: root.line
            opacity: concealed ? 0.38 : 1

            Rectangle {
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Style.space(3)
              color: root.swatchFor("g:" + sharedBlock.modelData.id)
            }

            Column {
              id: sharedCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              anchors.leftMargin: Style.space(14)
              spacing: Style.space(2)

            Item {
              width: parent.width
              height: Style.space(28)

              Text {
                anchors.left: parent.left
                anchors.leftMargin: 0
                anchors.right: sharedCal.visible ? sharedCal.left : parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: sharedBlock.modelData.name
                textFormat: Text.PlainText
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.space(13)
                font.bold: true
                elide: Text.ElideRight
              }

              CalGlyph {
                id: sharedCal
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.jobsFor(sharedBlock.modelData.rows).length > 0
                selected: root.aimed("shared", sharedBlock.modelData.id)
                label: "Calibrate Group"
                reveal: true
                fg: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.calibrateRows(sharedBlock.modelData.rows)
              }
            }

            Repeater {
              model: sharedBlock.moving
              delegate: Column {
                id: sharedRow
                required property var modelData
                width: sharedCol.width
                spacing: Style.space(2)

                ChannelLine {
                  channel: sharedRow.modelData
                  indent: Style.space(16)
                  liveTone: true
                  parentDim: sharedBlock.concealed
                }

                CalibNote {
                  width: parent.width
                  channel: sharedRow.modelData
                  service: root.service
                  fg: root.fg
                  accent: root.accent
                  muted: root.muted
                  fontFamily: root.fontFamily
                }
              }
            }

            Item {
              visible: sharedBlock.tucked.length > 0
              width: parent.width
              height: visible ? Style.space(28) : 0

              Rectangle {
                anchors.fill: parent
                color: root.aimed("blockFold", "g:" + sharedBlock.modelData.id)
                  ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.14)
                  : (sharedShelf.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05) : "transparent")
              }

              InactiveFold {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                caption: "Hidden " + sharedBlock.tucked.length
                hot: root.aimed("blockFold", "g:" + sharedBlock.modelData.id)
                mark: sharedBlock.blockOpen ? root.chevronDown : root.chevronRight
              }

              MouseArea {
                id: sharedShelf
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleBlock("g:" + sharedBlock.modelData.id)
              }
            }

            Repeater {
              model: sharedBlock.blockOpen ? sharedBlock.tucked : []
              delegate: Column {
                id: sharedTuckedRow
                required property var modelData
                width: sharedCol.width
                spacing: Style.space(2)

                ChannelLine {
                  channel: sharedTuckedRow.modelData
                  indent: Style.space(32)
                  liveTone: true
                  parentDim: sharedBlock.concealed
                }

                CalibNote {
                  width: parent.width
                  indent: Style.space(32)
                  channel: sharedTuckedRow.modelData
                  service: root.service
                  fg: root.fg
                  accent: root.accent
                  muted: root.muted
                  fontFamily: root.fontFamily
                }
              }
            }

            Item {
              visible: sharedBlock.idle.length > 0
              width: parent.width
              height: visible ? Style.space(28) : 0

              Rectangle {
                anchors.fill: parent
                color: root.aimed("groupFold", sharedBlock.modelData.id)
                  ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.14)
                  : (sharedFold.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05) : "transparent")
              }

              InactiveFold {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                count: sharedBlock.idle.length
                hot: root.aimed("groupFold", sharedBlock.modelData.id)
                mark: sharedBlock.open ? root.chevronDown : root.chevronRight
              }

              MouseArea {
                id: sharedFold
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleFold(sharedBlock.modelData.id)
              }
            }

            Repeater {
              model: sharedBlock.open ? sharedBlock.idle : []
              delegate: Column {
                id: sharedIdle
                required property var modelData
                width: sharedCol.width
                spacing: Style.space(2)

                ChannelLine {
                  channel: sharedIdle.modelData
                  indent: Style.space(32)
                  liveTone: false
                  parentDim: sharedBlock.concealed
                }

                CalibNote {
                  width: parent.width
                  indent: Style.space(32)
                  channel: sharedIdle.modelData
                  service: root.service
                  fg: root.fg
                  accent: root.accent
                  muted: root.muted
                  fontFamily: root.fontFamily
                }
              }
            }
            }
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(12)
        visible: section.modelData === "devices"

        Repeater {
          model: root.stableGroups
          delegate: Rectangle {
            id: deviceBlock
            required property var modelData
            readonly property bool concealed: root.deviceHidden(modelData.uid)
            readonly property bool naming: root.renameKind === "device" && root.renameUid === modelData.uid
            readonly property string hint: root.deviceHint(modelData.uid, modelData.name)
            readonly property var idle: root.deviceIdle(modelData)
            readonly property var listed: root.shownOpen(modelData.shown)
            readonly property var tucked: root.deviceTucked(modelData)
            readonly property bool open: root.opened[modelData.uid] === true
            readonly property bool blockOpen: root.blockShown("d:" + modelData.uid)
            readonly property bool eyeFlush: root.activeOf(modelData).length === 0
            width: root.width
            implicitHeight: deviceCol.implicitHeight + Style.space(20)
            height: implicitHeight
            color: "transparent"
            border.width: 1
            border.color: root.line
            opacity: concealed ? 0.38 : 1

            Rectangle {
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Style.space(3)
              color: root.swatchFor("d:" + deviceBlock.modelData.uid)
            }

            Column {
              id: deviceCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              anchors.leftMargin: Style.space(14)
              spacing: Style.space(2)

            Item {
              width: parent.width
              height: deviceBlock.naming && deviceEdit.item
                ? Math.max(Style.space(28), deviceEdit.item.implicitHeight)
                : Style.space(28)

              Item {
                id: deviceNameSlot
                anchors.left: parent.left
                anchors.leftMargin: 0
                anchors.right: eyeHit.left
                anchors.rightMargin: Style.space(8)
                anchors.top: parent.top
                anchors.bottom: parent.bottom

                Text {
                  id: deviceNameText
                  visible: !deviceBlock.naming
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: {
                    if (deviceBlock.naming) return 0
                    var room = deviceNameSlot.width
                    var pen = Style.space(22) + Style.space(4)
                    var hintW = deviceBlock.hint !== "" ? Math.min(deviceHintText.implicitWidth, Style.space(140)) + Style.space(8) : 0
                    return Math.max(Style.space(24), Math.min(implicitWidth, Math.max(0, room - pen - hintW)))
                  }
                  text: String(deviceBlock.modelData.name || "Device").toUpperCase()
                  textFormat: Text.PlainText
                  color: deviceBlock.concealed ? root.muted : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(13)
                  font.bold: true
                  elide: Text.ElideRight
                }

                RenameMark {
                  id: devicePen
                  visible: !deviceBlock.naming
                  anchors.left: deviceNameText.right
                  anchors.leftMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  onClicked: root.startRename(
                    "device",
                    deviceBlock.modelData.uid,
                    "",
                    deviceBlock.modelData.name || "",
                    deviceBlock.hint !== "" ? deviceBlock.hint : "Device name"
                  )
                }

                Text {
                  id: deviceHintText
                  visible: !deviceBlock.naming && text !== ""
                  anchors.left: devicePen.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: deviceBlock.hint
                  textFormat: Text.PlainText
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(11)
                  elide: Text.ElideRight
                }

                Loader {
                  id: deviceEdit
                  anchors.fill: parent
                  active: deviceBlock.naming
                  visible: active
                  focus: active
                  sourceComponent: renameField
                }
              }

              Item {
                id: eyeHit
                anchors.right: deviceCal.visible ? deviceCal.left : parent.right
                anchors.rightMargin: deviceCal.visible ? Style.space(8) : 0
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(22)
                height: Style.space(22)

                Rectangle {
                  anchors.fill: parent
                  color: root.aimed("eye", deviceBlock.modelData.uid)
                    ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                    : (eyeMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06) : "transparent")
                  border.width: 1
                  border.color: root.aimed("eye", deviceBlock.modelData.uid) || eyeMouse.containsMouse
                    ? root.accent
                    : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.28)
                }

                OpticalGlyph {
                  anchors.centerIn: parent
                  width: Style.space(16)
                  height: Style.space(16)
                  text: deviceBlock.concealed ? root.eyeOff : root.eyeOn
                  fontFamily: root.fontFamily
                  fontSize: Style.space(16)
                  color: root.aimed("eye", deviceBlock.modelData.uid) || eyeMouse.containsMouse ? root.accent : root.fg
                }

                MouseArea {
                  id: eyeMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleDevice(deviceBlock.modelData.uid)
                }

                PanelToolTip {
                  visible: eyeMouse.containsMouse
                  text: deviceBlock.concealed
                    ? "Hidden. Monitoring and the bar skip this device."
                    : "Hide this device from Monitoring and the bar."
                  fontFamily: root.fontFamily
                  panelBackground: Commons.Color.background
                  panelForeground: Commons.Color.foreground
                  panelBorder: Commons.Color.accent
                }
              }

              CalGlyph {
                id: deviceCal
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.activeOf(deviceBlock.modelData).length > 0
                selected: root.aimed("group", deviceBlock.modelData.uid)
                label: "Calibrate Group"
                reveal: true
                fg: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.calibrateRows(root.activeOf(deviceBlock.modelData))
              }
            }

            Repeater {
              model: deviceBlock.listed
              delegate: Column {
                id: shownRow
                required property var modelData
                width: deviceCol.width
                spacing: Style.space(2)

                ChannelLine {
                  channel: shownRow.modelData
                  indent: Style.space(16)
                  liveTone: true
                  parentDim: deviceBlock.concealed
                  eyeFlush: deviceBlock.eyeFlush
                }

                CalibNote {
                  width: parent.width
                  channel: shownRow.modelData
                  service: root.service
                  fg: root.fg
                  accent: root.accent
                  muted: root.muted
                  fontFamily: root.fontFamily
                }
              }
            }

            Item {
              visible: deviceBlock.tucked.length > 0
              width: parent.width
              height: visible ? Style.space(28) : 0

              Rectangle {
                anchors.fill: parent
                color: root.aimed("blockFold", "d:" + deviceBlock.modelData.uid)
                  ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.14)
                  : (deviceShelf.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05) : "transparent")
              }

              InactiveFold {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                caption: "Hidden " + deviceBlock.tucked.length
                hot: root.aimed("blockFold", "d:" + deviceBlock.modelData.uid)
                mark: deviceBlock.blockOpen ? root.chevronDown : root.chevronRight
              }

              MouseArea {
                id: deviceShelf
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleBlock("d:" + deviceBlock.modelData.uid)
              }
            }

            Repeater {
              model: deviceBlock.blockOpen ? deviceBlock.tucked : []
              delegate: Column {
                id: tuckedRow
                required property var modelData
                width: deviceCol.width
                spacing: Style.space(2)

                ChannelLine {
                  channel: tuckedRow.modelData
                  indent: Style.space(32)
                  liveTone: true
                  parentDim: deviceBlock.concealed
                  eyeFlush: deviceBlock.eyeFlush
                }

                CalibNote {
                  width: parent.width
                  indent: Style.space(32)
                  channel: tuckedRow.modelData
                  service: root.service
                  fg: root.fg
                  accent: root.accent
                  muted: root.muted
                  fontFamily: root.fontFamily
                }
              }
            }

            Item {
              visible: deviceBlock.idle.length > 0
              width: parent.width
              height: visible ? Style.space(28) : 0

              Rectangle {
                anchors.fill: parent
                color: root.aimed("hidden", deviceBlock.modelData.uid)
                  ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.14)
                  : (foldMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05) : "transparent")
              }

              InactiveFold {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                count: deviceBlock.idle.length
                hot: root.aimed("hidden", deviceBlock.modelData.uid)
                mark: deviceBlock.open ? root.chevronDown : root.chevronRight
              }

              MouseArea {
                id: foldMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleFold(deviceBlock.modelData.uid)
              }
            }

            Repeater {
              model: deviceBlock.open ? deviceBlock.idle : []
              delegate: Column {
                id: hiddenRow
                required property var modelData
                width: deviceCol.width
                spacing: Style.space(2)

                ChannelLine {
                  channel: hiddenRow.modelData
                  indent: Style.space(32)
                  liveTone: false
                  parentDim: deviceBlock.concealed
                  eyeFlush: deviceBlock.eyeFlush
                }

                CalibNote {
                  width: parent.width
                  indent: Style.space(32)
                  channel: hiddenRow.modelData
                  service: root.service
                  fg: root.fg
                  accent: root.accent
                  muted: root.muted
                  fontFamily: root.fontFamily
                }
              }
            }
            }
          }
        }
      }
    }
  }
}
