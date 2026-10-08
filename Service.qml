// 3D workspace switch animations for the omarchy shell.
//
// A transparent, always-mapped overlay window per output renders a cached
// screenshot of the outgoing workspace with a 4x4 transform while the new
// workspace is already live underneath. Screenshots are captured with grim
// into a ping-pong cache on a debounced event trail, so no capture ever runs
// on the switch path and workspace switches stay instant.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import "FlipMatrix.js" as FM

Item {
  id: root

  // User configuration (~/.config/omarchy/workspace3d.json).
  property bool effectEnabled: true
  property string effectStyle: "flip"
  property int effectDuration: 350
  property string effectEasing: "outCubic"

  // Animation state. activeStyle/effectEasing are frozen per run so a
  // mid-flight config edit can't tear a transition.
  property bool animating: false
  property int animDir: 1
  property string animOut: ""
  property string activeStyle: "flip"
  property real progress: 0
  // Bumped every time an animation starts; captures that straddled a switch
  // are discarded by comparing against the epoch they were issued under.
  property int animEpoch: 0

  // Last regular workspace id seen, for direction and change detection.
  property int prevWsId: -1

  // Per-output screenshot cache. slotIdx[out] is the newest completed slot
  // (0 or 1); lastPath is keyed "<out>.<slot>". cacheRev bumps on every
  // completed capture so bindings that read the plain JS maps re-evaluate.
  property var slotIdx: ({})
  property var lastPath: ({})
  property var panelFor: ({})
  property int cacheRev: 0

  // Capture pipeline state.
  property var pendingSlot: ({})
  property bool captureAgain: false
  property int captureEpoch: 0

  readonly property string home: Quickshell.env("HOME")
  readonly property string cacheDir: home + "/.cache/omarchy-workspace3d"
  readonly property string configPath: home + "/.config/omarchy/workspace3d.json"
  readonly property var validStyles: ["flip", "flythrough", "coverflow"]
  readonly property var validEasings: [
    "linear", "inQuad", "outQuad", "inOutQuad", "inCubic", "outCubic",
    "inOutCubic", "inSine", "outSine", "inOutSine", "inExpo", "outExpo",
    "inOutExpo", "inBack", "outBack", "inOutBack", "inBounce", "outBounce",
    "inOutBounce"
  ]
  // Events that never change what is on screen; they must not wake the
  // capture pipeline.
  readonly property var ignoreEvents: ({
    "windowtitle": true,
    "windowtitlev2": true,
    "activelayout": true,
    "submap": true,
    "focusedmon": true,
    "focusedmonv2": true,
    // Our own captures emit screencast events; reacting to them would make
    // the pipeline trigger itself in a loop.
    "screencast": true,
    "screencastv2": true
  })

  function cachePath(out, slot) {
    var safe = String(out).replace(/[^A-Za-z0-9_-]/g, "_")
    return cacheDir + "/" + safe + "." + slot + ".jpg"
  }

  function screenNames() {
    var names = []
    for (var i = 0; i < Quickshell.screens.length; i++)
      names.push(String(Quickshell.screens[i].name))
    return names
  }

  function focusedOutput() {
    var monitor = Hyprland.focusedMonitor
    return monitor ? String(monitor.name) : ""
  }

  // ------------------------------------------------------------ animation

  function easingType(name) {
    var all = Easing
    var map = {
      "linear": all.Linear,
      "inQuad": all.InQuad, "outQuad": all.OutQuad, "inOutQuad": all.InOutQuad,
      "inCubic": all.InCubic, "outCubic": all.OutCubic, "inOutCubic": all.InOutCubic,
      "inSine": all.InSine, "outSine": all.OutSine, "inOutSine": all.InOutSine,
      "inExpo": all.InExpo, "outExpo": all.OutExpo, "inOutExpo": all.InOutExpo,
      "inBack": all.InBack, "outBack": all.OutBack, "inOutBack": all.InOutBack,
      "inBounce": all.InBounce, "outBounce": all.OutBounce, "inOutBounce": all.InOutBounce
    }
    return map[name] !== undefined ? map[name] : all.OutCubic
  }

  function effectMatrix(out, w, h) {
    if (!animating || out !== animOut || w <= 0 || h <= 0)
      return Qt.matrix4x4(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
    var m = FM.build(activeStyle, animDir, progress, w, h)
    return Qt.matrix4x4(
      m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7],
      m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15])
  }

  function beginAnimation(out, dir, styleName) {
    animOut = out
    animDir = dir
    activeStyle = styleName
    progress = 0
    animEpoch += 1
    animating = true
    anim.duration = Math.max(100, effectDuration)
    anim.easing.type = easingType(effectEasing)
    anim.restart()
  }

  function finishAnimation() {
    animating = false
    progress = 0
    if (captureAgain && !captureProc.running) {
      captureAgain = false
      requestCapture()
    }
  }

  function readyImage(out) {
    var panel = panelFor[out]
    if (!panel || slotIdx[out] === undefined) return null
    var img = panel.imageFor(slotIdx[out])
    return img && img.status === Image.Ready ? img : null
  }

  function tryAnimate(dir) {
    if (!effectEnabled || animating) return
    var out = focusedOutput()
    if (!out || !readyImage(out)) return
    beginAnimation(out, dir, effectStyle)
  }

  function previewNow() {
    if (animating) return "busy"
    var out = focusedOutput()
    if (!out || !readyImage(out)) return "nocache"
    beginAnimation(out, 1, effectStyle)
    return "ok"
  }

  // ------------------------------------------------------- event handling

  function handleRawEvent(name, data) {
    if (name === "workspace" || name === "workspacev2") {
      var id = parseInt(String(data).split(",")[0], 10)
      if (isFinite(id) && id >= 1 && id !== prevWsId) {
        var dir = (prevWsId > 0 && id < prevWsId) ? -1 : 1
        var cold = prevWsId < 0
        prevWsId = id
        if (!cold) tryAnimate(dir)
      }
      debouncedCapture.restart()
      return
    }
    if (ignoreEvents[name]) return
    debouncedCapture.restart()
  }

  // ------------------------------------------------------ capture pipeline

  function requestCapture() {
    if (captureProc.running) {
      captureAgain = true
      return
    }
    var names = screenNames()
    if (names.length === 0) return
    var parts = []
    pendingSlot = ({})
    for (var i = 0; i < names.length; i++) {
      var out = names[i]
      var cur = slotIdx[out]
      var target = cur === undefined ? 0 : 1 - cur
      pendingSlot[out] = target
      var dest = cachePath(out, target)
      parts.push("grim -o " + Util.shellQuote(out) + " -t jpeg -q 75 "
        + Util.shellQuote(dest + ".tmp") + " && mv -f "
        + Util.shellQuote(dest + ".tmp") + " " + Util.shellQuote(dest) + " || true")
    }
    captureEpoch = animEpoch
    captureProc.command = ["bash", "-c",
      "mkdir -p " + Util.shellQuote(cacheDir) + "\n" + parts.join("\n")]
    captureProc.running = true
  }

  function captureAll() {
    if (animating) {
      captureAgain = true
      return
    }
    requestCapture()
  }

  function notifyCapture(out, slot, path) {
    slotIdx[out] = slot
    lastPath[out + "." + slot] = path
    cacheRev += 1
    var panel = panelFor[out]
    if (panel) panel.applyCapture(slot, path)
  }

  function registerPanel(out, panel) {
    panelFor[out] = panel
    if (slotIdx[out] === undefined) return
    for (var s = 0; s <= 1; s++) {
      var path = lastPath[out + "." + s]
      if (path) panel.applyCapture(s, path)
    }
  }

  function unregisterPanel(out) {
    if (panelFor[out]) delete panelFor[out]
  }

  // -------------------------------------------------------------- config

  function applyConfig(raw) {
    var v = {}
    if (String(raw || "").trim()) {
      try {
        v = JSON.parse(raw)
      } catch (e) {
        console.warn("workspace3d: ignoring malformed config")
        return
      }
    }
    if (typeof v.enabled === "boolean") effectEnabled = v.enabled
    if (validStyles.indexOf(String(v.style)) >= 0) effectStyle = String(v.style)
    var d = parseInt(v.duration, 10)
    if (isFinite(d)) effectDuration = Math.max(100, Math.min(5000, d))
    if (validEasings.indexOf(String(v.easing)) >= 0) effectEasing = String(v.easing)
  }

  function saveConfig() {
    configFile.setText(JSON.stringify({
      enabled: effectEnabled,
      style: effectStyle,
      duration: effectDuration,
      easing: effectEasing
    }, null, 2) + "\n")
  }

  function setStyle(name) {
    if (!name) return effectStyle
    if (validStyles.indexOf(String(name)) < 0) return "invalid"
    effectStyle = String(name)
    saveConfig()
    return effectStyle
  }

  function setDuration(ms) {
    if (!ms) return String(effectDuration)
    var d = parseInt(ms, 10)
    if (!isFinite(d)) return "invalid"
    effectDuration = Math.max(100, Math.min(5000, d))
    saveConfig()
    return String(effectDuration)
  }

  function setEasing(name) {
    if (!name) return effectEasing
    if (validEasings.indexOf(String(name)) < 0) return "invalid"
    effectEasing = String(name)
    saveConfig()
    return effectEasing
  }

  function setEnabled(on) {
    if (!on) return effectEnabled ? "on" : "off"
    var v = String(on).toLowerCase()
    if (v === "true" || v === "1" || v === "on" || v === "yes") effectEnabled = true
    else if (v === "false" || v === "0" || v === "off" || v === "no") effectEnabled = false
    else return "invalid"
    saveConfig()
    return effectEnabled ? "on" : "off"
  }

  function statusJson() {
    var cache = {}
    for (var out in slotIdx) cache[out] = slotIdx[out]
    return JSON.stringify({
      enabled: effectEnabled,
      style: effectStyle,
      duration: effectDuration,
      easing: effectEasing,
      animating: animating,
      dir: animDir,
      output: animOut,
      workspace: prevWsId,
      screens: screenNames(),
      cache: cache
    })
  }

  // ------------------------------------------------------------ plumbing

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyConfig(configFile.text())
    // First run: no file yet. Apply the defaults and write them out so the
    // config is discoverable and hand-editable from the start.
    onLoadFailed: {
      root.applyConfig("")
      root.saveConfig()
    }
  }

  Process {
    id: captureProc
    onExited: {
      // A switch that started while grim was running would have baked the
      // overlay into the capture; drop the result and let the next pass
      // overwrite the same target slot.
      if (captureEpoch === animEpoch) {
        for (var out in pendingSlot)
          notifyCapture(out, pendingSlot[out], root.cachePath(out, pendingSlot[out]))
      }
      pendingSlot = ({})
      if (captureAgain) {
        captureAgain = false
        requestCapture()
      }
    }
  }

  IpcHandler {
    target: "workspace3d"

    function status(): string {
      return root.statusJson()
    }

    function style(name: string): string {
      return root.setStyle(name)
    }

    function duration(ms: string): string {
      return root.setDuration(ms)
    }

    function easing(name: string): string {
      return root.setEasing(name)
    }

    function enable(on: string): string {
      return root.setEnabled(on)
    }

    function preview(): string {
      return root.previewNow()
    }

    function refresh(): string {
      if (root.animating) return "busy"
      root.requestCapture()
      return "ok"
    }
  }

  NumberAnimation {
    id: anim
    target: root
    property: "progress"
    from: 0
    to: 1
    onFinished: root.finishAnimation()
  }

  Timer {
    id: debouncedCapture
    interval: 400
    repeat: false
    onTriggered: root.captureAll()
  }

  Timer {
    interval: 8000
    repeat: true
    running: true
    onTriggered: root.captureAll()
  }

  Timer {
    id: startupCapture
    interval: 1200
    repeat: false
    onTriggered: root.requestCapture()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      root.handleRawEvent(String(event.name), String(event.data))
    }
  }

  // The Hyprland singleton may not have the focused workspace yet right
  // after a shell start; seed until it appears so the first switch after a
  // restart is not mistaken for a cold start (and skipped).
  function seedWorkspace() {
    if (prevWsId >= 0) return
    var fw = Hyprland.focusedWorkspace
    if (fw && fw.id >= 1) prevWsId = fw.id
  }

  Component.onCompleted: {
    seedWorkspace()
    Qt.callLater(function() { configFile.reload() })
    startupCapture.restart()
    console.log("workspace3d: service started")
  }

  Timer {
    interval: 500
    repeat: true
    running: root.prevWsId < 0
    onTriggered: root.seedWorkspace()
  }

  // One always-mapped, transparent overlay window per output. It never
  // toggles visible, so the first animated frame has no map latency; the
  // empty input region keeps it fully click-through.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData
      readonly property string out: String(modelData.name)
      screen: modelData

      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }

      WlrLayershell.namespace: "omarchy-workspace3d"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      mask: Region {}

      // Newest completed slot for this output; reading cacheRev inside the
      // block makes the plain-JS map lookup reactive to captures.
      readonly property int currentSlot: {
        root.cacheRev
        return root.slotIdx[panel.out] !== undefined ? root.slotIdx[panel.out] : -1
      }

      function imageFor(slot) {
        return slot === 0 ? img0 : img1
      }

      function applyCapture(slot, path) {
        var img = imageFor(slot)
        img.source = ""
        img.source = Util.fileUrl(path)
      }

      Component.onCompleted: root.registerPanel(panel.out, panel)
      Component.onDestruction: root.unregisterPanel(panel.out)

      Item {
        id: page
        anchors.fill: parent
        visible: root.animating && panel.out === root.animOut
        opacity: FM.pageOpacity(root.activeStyle, root.progress)

        transform: Matrix4x4 {
          matrix: root.effectMatrix(panel.out, page.width, page.height)
        }

        Image {
          id: img0
          anchors.fill: parent
          visible: panel.currentSlot === 0
          asynchronous: false
          smooth: true
          fillMode: Image.Stretch
        }

        Image {
          id: img1
          anchors.fill: parent
          visible: panel.currentSlot === 1
          asynchronous: false
          smooth: true
          fillMode: Image.Stretch
        }

        Rectangle {
          anchors.fill: parent
          color: "black"
          visible: opacity > 0
          opacity: FM.shadowOpacity(root.activeStyle, root.progress)
        }
      }
    }
  }
}
