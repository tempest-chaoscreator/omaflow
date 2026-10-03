import QtQuick
import qs.Commons
import "Calib.js" as Calib

// One channel's calibration. Progress comes from the daemon batch.
// The saved map stays under it, including after a later failed attempt.
Item {
  id: root

  property var channel: null
  property var service: null
  property color fg: Color.foreground
  property color accent: Color.accent
  property color muted: Qt.darker(fg, 1.4)
  property string fontFamily: Style.font.family

  readonly property string deviceUid: channel && channel.deviceUid ? String(channel.deviceUid) : ""
  readonly property string channelName: channel && channel.name ? String(channel.name) : ""
  readonly property var entry: Calib.findEntry(service ? service.calibrationBatch : null, deviceUid, channelName)
  readonly property var saved: Calib.findCalibration(service ? service.calibrations : null, deviceUid, channelName)
  readonly property var live: Calib.statusOf(service ? service.calibrationStatus : null, deviceUid, channelName)
  readonly property string progressText: Calib.progressLine(entry, live)
  readonly property string failText: Calib.failureLine(entry)
  readonly property string summaryText: Calib.summaryLine(saved)
  readonly property var warningLines: Calib.warningLines(saved)
  readonly property string nextText: Calib.nextLine(saved)
  readonly property var samples: Calib.upSamples(saved)
  readonly property bool hasContent: progressText !== "" || failText !== "" || summaryText !== ""
    || warningLines.length > 0 || nextText !== "" || samples.length > 1

  visible: hasContent
  width: parent ? parent.width : 0
  implicitHeight: inner.implicitHeight
  height: visible ? implicitHeight : 0

  Column {
    id: inner
    x: Style.space(16)
    width: Math.max(0, root.width - x - Style.space(4))
    spacing: Style.space(4)
    visible: root.hasContent

    Text {
      width: parent.width
      visible: root.progressText !== ""
      text: root.progressText
      wrapMode: Text.WordWrap
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.space(12)
    }

    Text {
      width: parent.width
      visible: root.failText !== ""
      text: root.failText
      wrapMode: Text.WordWrap
      color: Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.space(12)
    }

    Text {
      width: parent.width
      visible: root.summaryText !== ""
      text: root.summaryText
      wrapMode: Text.WordWrap
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.space(12)
    }

    Repeater {
      model: root.warningLines
      delegate: Text {
        required property var modelData
        width: parent.width
        text: String(modelData)
        wrapMode: Text.WordWrap
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.space(12)
      }
    }

    CalibGraph {
      width: parent.width
      visible: root.samples.length > 1
      height: visible ? Style.space(80) : 0
      samples: root.samples
      stroke: root.accent
      foreground: root.fg
      fontFamily: root.fontFamily
    }

    Text {
      width: parent.width
      visible: root.nextText !== ""
      text: root.nextText
      wrapMode: Text.WordWrap
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.space(12)
    }
  }
}
