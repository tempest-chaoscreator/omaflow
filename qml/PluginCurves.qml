import QtQuick
import qs.Commons
import qs.Commons as Commons
import "CcMap.js" as Cc

// Read-only curves for the mode selected in the bar plugin.
Column {
  id: root

  property var service: null
  property string modeUid: ""
  property color fg: Commons.Color.foreground
  property color accent: Commons.Color.accent
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

  function groupIndex() {
    var named = ({})
    var groups = service && service.groups ? service.groups : []
    for (var i = 0; i < groups.length; i++) {
      var keys = groups[i].members || []
      var name = groups[i].name || "Group"
      for (var m = 0; m < keys.length; m++) {
        var bucket = named[keys[m]]
        if (!bucket) named[keys[m]] = bucket = []
        if (bucket.indexOf(name) < 0) bucket.push(name)
      }
    }
    return named
  }

  function buildCurves() {
    if (!mode || !service) return []
    var hidden = service.hiddenDevices || ({})
    var named = groupIndex()
    var members = Cc.modeMembers(mode, service.channels, service.profiles)
    var order = []
    var by = ({})
    for (var i = 0; i < members.length; i++) {
      var row = members[i]
      if (hidden[String(row.deviceUid || "")] === true) continue
      var id = row.profileUid || ("fixed:" + row.key)
      var card = by[id]
      if (!card) {
        card = by[id] = {
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
      card.labels.push(device ? (device + "  ·  " + fan) : fan)
      var names = named[row.key] || []
      for (var g = 0; g < names.length; g++) {
        if (card.groups.indexOf(names[g]) < 0) card.groups.push(names[g])
      }
      if (row.isPump) {
        card.pump = true
        card.minDuty = Math.max(card.minDuty, Number(row.minDuty) || 0)
      }
    }
    var out = []
    for (var n = 0; n < order.length; n++) out.push(by[order[n]])
    return out
  }

  // The whole graph is the key. A resampled curve can change in the middle
  // while the ends stay, and the pump floor caption follows minDuty.
  function curveSignature(board) {
    var parts = [modeUid || ""]
    var list = board || []
    for (var i = 0; i < list.length; i++) {
      var card = list[i]
      var pts = card.points || []
      var flat = []
      for (var p = 0; p < pts.length; p++) {
        if (!pts[p] || pts[p].length < 2) continue
        flat.push(pts[p][0] + "," + pts[p][1])
      }
      parts.push([
        card.id || "",
        (card.groups || []).join("+"),
        (card.labels || []).join("+"),
        flat.join(";"),
        card.fixed === null || card.fixed === undefined ? "" : String(card.fixed),
        card.pump ? "p" : "f",
        String(Number(card.minDuty) || 0)
      ].join("~"))
    }
    return parts.join("|")
  }

  function floorNote(card) {
    var label = Cc.floorCaption(card && card.pump, card && card.minDuty)
    return label ? ("  ·  " + label) : ""
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
    textFormat: Text.PlainText
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: root.stableCurves
    delegate: Rectangle {
      id: card
      required property var modelData
      readonly property var drawn: root.shownPoints(modelData)
      width: root.width
      implicitHeight: cardCol.implicitHeight + Style.space(20)
      height: implicitHeight
      color: "transparent"
      border.width: 1
      border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.22)

      Column {
      id: cardCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      spacing: Style.space(4)

      Text {
        width: parent.width
        visible: (modelData.groups || []).length > 0
        text: (modelData.groups || []).join("  ·  ")
        textFormat: Text.PlainText
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: (modelData.labels || []).join("  ·  ") + root.floorNote(modelData)
        textFormat: Text.PlainText
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
      }

      CurveView {
        width: parent.width
        height: card.drawn.length > 1 ? Style.space(110) : 0
        visible: height > 0
        interactive: false
        points: card.drawn
        minDuty: modelData.minDuty || 0
        foreground: root.fg
        accent: root.accent
        fontFamily: root.fontFamily
      }

      Text {
        width: parent.width
        visible: card.drawn.length < 2
        text: "No curve stored for this channel."
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      }
    }
  }
}
