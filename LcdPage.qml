import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Nav.js" as Nav

// The preview and the angle dial share one stage. The preview grows with the window.
// Round glass draws a circle. Square panels draw a square frame, and a non-square
// pixel buffer keeps that aspect. The axis lock sets the preview level and saves
// that. The dot still shows the dial, and that dial angle is what the pump image is rotated by.
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
  property bool syncOn: false
  property bool liveKnown: false
  property bool lcdReady: false
  property bool touched: false
  property bool pushing: false
  property bool viewReady: false
  property string pushed: ""
  property int previewGen: 0
  property color fg: Color.foreground
  property color accent: Color.accent
  property color accent2: Color.accent
  property color muted: Qt.darker(fg, 1.4)
  property string fontFamily: Style.font.family

  width: parent ? parent.width : 0
  spacing: Style.space(12)

  readonly property var screen: service && service.lcdChannels && service.lcdChannels.length ? service.lcdChannels[0] : null
  // lcdChannels is a new array on every poll. Follow the channel, not that array.
  readonly property string screenKey: screen ? (String(screen.deviceUid || "") + "/" + String(screen.name || "")) : ""
  readonly property var temps: service && service.temps ? service.temps : ({})
  readonly property color ink: deepen(accent, saturation)
  readonly property color ink2: deepen(accent2, saturation)
  readonly property bool combo: face === "cpu-gpu" || face === "cpu-liquid"
  readonly property int previewAngle: zeroOrientation ? 0 : angle
  readonly property string detectedShape: screen ? detectShape() : "round"
  readonly property string shownShape: detectedShape
  readonly property real frameAspect: screen ? frameRatio() : 1
  readonly property bool logoFace: face === "omarchy" || face === "omarchy-time"
  readonly property bool keepOn: !service || service.lcdBackground !== false
  property string previewSource: ""
  property string clockShown: ""
  readonly property var faces: [
    { id: "liquid", label: "Liquid" },
    { id: "cpu", label: "CPU" },
    { id: "cpu-gpu", label: "CPU | GPU" },
    { id: "cpu-liquid", label: "CPU | Liquid" },
    { id: "omarchy", label: "Omarchy" },
    { id: "omarchy-time", label: "Omarchy | Time" }
  ]
  // Face cells keep their column when Keep updating is off so the dimmed
  // buttons stay in place while the keyboard skips them.
  readonly property var navItems: {
    var allowAll = keepOn
    var out = []
    var i
    for (i = 0; i < faces.length; i++) {
      if (!allowAll && faces[i].id !== "omarchy") continue
      out.push({ id: "face", face: i, x: i, y: 0 })
    }
    out.push({ id: "zero", x: 6, y: 0 })
    out.push({ id: "ccw", x: 0, y: 1 })
    out.push({ id: "cw", x: 2, y: 1 })
    out.push({ id: "sync", x: 0, y: 2 })
    out.push({ id: "off", x: 1, y: 2 })
    out.push({ id: "bright", x: 0, y: 3 })
    out.push({ id: "sat", x: 1, y: 3 })
    return out
  }

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

  function clockNow() {
    return Qt.formatTime(new Date(), "HH:mm")
  }

  function faceEnabled(id) {
    if (keepOn) return true
    return id === "omarchy"
  }

  function faceNavIndex(faceIndex) {
    for (var i = 0; i < navItems.length; i++) {
      if (navItems[i].id === "face" && navItems[i].face === faceIndex) return i
    }
    return navIndex
  }

  // Logo plates ignore temperatures. The field is the Liquid black, and the clock uses the accent.
  function mark() {
    var px = pixelSize()
    var head = shownShape + "|" + px.w + "x" + px.h + "|" + face + "|"
    if (face === "omarchy" || face === "omarchy-time") {
      var minute = face === "omarchy-time" ? clockNow() : ""
      return head + minute + "|#0a0c0b|" + hexOf(ink) + "||" + brightness + "|" + angle
    }
    return head + primaryText() + "|" + secondaryText() + "|" + hexOf(ink) + "|" + hexOf(ink2) + "|" + brightness + "|" + angle
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
      if (obj.live !== undefined) {
        syncOn = obj.live === true
        liveKnown = true
      }
      touched = true
    } catch (e) {}
    finishView()
  }

  function finishView() {
    if (viewReady) return
    var snap = !keepOn && face !== "omarchy"
    if (snap) face = "omarchy"
    viewReady = true
    if (snap) saveView()
    if (screen && !lcdReady) pull()
  }

  function enforceKeepFace() {
    if (!viewReady || keepOn || face === "omarchy") return
    setFace("omarchy")
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
    if (liveKnown) obj.live = syncOn
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
          root.liveKnown = true
          root.saveView()
        }
      }
      root.lcdReady = true
      if (root.syncOn) root.push()
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
      shownShape, px.w, px.h, screen.deviceName || "",
      function(res) {
        root.pushing = false
        if (res && res.ok) root.pushed = token
      }
    )
  }

  function schedulePreview() {
    if (!logoFace || !service) return
    previewDelay.restart()
  }

  function requestPreview() {
    if (!logoFace || !service || !service.previewLcd) return
    previewGen = previewGen + 1
    var gen = previewGen
    var px = pixelSize()
    var name = screen ? String(screen.deviceName || "") : ""
    service.previewLcd(name, px.w, px.h, face, hexOf(ink), function(res) {
      if (gen !== root.previewGen || !root.logoFace) return
      if (!res || !res.ok) return
      root.previewSource = "file://" + Quickshell.env("HOME") + "/.cache/omaflow/lcd-preview.png?v=" + gen
    })
  }

  function turnOff() {
    syncOn = false
    liveKnown = true
    pushed = ""
    saveView()
    if (!service || !screen) return
    service.setLcd(screen.deviceUid, screen.name, {
      brightness: brightness, orientation: 0, colors: [], mode: "none"
    })
  }

  function setFace(id) {
    face = id
    if (syncOn) push()
  }

  // One shot. Holds the preview level and saves that choice. It does not
  // change the dial degree the pump image is rotated by, and it does not stay down.
  function zeroPreview() {
    zeroOrientation = true
    saveView()
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
    if (item.id === "face") {
      var picked = faces[item.face] ? faces[item.face].id : ""
      if (!faceEnabled(picked)) return
      setFace(picked)
    }
    else if (item.id === "zero") zeroPreview()
    else if (item.id === "ccw") stepAngle(-30)
    else if (item.id === "cw") stepAngle(30)
    else if (item.id === "sync") {
      syncOn = true
      liveKnown = true
      saveView()
      push()
    }
    else if (item.id === "off") turnOff()
  }

  onVisibleChanged: {
    if (visible && viewReady && screen && !lcdReady) pull()
    if (visible && logoFace) schedulePreview()
  }
  onScreenKeyChanged: {
    if (!screenKey) return
    lcdReady = false
    pushed = ""
    if (viewReady && screen) pull()
    if (logoFace) schedulePreview()
  }
  onKeepOnChanged: enforceKeepFace()
  onFaceChanged: {
    saveView()
    if (ring) ring.requestPaint()
    if (logoFace) {
      clockShown = clockNow()
      schedulePreview()
    }
  }
  onAccent2Changed: if (syncOn && keepOn && viewReady && visible) pushDelay.restart()
  onAngleChanged: saveView()
  onBrightnessChanged: saveView()
  onSaturationChanged: saveView()
  onZeroOrientationChanged: saveView()
  onShownShapeChanged: {
    if (ring) ring.requestPaint()
    if (logoFace) schedulePreview()
  }
  onInkChanged: {
    if (ring) ring.requestPaint()
    if (!logoFace) return
    schedulePreview()
    if (syncOn && keepOn && viewReady && visible) pushDelay.restart()
  }
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
    id: previewDelay
    interval: 180
    repeat: false
    onTriggered: root.requestPreview()
  }

  Timer {
    id: clockTick
    interval: 1000
    repeat: true
    running: root.visible && root.face === "omarchy-time"
    triggeredOnStart: true
    onTriggered: {
      var now = root.clockNow()
      var changed = now !== root.clockShown
      if (!changed && root.previewSource !== "") return
      root.clockShown = now
      root.schedulePreview()
      if (changed && root.syncOn && root.keepOn && root.viewReady) root.push()
    }
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
    height: Math.max(faceFlow.implicitHeight, zeroBtn.height)

    Flow {
      id: faceFlow
      width: parent.width - zeroBtn.width - Style.space(12)
      spacing: Style.space(8)

      Repeater {
        id: faceRepeat
        model: root.faces
        delegate: Button {
          required property var modelData
          required property int index
          text: modelData.label
          bordered: true
          selected: root.face === modelData.id
          opacity: {
            var on = root.keepOn
            return root.faceEnabled(modelData.id) ? 1 : 0.38
          }
          hasCursor: root.aimed("face", index)
          foreground: root.fg
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: {
            if (!root.faceEnabled(modelData.id)) return
            root.navIndex = root.faceNavIndex(index)
            root.setFace(modelData.id)
          }
        }
      }
    }

    Item {
      id: zeroBtn
      readonly property int side: {
        var sample = faceRepeat.itemAt(0)
        return sample ? sample.implicitHeight : Style.space(28)
      }
      anchors.right: parent.right
      anchors.top: parent.top
      width: side
      height: side

      Rectangle {
        anchors.fill: parent
        radius: 0
        color: zeroMouse.containsMouse || root.aimed("zero")
          ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
          : "transparent"
        border.width: 1
        border.color: root.aimed("zero") ? root.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.28)
      }

      OpticalGlyph {
        anchors.centerIn: parent
        width: Style.space(16)
        height: Style.space(16)
        text: "\uDB83\uDD4A"
        fontFamily: root.fontFamily
        fontSize: Style.space(16)
        color: root.aimed("zero") || zeroMouse.containsMouse ? root.accent : root.fg
      }

      MouseArea {
        id: zeroMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          root.navIndex = root.indexOf("zero")
          root.zeroPreview()
        }
      }

      PanelToolTip {
        visible: zeroMouse.containsMouse
        text: "Zero the preview and save that orientation"
        fontFamily: root.fontFamily
        panelBackground: Color.background
        panelForeground: Color.foreground
        panelBorder: Color.accent
      }
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

          Image {
            anchors.fill: parent
            visible: root.logoFace && root.previewSource !== ""
            source: root.previewSource
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
            cache: false
            asynchronous: true
          }

          Canvas {
            id: ring
            visible: !root.logoFace
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
            visible: !root.logoFace && !root.combo
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
            visible: !root.logoFace && root.combo
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
    height: Math.max(syncCluster.implicitHeight, deviceCaption.implicitHeight)

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
          root.liveKnown = true
          root.saveView()
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
      anchors.right: deviceCaption.left
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
      text: root.angle + "°    " + (root.zeroOrientation ? "Preview held level" : "Preview follows the dial")
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Row {
      id: deviceCaption
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, Math.max(Style.space(72), actionRow.width * 0.26))
        elide: Text.ElideRight
        text: root.screen ? String(root.screen.deviceName || "Display") : ""
        color: root.muted
        opacity: 0.72
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: {
          var screen = root.screen
          if (!screen) return ""
          var w = Number(screen.screenWidth) || 0
          var h = Number(screen.screenHeight) || 0
          var pxW = w > 0 && h > 0 ? Math.round(w) : 320
          var pxH = w > 0 && h > 0 ? Math.round(h) : 320
          var kind = root.shownShape === "square" ? "Square" : "Round"
          return pxW + "×" + pxH + "  ·  " + kind
        }
        color: root.muted
        opacity: 0.72
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
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
