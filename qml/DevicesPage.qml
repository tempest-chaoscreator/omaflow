import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "CcMap.js" as Cc
import "Nav.js" as Nav
import "ThemePalette.js" as ThemePalette

// Device list. Custom groups are their own section. Stopped headers fold
// one step further right than the spinning fans.
// The row models stay put across polls. A fresh array each second used to
// destroy the hovered row and restart the tooltip delay.
Column {
  id: root

  property var service: null
  property bool keyed: false
  property int navIndex: 0
  property color fg: Color.foreground
  property color accent: Color.accent
  property color line: Qt.rgba(fg.r, fg.g, fg.b, 0.16)
  property color muted: Qt.darker(fg, 1.4)
  property string fontFamily: Style.font.family
  property var opened: ({})
  property var palette: []
  property var stableGroups: []
  property var stableShared: []
  property var sectionOrder: ["devices"]
  // nf-md-eye U+F0208, nf-md-eye_off_outline U+F06D1
  readonly property string eyeOn: "\uDB80\uDE08"
  readonly property string eyeOff: "\uDB81\uDED1"
  // nf-md-chevron_right_box_outline U+F09DB, nf-md-chevron_down_box U+F09D6
  readonly property string chevronRight: "\uDB82\uDDDB"
  readonly property string chevronDown: "\uDB82\uDDD6"

  width: parent ? parent.width : 0
  spacing: Style.space(8)

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
      return String(a.name).localeCompare(String(b.name))
    })
    return out
  }
  readonly property var sections: sectionList(pinOn, sharedCards.length)
  // Membership only. RPM numbers stay out so a poll does not rebuild the rows.
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
      for (n = 0; n < shown.length; n++) shownKeys.push(shown[n].key)
      for (n = 0; n < hidden.length; n++) hiddenKeys.push(hidden[n].key)
      parts.push([group.uid, group.name, group.type, shownKeys.join(","), hiddenKeys.join(",")].join("~"))
    }
    var cards = sharedCards
    for (i = 0; i < cards.length; i++) {
      var memberKeys = []
      var members = cards[i].rows || []
      for (n = 0; n < members.length; n++) {
        memberKeys.push(members[n].key + (Number(members[n].rpm) > 0 ? "+" : "-"))
      }
      parts.push(["s", cards[i].id, cards[i].name, memberKeys.join(",")].join("~"))
    }
    parts.push(pinOn ? "pin" : "tail")
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
    function placeFans(rows) {
      var list = rows || []
      var n
      for (n = 0; n < list.length; n++) {
        if (!list[n] || !list[n].key) continue
        place({ kind: "fan", key: list[n].key })
      }
    }
    function placeDevice(group) {
      var rowY = y
      var spinning = activeOf(group).length > 0
      if (spinning) out.push({ kind: "group", uid: group.uid, x: 0, y: rowY })
      out.push({ kind: "eye", uid: group.uid, x: spinning ? 1 : 0, y: rowY })
      y += 1
      placeFans(group.shown)
      if ((group.hidden || []).length) place({ kind: "hidden", uid: group.uid })
      if (opened[group.uid] === true) placeFans(group.hidden)
    }
    function placeShared(card) {
      if (jobsFor(card.rows).length) place({ kind: "shared", id: card.id })
      var moving = []
      var still = stoppedRows(card.rows)
      var rows = card.rows || []
      var n
      for (n = 0; n < rows.length; n++) if (Number(rows[n].rpm) > 0) moving.push(rows[n])
      placeFans(moving)
      if (still.length) place({ kind: "groupFold", id: card.id })
      if (opened[card.id] === true) placeFans(still)
    }
    if (jobsFor(everyActive()).length) place({ kind: "all" })
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

  function stoppedRows(rows) {
    var out = []
    var list = rows || []
    for (var i = 0; i < list.length; i++) if (!(Number(list[i].rpm) > 0)) out.push(list[i])
    return out
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
    var channels = service && service.channels ? service.channels : []
    var saved = service && service.groups ? service.groups : []
    return ThemePalette.swatch(palette, ThemePalette.keysOf(channels, saved), key)
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

  function moveNav(dx, dy) {
    navIndex = Nav.step(navItems, navIndex, dx, dy)
  }

  function activateNav() {
    var item = navItems[navIndex]
    if (!item) return
    if (item.kind === "hidden" || item.kind === "groupFold") toggleFold(item.uid || item.id)
    else if (item.kind === "eye") toggleDevice(item.uid)
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
    var item = navItems[navIndex]
    if (!item || item.kind !== kind) return false
    if (kind === "hidden" || kind === "group" || kind === "eye") return item.uid === id
    if (kind === "shared" || kind === "groupFold") return item.id === id
    if (kind === "fan") return item.key === id
    return kind === "all"
  }

  function toggleFold(uid) {
    var next = ({})
    for (var k in opened) next[k] = opened[k]
    next[uid] = next[uid] !== true
    opened = next
  }

  function deviceHidden(uid) {
    var map = service && service.hiddenDevices ? service.hiddenDevices : null
    return !!(map && map[uid] === true)
  }

  function rowsHidden(rows) {
    var list = rows || []
    if (!list.length) return false
    var seen = false
    for (var i = 0; i < list.length; i++) {
      var uid = list[i] && list[i].deviceUid
      if (!uid) continue
      seen = true
      if (!deviceHidden(uid)) return false
    }
    return seen
  }

  function toggleDevice(uid) {
    if (!service || !uid) return
    service.setDeviceHidden(uid, !deviceHidden(uid))
  }

  function dutyText(channel) {
    var src = channelOf(channel) || {}
    var duty = isFinite(Number(src.duty)) ? Math.round(Number(src.duty)) + "%" : "—"
    var rpm = isFinite(Number(src.rpm)) ? Math.round(Number(src.rpm)) + " rpm" : ""
    return rpm ? duty + "    " + rpm : duty
  }

  function fanTip(channel) {
    var src = channelOf(channel) || {}
    var name = src.label || src.name || "fan"
    return "Calibrate " + name
  }

  function fanOn(channel) {
    var src = channelOf(channel)
    return Number(src && src.rpm) > 0
  }

  function inactiveLabel(count) {
    return "Inactive " + count
  }

  component InactiveFold: Item {
    id: fold
    property int count: 0
    property string mark: ""
    property bool hot: false
    readonly property int gap: Style.space(6)
    implicitWidth: word.implicitWidth + gap + markText.implicitWidth
    implicitHeight: Math.max(word.implicitHeight, markText.implicitHeight)

    Text {
      id: word
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: root.inactiveLabel(fold.count)
      color: fold.hot ? root.accent : root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.space(12)
    }

    Text {
      id: markText
      anchors.left: word.right
      anchors.leftMargin: fold.gap
      anchors.baseline: word.baseline
      text: fold.mark
      color: word.color
      font.family: root.fontFamily
      font.pixelSize: word.font.pixelSize
    }
  }

  onStructureSigChanged: applyStable()
  Connections {
    target: root.service
    function onPinGroupsChanged() { root.applyStable() }
  }
  Component.onCompleted: {
    applyStable()
    if (!palette.length) palette = ThemePalette.ramp("", accent, Color.urgent)
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.palette = ThemePalette.ramp(text(), root.accent, Color.urgent)
    onFileChanged: reload()
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

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    visible: root.service && root.service.lastError === "" && root.service.notice !== ""
    text: root.service ? root.service.notice : ""
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: root.sectionOrder
    delegate: Column {
      id: section
      required property var modelData
      required property int index
      width: root.width
      spacing: Style.space(8)

      // The break sits between the two lists in either order. Pin only
      // chooses which list is first.
      Item {
        width: parent.width
        visible: section.index > 0
        height: section.index > 0 ? Style.space(16) : 0
      }

      Rectangle {
        width: parent.width
        visible: section.index > 0
        height: section.index > 0 ? 1 : 0
        color: root.line
      }

      Column {
        width: parent.width
        spacing: Style.space(8)
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
          delegate: Item {
            id: sharedBlock
            required property var modelData
            required property int index
            readonly property var idle: root.stoppedRows(modelData.rows)
            readonly property bool open: root.opened[modelData.id] === true
            width: root.width
            implicitHeight: sharedCol.implicitHeight
            height: implicitHeight
            opacity: root.rowsHidden(modelData.rows) ? 0.38 : 1

            Rectangle {
              width: Style.space(3)
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 1
              color: root.swatchFor("g:" + sharedBlock.modelData.id)
            }

            Column {
              id: sharedCol
              width: parent.width
              spacing: Style.space(2)

            Item {
              width: parent.width
              height: Style.space(28)

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                anchors.right: sharedCal.visible ? sharedCal.left : parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: sharedBlock.modelData.name
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
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
              model: sharedBlock.modelData.rows
              delegate: Column {
                id: sharedRow
                required property var modelData
                visible: Number(modelData.rpm) > 0
                width: sharedBlock.width
                spacing: Style.space(2)

                Item {
                  width: parent.width
                  height: Style.space(22)
                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(16)
                    anchors.right: sharedDuty.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: sharedRow.modelData.label || sharedRow.modelData.name
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(12)
                    elide: Text.ElideRight
                  }
                  Text {
                    id: sharedDuty
                    anchors.right: sharedFan.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.dutyText(sharedRow.modelData)
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(12)
                  }
                  CalGlyph {
                    id: sharedFan
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    label: root.fanTip(sharedRow.modelData)
                    reveal: true
                    selected: root.aimed("fan", sharedRow.modelData.key)
                    fg: root.fg
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.calibrateOne(sharedRow.modelData)
                  }
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
                anchors.leftMargin: Style.space(32)
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
                width: sharedBlock.width
                spacing: Style.space(2)

                Item {
                  width: parent.width
                  height: Style.space(22)
                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(48)
                    anchors.right: sharedIdleDuty.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: sharedIdle.modelData.label || sharedIdle.modelData.name
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(12)
                    elide: Text.ElideRight
                  }
                  Text {
                    id: sharedIdleDuty
                    anchors.right: sharedIdleFan.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.dutyText(sharedIdle.modelData)
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(12)
                  }
                  CalGlyph {
                    id: sharedIdleFan
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    label: root.fanTip(sharedIdle.modelData)
                    reveal: true
                    selected: root.aimed("fan", sharedIdle.modelData.key)
                    fg: root.fg
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.calibrateOne(sharedIdle.modelData)
                  }
                }

                CalibNote {
                  width: parent.width
                  channel: sharedIdle.modelData
                  service: root.service
                  fg: root.fg
                  accent: root.accent
                  muted: root.muted
                  fontFamily: root.fontFamily
                }
              }
            }

            Rectangle {
              width: parent.width
              height: 1
              color: root.line
            }
            }
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: section.modelData === "devices"

        Repeater {
          model: root.stableGroups
          delegate: Item {
            id: deviceBlock
            required property var modelData
            required property int index
            readonly property bool concealed: root.deviceHidden(modelData.uid)
            readonly property var idle: modelData.hidden || []
            readonly property bool open: root.opened[modelData.uid] === true
            width: root.width
            implicitHeight: deviceCol.implicitHeight
            height: implicitHeight
            opacity: concealed ? 0.38 : 1

            Rectangle {
              width: Style.space(3)
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 1
              color: root.swatchFor("d:" + deviceBlock.modelData.uid)
            }

            Column {
              id: deviceCol
              width: parent.width
              spacing: Style.space(2)

            Item {
              width: parent.width
              height: Style.space(28)

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                anchors.right: eyeHit.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: String(deviceBlock.modelData.name || "Device").toUpperCase()
                color: deviceBlock.concealed ? root.muted : root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 0.6
                elide: Text.ElideRight
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
                  panelBackground: Color.background
                  panelForeground: Color.foreground
                  panelBorder: Color.accent
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
              model: deviceBlock.modelData.shown || []
              delegate: Column {
                id: shownRow
                required property var modelData
                width: deviceBlock.width
                spacing: Style.space(2)

                Item {
                  width: parent.width
                  height: Style.space(22)

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(16)
                    anchors.right: dutyLabel.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: shownRow.modelData.label || shownRow.modelData.name
                    color: root.fanOn(shownRow.modelData) ? root.fg : root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(12)
                    elide: Text.ElideRight
                  }

                  Text {
                    id: dutyLabel
                    anchors.right: shownFan.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.dutyText(shownRow.modelData)
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(12)
                  }

                  CalGlyph {
                    id: shownFan
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    label: root.fanTip(shownRow.modelData)
                    reveal: true
                    selected: root.aimed("fan", shownRow.modelData.key)
                    fg: root.fg
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.calibrateOne(shownRow.modelData)
                  }
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
                anchors.leftMargin: Style.space(32)
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
                width: deviceBlock.width
                spacing: Style.space(2)

                Item {
                  width: parent.width
                  height: Style.space(22)
                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(48)
                    anchors.right: hiddenDuty.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: hiddenRow.modelData.label || hiddenRow.modelData.name
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(12)
                    elide: Text.ElideRight
                  }
                  Text {
                    id: hiddenDuty
                    anchors.right: hiddenFan.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.dutyText(hiddenRow.modelData)
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(12)
                  }
                  CalGlyph {
                    id: hiddenFan
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    label: root.fanTip(hiddenRow.modelData)
                    reveal: true
                    selected: root.aimed("fan", hiddenRow.modelData.key)
                    fg: root.fg
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: root.calibrateOne(hiddenRow.modelData)
                  }
                }

                CalibNote {
                  width: parent.width
                  channel: hiddenRow.modelData
                  service: root.service
                  fg: root.fg
                  accent: root.accent
                  muted: root.muted
                  fontFamily: root.fontFamily
                }
              }
            }

            Rectangle {
              width: parent.width
              height: 1
              color: root.line
            }
            }
          }
        }
      }
    }
  }
}
