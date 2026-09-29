import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Nav.js" as Nav

// The preview and the angle dial share one stage. The preview grows with the window.
// Round glass draws a circle. Square panels draw a square frame, and a non-square
// pixel buffer keeps that aspect. Zero orientation holds the picture level.
// The dot still shows the dial, and that dial angle is what the pump image is rotated by.
Column {
  id: root

  property var service: null
  property bool keyed: false
  property int navIndex: 0
  property int brightness: 80
  property int saturation: 0
  property int angle: 0
  property bool zeroOrientation: true
  property string face: "liquid"
  property string shapeChoice: ""
  property bool syncOn: false
  property bool lcdReady: false
  property bool touched: false
  property bool pushing: false
  property bool viewReady: false
  property string pushed: ""
  property color fg: Color.foreground
  property color accent: Color.accent
  property color accent2: Color.accent
  property color muted: Qt.darker(fg, 1.4)
  property string fontFamily: Style.font.family

  width: parent ? parent.width : 0
  spacing: Style.space(12)

  readonly property var screen: service && service.lcdChannels && service.lcdChannels.length ? service.lcdChannels[0] : null
  readonly property var temps: service && service.temps ? service.temps : ({})
  readonly property color ink: deepen(accent, saturation)
  readonly property color ink2: deepen(accent2, saturation)
  readonly property bool combo: face === "cpu-gpu" || face === "cpu-liquid"
  readonly property int previewAngle: zeroOrientation ? 0 : angle
  readonly property string detectedShape: detectShape()
  readonly property string shownShape: (shapeChoice === "round" || shapeChoice === "square") ? shapeChoice : detectedShape
  readonly property real frameAspect: frameRatio()
  readonly property var faces: [
    { id: "liquid", label: "Liquid" },
    { id: "cpu", label: "CPU" },
    { id: "cpu-gpu", label: "CPU | GPU" },
    { id: "cpu-liquid", label: "CPU | Liquid" }
  ]
  // Round and Square sit on the bottom row, opposite Sync and Off.
  readonly property var navItems: [
    { id: "face", face: 0, x: 0, y: 0 },
    { id: "face", face: 1, x: 1, y: 0 },
    { id: "face", face: 2, x: 2, y: 0 },
    { id: "face", face: 3, x: 3, y: 0 },
    { id: "zero", x: 6, y: 0 },
    { id: "ccw", x: 0, y: 1 },
    { id: "cw", x: 2, y: 1 },
    { id: "sync", x: 0, y: 2 },
    { id: "off", x: 1, y: 2 },
    { id: "shape", shape: "round", x: 5, y: 2 },
    { id: "shape", shape: "square", x: 6, y: 2 },
    { id: "bright", x: 0, y: 3 },
    { id: "sat", x: 1, y: 3 }
  ]

  // Same hue as the theme. Higher values raise saturation and lower lightness a little.
  function deepen(base, amount) {
    var t = Math.max(0, Math.min(100, Number(amount) || 0)) / 100
    var s = base.hslSaturation + (1 - base.hslSaturation) * t * 0.55
    var l = base.hslLightness * (1 - 0.18 * t)
    if (s > 1) s = 1
    if (l < 0.2) l = 0.2
    return Qt.hsla(base.hslHue, s, l, 1)
  }

  function whole(value) {
    var n = Number(value)
    return isFinite(n) ? String(Math.round(n)) : "—"
  }

  function primaryText() {
    if (face === "cpu" || face === "cpu-gpu" || face === "cpu-liquid") return whole(temps.cpu)
    return whole(temps.coolant)
  }

  function secondaryText() {
    if (face === "cpu-gpu") return whole(temps.gpu)
    if (face === "cpu-liquid") return whole(temps.coolant)
    return ""
  }

  function primaryLabel() {
    if (face === "cpu" || combo) return "CPU"
    return "LIQUID"
  }

  function secondaryLabel() {
    if (face === "cpu-gpu") return "GPU"
    if (face === "cpu-liquid") return "LIQUID"
    return ""
  }

  function hexByte(part) {
    var n = Math.max(0, Math.min(255, Math.round(Number(part) * 255)))
    var text = n.toString(16)
    return text.length < 2 ? "0" + text : text
  }

  function hexOf(color) {
    return "#" + hexByte(color.r) + hexByte(color.g) + hexByte(color.b)
  }

  function detectShape() {
    var blob = String(screen && screen.deviceName || "").toLowerCase()
    var w = Number(screen && screen.screenWidth) || 0
    var h = Number(screen && screen.screenHeight) || 0
    if (/ryujin|coreliquid/.test(blob)) return "square"
    if (/kraken/.test(blob) && /2023|2024/.test(blob) && blob.indexOf("elite") < 0) return "square"
    if (w > 0 && h > 0 && w !== h) return "square"
    return "round"
  }

  function frameRatio() {
    if (shownShape !== "square") return 1
    var w = Number(screen && screen.screenWidth) || 0
    var h = Number(screen && screen.screenHeight) || 0
    if (w > 0 && h > 0 && w !== h) return w / h
    return 1
  }

  function pixelSize() {
    var w = Number(screen && screen.screenWidth) || 0
    var h = Number(screen && screen.screenHeight) || 0
    if (w > 0 && h > 0) return { w: Math.round(w), h: Math.round(h) }
    return { w: 320, h: 320 }
  }

  function shapeTip(kind) {
    var auto = shapeChoice !== "round" && shapeChoice !== "square"
    var word = kind === "square" ? "Square panel" : "Round glass"
    if (shapeChoice === kind) return word + ". Click again to follow the cooler automatically."
    if (auto && detectedShape === kind) return word + ", detected from this cooler."
    return "Show a " + (kind === "square" ? "square" : "round") + " frame."
  }

  function mark() {
    var px = pixelSize()
    return shownShape + "|" + px.w + "x" + px.h + "|" + face + "|" + primaryText() + "|" + secondaryText() + "|" + hexOf(ink) + "|" + hexOf(ink2) + "|" + brightness + "|" + saturation + "|" + angle
  }

  function indexOf(id) {
    for (var i = 0; i < navItems.length; i++) if (navItems[i].id === id) return i
    return 0
  }

  function readView(raw) {
    try {
      var obj = JSON.parse(String(raw || ""))
      if (obj.face) face = String(obj.face)
      if (isFinite(Number(obj.angle))) angle = ((Math.round(Number(obj.angle)) % 360) + 360) % 360
      if (isFinite(Number(obj.brightness))) brightness = Math.max(0, Math.min(100, Math.round(Number(obj.brightness))))
      if (isFinite(Number(obj.saturation))) saturation = Math.max(0, Math.min(100, Math.round(Number(obj.saturation))))
      if (obj.zeroOrientation !== undefined) zeroOrientation = !!obj.zeroOrientation
      if (obj.shape === "round" || obj.shape === "square") shapeChoice = String(obj.shape)
      touched = true
    } catch (e) {}
    finishView()
  }

  function finishView() {
    if (viewReady) return
    viewReady = true
    if (visible && screen && !lcdReady) pull()
  }

  function writeView() {
    if (!viewReady || !lcdFile.setText) return
    var obj = {
      brightness: brightness,
      saturation: saturation,
      angle: angle,
      face: face,
      zeroOrientation: zeroOrientation
    }
    if (shapeChoice === "round" || shapeChoice === "square") obj.shape = shapeChoice
    lcdFile.setText(JSON.stringify(obj))
  }

  function saveView() {
    if (!viewReady) return
    viewSave.restart()
  }

  function pull() {
    if (!service || !screen || !service.call) return
    var uid = screen.deviceUid
    var channel = screen.name
    service.call("GET", "/devices/" + encodeURIComponent(uid) + "/settings", null, function(res) {
      if (!root.screen || root.screen.deviceUid !== uid) return
      if (res && res.ok) {
        var rows = (res.body && res.body.settings) || []
        for (var i = 0; i < rows.length; i++) {
          if (rows[i].channel_name !== channel || !rows[i].lcd) continue
          var lcd = rows[i].lcd
          if (!root.touched && isFinite(Number(lcd.brightness))) root.brightness = Number(lcd.brightness)
          root.syncOn = String(lcd.mode || "") !== "none"
        }
      }
      root.lcdReady = true
      if (root.syncOn && root.visible) root.push()
    })
  }

  function push() {
    if (!viewReady || !service || !screen || pushing) return
    pushing = true
    var token = mark()
    var px = pixelSize()
    service.pushLcdImage(
      screen.deviceUid, screen.name, brightness, face, angle,
      hexOf(ink), hexOf(ink2), primaryText(), secondaryText(),
      shownShape, px.w, px.h,
      function(res) {
        root.pushing = false
        if (res && res.ok) root.pushed = token
      }
    )
  }

  function turnOff() {
    syncOn = false
    pushed = ""
    if (!service || !screen) return
    service.setLcd(screen.deviceUid, screen.name, {
      brightness: brightness, orientation: 0, colors: [], mode: "none"
    })
  }

  function setFace(id) {
    face = id
    if (syncOn) push()
  }

  function setShape(kind) {
    if (kind !== "round" && kind !== "square") return
    if (shapeChoice === "" && detectedShape === kind) return
    var next = shapeChoice === kind ? "" : kind
    var after = (next === "round" || next === "square") ? next : detectedShape
    var before = shownShape
    shapeChoice = next
    if (syncOn && after !== before) push()
  }

  function shapeIndex(kind) {
    for (var i = 0; i < navItems.length; i++) {
      if (navItems[i].id === "shape" && navItems[i].shape === kind) return i
    }
    return 0
  }

  function setAngle(deg) {
    touched = true
    angle = ((Math.round(deg) % 360) + 360) % 360
    if (syncOn) push()
  }

  function stepAngle(delta) {
    setAngle(angle + delta)
  }

  function setBrightness(value) {
    touched = true
    brightness = Math.max(0, Math.min(100, Math.round(Number(value))))
    if (syncOn) pushDelay.restart()
  }

  function setSaturation(value) {
    touched = true
    saturation = Math.max(0, Math.min(100, Math.round(Number(value))))
    if (syncOn) pushDelay.restart()
  }

  function navAt() {
    return navItems.length ? navItems[Math.max(0, Math.min(navItems.length - 1, navIndex))] : null
  }

  function aimed(id, extra) {
    if (!keyed) return false
    var item = navAt()
    if (!item || item.id !== id) return false
    if (id === "face") return item.face === extra
    if (id === "shape") return item.shape === extra
    return true
  }

  function dotOn(deg) {
    var delta = Math.abs(angle - deg) % 360
    if (delta > 180) delta = 360 - delta
    return delta < 15
  }

  function moveNav(dx, dy) {
    var item = navAt()
    var next = Nav.step(navItems, navIndex, dx, dy)
    if (next === navIndex && dx && item) {
      if (item.id === "bright") setBrightness(brightness + dx * 5)
      else if (item.id === "sat") setSaturation(saturation + dx * 5)
      return
    }
    navIndex = next
  }

  function activateNav() {
    var item = navAt()
    if (!item) return
    if (item.id === "face") setFace(faces[item.face].id)
    else if (item.id === "shape") setShape(item.shape)
    else if (item.id === "zero") zeroOrientation = !zeroOrientation
    else if (item.id === "ccw") stepAngle(-30)
    else if (item.id === "cw") stepAngle(30)
    else if (item.id === "sync") { syncOn = true; push() }
    else if (item.id === "off") turnOff()
  }

  onVisibleChanged: if (visible && viewReady && screen && !lcdReady) pull()
  onScreenChanged: {
    lcdReady = false
    pushed = ""
    if (visible && viewReady && screen) pull()
  }
  onFaceChanged: {
    saveView()
    if (ring) ring.requestPaint()
  }
  onAccent2Changed: if (syncOn && viewReady && visible) pushDelay.restart()
  onAngleChanged: saveView()
  onBrightnessChanged: saveView()
  onSaturationChanged: saveView()
  onZeroOrientationChanged: saveView()
  onShapeChoiceChanged: saveView()
  onShownShapeChanged: if (ring) ring.requestPaint()
  onInkChanged: if (ring) ring.requestPaint()
  onInk2Changed: if (ring) ring.requestPaint()
  onPreviewAngleChanged: if (ring) ring.requestPaint()

  Timer {
    id: viewSave
    interval: 200
    repeat: false
    onTriggered: root.writeView()
  }

  Timer {
    id: pushDelay
    interval: 180
    repeat: false
    onTriggered: if (root.syncOn) root.push()
  }

  Timer {
    interval: 5000
    repeat: true
    running: root.visible && root.syncOn && root.lcdReady && root.viewReady && root.screen !== null
    onTriggered: if (root.mark() !== root.pushed) root.push()
  }

  FileView {
    id: lcdFile
    path: Quickshell.env("HOME") + "/.config/omaflow/lcd-view.json"
    watchChanges: false
    printErrors: false
    onLoaded: root.readView(text())
    onLoadFailed: root.finishView()
  }

  Item {
    id: faceRow
    width: parent.width
    height: Math.max(faceFlow.implicitHeight, zeroBtn.implicitHeight)

    Flow {
      id: faceFlow
      width: parent.width - zeroBtn.width - Style.space(12)
      spacing: Style.space(8)

      Repeater {
        model: 2
        delegate: Button {
          required property int index
          readonly property var face: root.faces[index]
          text: face.label
          bordered: true
          selected: root.face === face.id
          hasCursor: root.aimed("face", index)
          foreground: root.fg
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: {
            root.navIndex = index
            root.setFace(face.id)
          }
        }
      }

      Item {
        width: Style.space(16)
        height: Style.space(8)
      }

      Button {
        readonly property int faceIndex: 2
        text: root.faces[2].label
        bordered: true
        selected: root.face === root.faces[2].id
        hasCursor: root.aimed("face", faceIndex)
        foreground: root.fg
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        onClicked: {
          root.navIndex = faceIndex
          root.setFace(root.faces[2].id)
        }
      }

      Item {
        width: Style.space(28)
        height: Style.space(8)
      }

      Button {
        readonly property int faceIndex: 3
        text: root.faces[3].label
        bordered: true
        selected: root.face === root.faces[3].id
        hasCursor: root.aimed("face", faceIndex)
        foreground: root.fg
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        onClicked: {
          root.navIndex = faceIndex
          root.setFace(root.faces[3].id)
        }
      }
    }

    Button {
      id: zeroBtn
      anchors.right: parent.right
      anchors.top: parent.top
      text: "Zero orientation"
      bordered: true
      selected: root.zeroOrientation
      hasCursor: root.aimed("zero")
      foreground: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      tooltipText: "Hold the preview level, as if the pump screen were horizontal"
      onClicked: root.zeroOrientation = !root.zeroOrientation
    }
  }

  Item {
    id: stage
    width: parent.width
    height: Math.max(Style.space(180), root.height - faceRow.height - sliderRow.height - actionRow.height - root.spacing * 3)
    readonly property int dialSize: {
      var chrome = Style.space(36) * 2 + Style.space(18) * 2
      var byW = Math.floor(width - chrome)
      var byH = Math.floor(height - Style.space(4))
      var fit = Math.min(byW, byH)
      if (fit < Style.space(96)) fit = Style.space(96)
      return fit
    }

    Row {
      anchors.centerIn: parent
      spacing: Style.space(18)

      Item {
        width: Style.space(36)
        height: stage.dialSize
        Button {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(36)
          height: Style.space(36)
          iconText: "\uf0e2"
          iconSize: Style.font.caption
          bordered: true
          hasCursor: root.aimed("ccw")
          foreground: root.fg
          accent: root.accent
          fontFamily: root.fontFamily
          tooltipText: "Turn the display 30 degrees counter-clockwise"
          onClicked: root.stepAngle(-30)
        }
      }

      Item {
        id: dial
        width: stage.dialSize
        height: width
        readonly property real orbit: width / 2 - Style.space(8)
        readonly property int frameW: {
          var aspect = root.frameAspect > 0 ? root.frameAspect : 1
          return aspect >= 1 ? width : Math.max(1, Math.round(width * aspect))
        }
        readonly property int frameH: {
          var aspect = root.frameAspect > 0 ? root.frameAspect : 1
          return aspect >= 1 ? Math.max(1, Math.round(width / aspect)) : width
        }

        Item {
          id: artwork
          width: dial.frameW
          height: dial.frameH
          anchors.centerIn: parent
          transform: Rotation {
            origin.x: artwork.width / 2
            origin.y: artwork.height / 2
            angle: root.previewAngle
          }

          Canvas {
            id: ring
            anchors.fill: parent
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var stroke = Math.max(2, Style.space(8))
              var inset = Style.space(18)
              ctx.lineWidth = stroke
              ctx.lineCap = "butt"
              if (root.shownShape === "square") {
                var x = inset
                var y = inset
                var rw = Math.max(1, width - inset * 2)
                var rh = Math.max(1, height - inset * 2)
                ctx.strokeStyle = root.ink
                ctx.strokeRect(x, y, rw, rh)
                if (root.combo) {
                  ctx.strokeStyle = root.ink2
                  ctx.beginPath()
                  ctx.moveTo(x + rw / 2, y)
                  ctx.lineTo(x + rw, y)
                  ctx.lineTo(x + rw, y + rh)
                  ctx.lineTo(x + rw / 2, y + rh)
                  ctx.stroke()
                }
                return
              }
              var radius = (Math.min(width, height) - inset * 2 - stroke) / 2
              if (root.combo) {
                ctx.strokeStyle = root.ink
                ctx.beginPath()
                ctx.arc(width / 2, height / 2, radius, Math.PI / 2, Math.PI * 1.5, false)
                ctx.stroke()
                ctx.strokeStyle = root.ink2
                ctx.beginPath()
                ctx.arc(width / 2, height / 2, radius, Math.PI * 1.5, Math.PI / 2, false)
                ctx.stroke()
              } else {
                ctx.strokeStyle = root.ink
                ctx.beginPath()
                ctx.arc(width / 2, height / 2, radius, 0, Math.PI * 2, false)
                ctx.stroke()
              }
            }
          }

          Column {
            anchors.centerIn: parent
            visible: !root.combo
            spacing: Style.space(2)
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.primaryText()
              color: root.ink
              font.family: root.fontFamily
              font.pixelSize: Math.max(Style.space(28), Math.round(artwork.width * 0.16))
              font.bold: true
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.primaryLabel()
              color: root.ink
              font.family: root.fontFamily
              font.pixelSize: Style.space(12)
              font.bold: true
              font.letterSpacing: 1.2
            }
          }

          Row {
            anchors.centerIn: parent
            visible: root.combo
            spacing: Style.space(16)

            Column {
              spacing: Style.space(2)
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.primaryText()
                color: root.ink
                font.family: root.fontFamily
                font.pixelSize: Math.max(Style.space(22), Math.round(artwork.width * 0.11))
                font.bold: true
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.primaryLabel()
                color: root.ink
                font.family: root.fontFamily
                font.pixelSize: Style.space(11)
                font.bold: true
                font.letterSpacing: 1.1
              }
            }

            Rectangle {
              width: 1
              height: Style.space(46)
              anchors.verticalCenter: parent.verticalCenter
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.35)
            }

            Column {
              spacing: Style.space(2)
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.secondaryText()
                color: root.ink2
                font.family: root.fontFamily
                font.pixelSize: Math.max(Style.space(22), Math.round(artwork.width * 0.11))
                font.bold: true
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.secondaryLabel()
                color: root.ink2
                font.family: root.fontFamily
                font.pixelSize: Style.space(11)
                font.bold: true
                font.letterSpacing: 1.1
              }
            }
          }
        }

        Repeater {
          model: 12
          delegate: Rectangle {
            required property int index
            readonly property int deg: index * 30
            readonly property bool on: root.dotOn(deg)
            z: 2
            width: on ? Style.space(12) : Style.space(6)
            height: width
            radius: width / 2
            color: on ? root.fg : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.45)
            x: dial.width / 2 + Math.sin(deg * Math.PI / 180) * dial.orbit - width / 2
            y: dial.height / 2 - Math.cos(deg * Math.PI / 180) * dial.orbit - height / 2

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(8)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.setAngle(deg)
            }
          }
        }
      }

      Item {
        width: Style.space(36)
        height: stage.dialSize
        Button {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(36)
          height: Style.space(36)
          iconText: "\uf01e"
          iconSize: Style.font.caption
          bordered: true
          hasCursor: root.aimed("cw")
          foreground: root.fg
          accent: root.accent
          fontFamily: root.fontFamily
          tooltipText: "Turn the display 30 degrees clockwise"
          onClicked: root.stepAngle(30)
        }
      }
    }
  }

  Row {
    id: sliderRow
    width: parent.width
    spacing: Style.space(18)

    Row {
      id: brightSide
      width: (parent.width - parent.spacing) / 2
      spacing: Style.space(8)

      Text {
        id: brightLabel
        anchors.verticalCenter: parent.verticalCenter
        text: "Brightness"
        color: root.aimed("bright") ? root.accent : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.space(13)
      }

      Item {
        id: brightSlider
        width: parent.width - brightLabel.width - brightValue.width - parent.spacing * 2
        height: Style.space(28)
        anchors.verticalCenter: parent.verticalCenter

        function setFromX(x) {
          var span = Math.max(1, width)
          root.setBrightness((Math.max(0, Math.min(span, x)) / span) * 100)
        }

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          height: Style.space(6)
          radius: 0
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)
        }
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width * root.brightness / 100
          height: Style.space(6)
          radius: 0
          color: root.aimed("bright") ? root.accent : root.fg
        }
        Rectangle {
          width: Style.space(10)
          height: Style.space(16)
          radius: 0
          anchors.verticalCenter: parent.verticalCenter
          x: Math.max(0, Math.min(parent.width - width, parent.width * root.brightness / 100 - width / 2))
          color: root.fg
          border.width: root.aimed("bright") ? 1 : 0
          border.color: root.accent
        }
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onPressed: function(mouse) {
            root.navIndex = root.indexOf("bright")
            brightSlider.setFromX(mouse.x)
          }
          onPositionChanged: function(mouse) {
            if (pressed) brightSlider.setFromX(mouse.x)
          }
          onWheel: function(wheel) {
            var dir = wheel.angleDelta.y >= 0 ? 1 : -1
            root.navIndex = root.indexOf("bright")
            root.setBrightness(root.brightness + dir * 5)
          }
        }
      }

      Text {
        id: brightValue
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(28)
        text: root.brightness
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.space(13)
        font.bold: true
      }
    }

    Row {
      id: satSide
      width: (parent.width - parent.spacing) / 2
      spacing: Style.space(8)

      Text {
        id: satLabel
        anchors.verticalCenter: parent.verticalCenter
        text: "Saturation"
        color: root.aimed("sat") ? root.accent : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.space(13)
      }

      Item {
        id: satSlider
        width: parent.width - satLabel.width - satValue.width - parent.spacing * 2
        height: Style.space(28)
        anchors.verticalCenter: parent.verticalCenter

        function setFromX(x) {
          var span = Math.max(1, width)
          root.setSaturation((Math.max(0, Math.min(span, x)) / span) * 100)
        }

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          height: Style.space(6)
          radius: 0
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)
        }
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width * root.saturation / 100
          height: Style.space(6)
          radius: 0
          color: root.aimed("sat") ? root.accent : root.fg
        }
        Rectangle {
          width: Style.space(10)
          height: Style.space(16)
          radius: 0
          anchors.verticalCenter: parent.verticalCenter
          x: Math.max(0, Math.min(parent.width - width, parent.width * root.saturation / 100 - width / 2))
          color: root.fg
          border.width: root.aimed("sat") ? 1 : 0
          border.color: root.accent
        }
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onPressed: function(mouse) {
            root.navIndex = root.indexOf("sat")
            satSlider.setFromX(mouse.x)
          }
          onPositionChanged: function(mouse) {
            if (pressed) satSlider.setFromX(mouse.x)
          }
          onWheel: function(wheel) {
            var dir = wheel.angleDelta.y >= 0 ? 1 : -1
            root.navIndex = root.indexOf("sat")
            root.setSaturation(root.saturation + dir * 5)
          }
        }
      }

      Text {
        id: satValue
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(36)
        text: root.saturation
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.space(13)
        font.bold: true
      }
    }
  }

  Item {
    id: actionRow
    width: parent.width
    height: Math.max(syncCluster.implicitHeight, shapeCluster.implicitHeight)

    Row {
      id: syncCluster
      spacing: Style.space(8)

      Button {
        text: "Sync"
        bordered: true
        selected: root.syncOn
        hasCursor: root.aimed("sync")
        foreground: root.fg
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        tooltipText: "Keep the pump on this frame"
        onClicked: {
          root.syncOn = true
          root.push()
        }
      }
      Button {
        text: "Off"
        bordered: true
        selected: !root.syncOn && root.lcdReady
        hasCursor: root.aimed("off")
        foreground: root.fg
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        onClicked: root.turnOff()
      }
    }

    Text {
      anchors.left: syncCluster.right
      anchors.right: shapeCluster.left
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
      text: root.angle + "°    " + (root.zeroOrientation ? "Preview held level" : "Preview follows the dial") + "    " + (root.shownShape === "square" ? "Square" : "Round") + (root.shapeChoice === "" ? " · auto" : "")
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Row {
      id: shapeCluster
      anchors.right: parent.right
      spacing: Style.space(8)

      Button {
        text: "Round"
        bordered: true
        selected: root.shownShape === "round"
        hasCursor: root.aimed("shape", "round")
        foreground: root.fg
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        tooltipText: root.shapeTip("round")
        onClicked: {
          root.navIndex = root.shapeIndex("round")
          root.setShape("round")
        }
      }
      Button {
        text: "Square"
        bordered: true
        selected: root.shownShape === "square"
        hasCursor: root.aimed("shape", "square")
        foreground: root.fg
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        tooltipText: root.shapeTip("square")
        onClicked: {
          root.navIndex = root.shapeIndex("square")
          root.setShape("square")
        }
      }
    }
  }

  Text {
    width: parent.width
    visible: root.screen === null
    text: "No pump display reported by the daemon."
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
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
}
