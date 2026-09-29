import QtQuick
import qs.Commons
import qs.Ui
import "CcMap.js" as Cc
import "Nav.js" as Nav

// Device list. Spinning headers stay open. Stopped headers stay folded.
// Calibrate sits on the row that owns those fans, including a shared curve.
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
  // nf-md-eye U+F0208, nf-md-eye_off_outline U+F06D1
  readonly property string eyeOn: "\uDB80\uDE08"
  readonly property string eyeOff: "\uDB81\uDED1"

  width: parent ? parent.width : 0
  spacing: Style.space(8)

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
        var ar = Number(a.rpm) > 0 ? 0 : 1
        var br = Number(b.rpm) > 0 ? 0 : 1
        if (ar !== br) return ar - br
        return String(a.label || "").localeCompare(String(b.label || ""))
      })
      out.push({ id: saved[g].id, name: saved[g].name || "Shared", rows: rows })
    }
    out.sort(function(a, b) {
      var ah = rowsHidden(a.rows) ? 1 : 0
      var bh = rowsHidden(b.rows) ? 1 : 0
      if (ah !== bh) return ah - bh
      return String(a.name).localeCompare(String(b.name))
    })
    return out
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
    var g
    if (sharedCards.length) place({ kind: "all" })
    for (g = 0; g < sharedCards.length; g++) {
      if (jobsFor(sharedCards[g].rows).length) place({ kind: "shared", id: sharedCards[g].id })
    }
    for (g = 0; g < groups.length; g++) {
      var rowY = y
      if (activeOf(groups[g]).length) {
        var cal = { kind: "group", uid: groups[g].uid, x: 0, y: rowY }
        out.push(cal)
      }
      out.push({ kind: "eye", uid: groups[g].uid, x: activeOf(groups[g]).length ? 1 : 0, y: rowY })
      y += 1
      if ((groups[g].hidden || []).length) place({ kind: "hidden", uid: groups[g].uid })
    }
    return out
  }

  function activeOf(group) {
    var out = []
    var shown = group && group.shown ? group.shown : []
    for (var i = 0; i < shown.length; i++) if (Number(shown[i].rpm) > 0) out.push(shown[i])
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

  function moveNav(dx, dy) {
    navIndex = Nav.step(navItems, navIndex, dx, dy)
  }

  function activateNav() {
    var item = navItems[navIndex]
    if (!item) return
    if (item.kind === "hidden") toggleFold(item.uid)
    else if (item.kind === "eye") toggleDevice(item.uid)
    else if (item.kind === "all") calibrateRows(everyActive())
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
    if (kind === "shared") return item.id === id
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
    var duty = isFinite(Number(channel.duty)) ? Math.round(Number(channel.duty)) + "%" : "—"
    var rpm = isFinite(Number(channel.rpm)) ? Math.round(Number(channel.rpm)) + " rpm" : ""
    return rpm ? duty + "    " + rpm : duty
  }

  Column {
    width: parent.width
    spacing: Style.space(8)
    visible: root.sharedCards.length > 0

    Item {
      width: parent.width
      height: Style.space(28)
      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "Shared curves"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.space(13)
        font.bold: true
      }
      SquareButton {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: Style.space(22)
        text: "Calibrate all"
        selected: root.aimed("all", "")
        onClicked: root.calibrateRows(root.everyActive())
      }
    }

    Repeater {
      model: root.sharedCards
      delegate: Column {
        id: sharedBlock
        required property var modelData
        required property int index
        width: root.width
        spacing: Style.space(2)
        opacity: root.rowsHidden(modelData.rows) ? 0.38 : 1

        Item {
          width: parent.width
          height: Style.space(28)

          Rectangle {
            width: Style.space(3)
            height: parent.height
            color: root.accent
          }

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

          SquareButton {
            id: sharedCal
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.jobsFor(sharedBlock.modelData.rows).length > 0
            height: Style.space(22)
            text: "Calibrate"
            selected: root.aimed("shared", sharedBlock.modelData.id)
            onClicked: root.calibrateRows(sharedBlock.modelData.rows)
          }
        }

        Repeater {
          model: sharedBlock.modelData.rows
          delegate: Item {
            required property var modelData
            width: sharedBlock.width
            height: Style.space(22)
            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.right: sharedDuty.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.label || modelData.name
              color: Number(modelData.rpm) > 0 ? root.fg : root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.space(12)
              elide: Text.ElideRight
            }
            Text {
              id: sharedDuty
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.dutyText(modelData)
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.space(12)
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

  Repeater {
    model: root.groups
    delegate: Column {
      id: deviceBlock
      required property var modelData
      required property int index
      readonly property bool concealed: root.deviceHidden(modelData.uid)
      width: root.width
      spacing: Style.space(2)
      opacity: concealed ? 0.38 : 1

      Item {
        width: parent.width
        height: Style.space(28)

        Rectangle {
          width: Style.space(3)
          height: parent.height
          color: Cc.groupColor(deviceBlock.modelData.type, deviceBlock.modelData.name, deviceBlock.index)
        }

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
            radius: 0
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

        SquareButton {
          id: deviceCal
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: root.activeOf(deviceBlock.modelData).length > 0
          height: Style.space(22)
          text: "Calibrate"
          selected: root.aimed("group", deviceBlock.modelData.uid)
          onClicked: root.calibrateRows(root.activeOf(deviceBlock.modelData))
        }
      }

      Repeater {
        model: deviceBlock.modelData.shown || []
        delegate: Item {
          required property var modelData
          width: deviceBlock.width
          height: Style.space(22)

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.right: dutyLabel.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.label || modelData.name
            color: Number(modelData.rpm) > 0 ? root.fg : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
            elide: Text.ElideRight
          }

          Text {
            id: dutyLabel
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.dutyText(modelData)
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
          }
        }
      }

      Item {
        id: fold
        visible: (deviceBlock.modelData.hidden || []).length > 0
        width: parent.width
        height: visible ? Style.space(28) : 0

        Rectangle {
          anchors.fill: parent
          color: root.aimed("hidden", deviceBlock.modelData.uid)
            ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.14)
            : (foldMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05) : "transparent")
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
          text: (root.opened[deviceBlock.modelData.uid] === true ? "Hide inactive" : "Inactive")
            + "   " + (deviceBlock.modelData.hidden || []).length
          color: root.aimed("hidden", deviceBlock.modelData.uid) ? root.accent : root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.space(12)
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
        model: root.opened[deviceBlock.modelData.uid] === true ? deviceBlock.modelData.hidden : []
        delegate: Item {
          required property var modelData
          width: deviceBlock.width
          height: Style.space(22)
          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.right: hiddenDuty.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.label || modelData.name
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
            elide: Text.ElideRight
          }
          Text {
            id: hiddenDuty
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.dutyText(modelData)
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
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
