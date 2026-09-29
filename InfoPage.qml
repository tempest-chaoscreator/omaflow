import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// About this window: version and the keys that move through it.
Column {
  id: root

  property bool keyed: false
  property color fg: Color.foreground
  property color muted: Qt.darker(fg, 1.4)
  property string fontFamily: Style.font.family
  property string version: "2.0.0"
  property string author: "Tempest"
  property string homepage: "https://github.com/tempest-chaoscreator/omaflow-plugin"
  readonly property int capH: Style.space(22)
  readonly property int capW: Math.max(Style.space(72), Math.ceil(capMeasure.width) + Style.space(16))
  readonly property var keyColumns: [
    [
      { heading: "Move" },
      { keys: "up", label: "previous control" },
      { keys: "down", label: "next control" },
      { keys: "left", label: "left control" },
      { keys: "right", label: "right control" },
      { keys: "tab", label: "rail and page" },
      { keys: "shift-tab", label: "rail and page" },
      { keys: "enter", label: "activate" },
      { keys: "escape", label: "close" }
    ],
    [
      { heading: "Change" },
      { keys: "left / right", label: "slider" },
      { keys: "wheel", label: "slider" },
      { keys: "enter", label: "eye, link, apply" },
      { heading: "Look" },
      { keys: "right", label: "info, from settings" }
    ]
  ]

  width: parent ? parent.width : 0
  spacing: Style.space(14)

  function moveNav(dx, dy) {}
  function activateNav() {}

  function readManifest(raw) {
    try {
      var obj = JSON.parse(String(raw || ""))
      if (obj.version) version = String(obj.version)
      if (obj.author) author = String(obj.author)
      if (obj.homepage) homepage = String(obj.homepage)
    } catch (e) {}
  }

  function filePath(url) {
    var text = String(url || "")
    if (text.indexOf("file://") === 0) text = text.substring(7)
    try { text = decodeURIComponent(text) } catch (e) {}
    return text
  }

  FileView {
    path: root.filePath(Qt.resolvedUrl("manifest.json"))
    watchChanges: false
    printErrors: false
    onLoaded: root.readManifest(text())
  }

  Text {
    text: "Omaflow"
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.space(16)
    font.bold: true
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Version " + root.version + "  ·  " + root.author
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.space(13)
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: root.homepage
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  TextMetrics {
    id: capMeasure
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    text: "left / right"
  }

  Item {
    width: parent.width
    height: keysTitle.implicitHeight

    Text {
      id: keysTitle
      anchors.left: parent.left
      text: "Keys"
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.space(13)
      font.bold: true
    }

    Text {
      anchors.right: parent.right
      anchors.baseline: keysTitle.baseline
      text: "esc closes"
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Row {
    width: parent.width
    spacing: Style.space(24)

    Repeater {
      model: root.keyColumns
      delegate: Column {
        id: keyCol
        required property var modelData
        required property int index
        width: Math.max(1, Math.floor((parent.width - Style.space(24)) / 2))
        spacing: Style.space(4)

        Repeater {
          model: keyCol.modelData
          delegate: Item {
            id: keySlot
            required property var modelData
            required property int index
            readonly property bool heading: modelData.heading !== undefined
            width: keyCol.width
            height: heading ? root.capH : root.capH + Style.space(4)

            Text {
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              visible: keySlot.heading
              text: keySlot.modelData.heading || ""
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.capitalization: Font.AllUppercase
              font.letterSpacing: 1
            }

            Rectangle {
              id: capBox
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              visible: !keySlot.heading
              width: root.capW
              height: root.capH
              radius: Style.space(4)
              color: "transparent"
              border.width: 1
              border.color: root.muted

              Text {
                anchors.fill: parent
                anchors.margins: 1
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: keySlot.modelData.keys || ""
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Text {
              anchors.left: capBox.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: !keySlot.heading
              text: keySlot.modelData.label || ""
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Enter runs the highlighted control. The eye hides a device from Monitoring and the bar. A group made of only that device hides with it. The link beside a Modes name shares one curve. The pump keeps its own. The axis lock on LCD zeroes the preview and saves it. Left and right change a slider when the arrow has nowhere else to go, and the wheel does the same. Saturation deepens the theme colors and keeps their hue."
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "The bar chip and this window are both clients of coolercontrold at 127.0.0.1:11987. There is no address to type. Fan writes stay on the daemon."
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
