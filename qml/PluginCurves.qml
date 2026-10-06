import QtQuick
import qs.Commons
import "CcMap.js" as Cc

// Read-only curves for the mode selected in the bar plugin.
Column {
  id: root

  property var service: null
  property string modeUid: ""
  property color fg: Color.foreground
  property color accent: Color.accent
  property color muted: Qt.darker(fg, 1.4)
  property string fontFamily: Style.font.family

  property var stableCurves: []

  width: parent ? parent.width : 0
  spacing: Style.space(8)

  readonly property var mode: {
    var list = service && service.modes ? service.modes : []
    for (var i = 0; i < list.length; i++) if (list[i].uid === modeUid) return list[i]
    return null
  }
  readonly property var curveBoard: buildCurves()
  readonly property string curveSig: curveSignature(curveBoard)

  function concealed(uid) {
    var map = service && service.hiddenDevices ? service.hiddenDevices : ({})
    return map[String(uid || "")] === true
  }

  function groupNames(key) {
    var names = []
    var groups = service && service.groups ? service.groups : []
    var i
    var m
    for (i = 0; i < groups.length; i++) {
      var members = groups[i].members || []
      for (m = 0; m < members.length; m++) {
        if (members[m] !== key) continue
        var name = groups[i].name || "Group"
        if (names.indexOf(name) < 0) names.push(name)
      }
    }
    return names
  }

  function buildCurves() {
    if (!mode || !service) return []
    var members = Cc.modeMembers(mode, service.channels, service.profiles)
    var order = []
    var by = ({})
    for (var i = 0; i < members.length; i++) {
      var row = members[i]
      if (concealed(row.deviceUid)) continue
      var id = row.profileUid || ("fixed:" + row.key)
      if (!by[id]) {
        by[id] = {
          id: id,
          labels: [],
          groups: [],
          points: row.points || [],
          fixed: row.fixed,
          minDuty: Number(row.minDuty) || 0,
          pump: row.isPump === true
        }
        order.push(id)
      }
      var fan = row.label || row.name || ""
      var device = row.deviceName || ""
      by[id].labels.push(device ? (device + "  ·  " + fan) : fan)
      var names = groupNames(row.key)
      var g
      for (g = 0; g < names.length; g++) {
        if (by[id].groups.indexOf(names[g]) < 0) by[id].groups.push(names[g])
      }
      if (row.isPump) {
        by[id].pump = true
        by[id].minDuty = Math.max(by[id].minDuty, Number(row.minDuty) || 0)
      }
    }
    var out = []
    for (var n = 0; n < order.length; n++) out.push(by[order[n]])
    return out
  }

  function curveSignature(board) {
    var parts = []
    var list = board || []
    for (var i = 0; i < list.length; i++) {
      var card = list[i]
      var pts = card.points || []
      var ends = pts.length ? (pts[0][0] + "," + pts[0][1] + ":" + pts[pts.length - 1][0] + "," + pts[pts.length - 1][1]) : ""
      parts.push([
        card.id || "",
        (card.groups || []).join("+"),
        (card.labels || []).join("+"),
        String(pts.length),
        ends,
        card.fixed === null || card.fixed === undefined ? "" : String(card.fixed),
        card.pump ? "p" : "f"
      ].join("~"))
    }
    return (modeUid || "") + "|" + parts.join("|")
  }

  function shownPoints(card) {
    if (!card) return []
    if (card.points && card.points.length > 1) return card.points
    if (card.fixed !== null && card.fixed !== undefined)
      return Cc.spreadPoints([[0, card.fixed], [100, card.fixed]], card.minDuty || 0)
    return []
  }

  onCurveSigChanged: stableCurves = curveBoard
  Component.onCompleted: stableCurves = curveBoard

  Text {
    width: parent.width
    visible: root.mode && root.stableCurves.length === 0
    wrapMode: Text.WordWrap
    text: (root.mode ? root.mode.name : "This mode") + " has no curves yet."
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: root.stableCurves
    delegate: Column {
      required property var modelData
      width: root.width
      spacing: Style.space(4)

      Text {
        width: parent.width
        visible: (modelData.groups || []).length > 0
        text: (modelData.groups || []).join("  ·  ")
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: (modelData.labels || []).join("  ·  ") + (modelData.pump ? "  ·  floor 50%" : "")
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
      }

      CurveView {
        width: parent.width
        height: root.shownPoints(modelData).length > 1 ? Style.space(110) : 0
        visible: height > 0
        interactive: false
        points: root.shownPoints(modelData)
        minDuty: modelData.minDuty || 0
        foreground: root.fg
        accent: root.accent
        fontFamily: root.fontFamily
      }

      Text {
        width: parent.width
        visible: root.shownPoints(modelData).length < 2
        text: "No curve stored for this channel."
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
