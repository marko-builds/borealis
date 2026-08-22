import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  // The single config surface: "palette" on this plugin's entry in
  // ~/.config/omarchy/shell.json, applied live on save (shellConfig is
  // reactive):  "plugins": [{ "id": "io.github.marko-builds.borealis",
  // "palette": "ember" }]  — aurora | ember | gold | nord | ice.
  // 6-stop ramps + sky tints from play/aurora.py PALETTES (0-255).
  readonly property var paletteTable: ({
    aurora: { p: [0.00, 0.12, 0.30, 0.55, 0.80, 1.00],
      c: [[150,45,180],[90,110,205],[35,200,200],[30,235,130],[25,180,80],[8,70,35]],
      sb: [6,8,18], sa: [8,10,22] },
    ember: { p: [0.00, 0.15, 0.35, 0.60, 0.82, 1.00],
      c: [[200,40,150],[225,60,95],[235,75,60],[240,120,40],[180,70,22],[60,20,12]],
      sb: [10,6,12], sa: [16,8,14] },
    gold: { p: [0.00, 0.15, 0.35, 0.60, 0.82, 1.00],
      c: [[120,70,20],[180,120,35],[225,165,55],[245,205,110],[235,175,90],[60,40,14]],
      sb: [10,8,6], sa: [16,12,8] },
    nord: { p: [0.00, 0.18, 0.40, 0.62, 0.82, 1.00],
      c: [[180,142,173],[129,161,193],[136,192,208],[143,188,187],[163,190,140],[90,110,75]],
      sb: [12,14,18], sa: [20,24,34] },
    ice: { p: [0.00, 0.15, 0.35, 0.60, 0.82, 1.00],
      c: [[60,90,200],[60,150,230],[90,210,235],[160,235,240],[130,185,160],[20,45,75]],
      sb: [6,9,22], sa: [8,14,26] }
  })
  property string palette: {
    var cfg = root.shell && root.shell.shellConfig
    var plugins = (cfg && cfg.plugins) || []
    for (var i = 0; i < plugins.length; i++) {
      var e = plugins[i]
      // hasOwnProperty, never `paletteTable[k] !== undefined`: every key on
      // Object.prototype ("__proto__", "constructor", "toString",
      // "hasOwnProperty", "valueOf") answers a plain lookup, so the loose test
      // accepts all five and hands `pal` the prototype object, whose ramp is
      // undefined. Measured in the shipping Qt V4 engine as a TypeError on
      // every colour uniform.
      var name = e && e.palette !== undefined ? String(e.palette) : ""
      if (e && e.id === "io.github.marko-builds.borealis"
          && Object.prototype.hasOwnProperty.call(paletteTable, name))
        return name
    }
    return "aurora"
  }
  readonly property var pal: paletteTable[palette]

  // v0.2 ambience: a synthesized aurora pad (play/ambient_synth.py, seamless by
  // construction, -14 LUFS) fades in on summon and ramps out on dismiss.
  // Config on the same shell.json entry: "ambience": true turns it on (default off),
  // "ambienceVolume": 0-100 sets the level (default 40), both live.
  readonly property var pluginEntry: {
    var cfg = root.shell && root.shell.shellConfig
    var plugins = (cfg && cfg.plugins) || []
    for (var i = 0; i < plugins.length; i++) {
      var e = plugins[i]
      if (e && e.id === "io.github.marko-builds.borealis") return e
    }
    return null
  }
  // Default OFF: Borealis has an installed base; no surprise audio in an update.
  readonly property bool ambience: !!(pluginEntry && pluginEntry.ambience === true)
  readonly property int ambienceVolume: {
    var v = pluginEntry ? Number(pluginEntry.ambienceVolume) : NaN
    return isFinite(v) ? Math.max(0, Math.min(100, Math.round(v))) : 40
  }
  onAmbienceVolumeChanged: if (bed.running) restore.running = true

  // The bed outlives `opened` by one ramp: the overlay closes at once, the
  // audio Process stops when the ramp reports done (or at once if no ramp ran).
  property bool audioOn: false
  readonly property string audioClient: "io.github.marko-builds.borealis"
  // Sink-input index by application.name; index() not a regex, so the dots in
  // the id are literal. Empty when the stream is not (yet) registered.
  readonly property string findIdx:
    "pactl list sink-inputs | awk -v app='application.name = \"" + audioClient + "\"' "
    + "'/Sink Input #/ { i=$0; sub(/.*#/, \"\", i) } index($0, app) && !f { f=i } END { print f }'"

  Process {
    id: bed
    running: root.audioOn && root.ambience
    command: [
      "mpv", "--no-video", "--loop-file=inf", "--load-scripts=no",
      "--audio-client-name=" + root.audioClient,
      "--volume=100", "--af=afade=t=in:d=2",
      Qt.resolvedUrl("audio/bed-aurora.ogg").toString()
    ]
    // --load-scripts=no: Omarchy ships mpv-mpris; a bare mpv would take the
    // media keys. Level lives on the PipeWire stream, not in mpv, so config
    // changes and the dismiss ramp use the same lever.
    onStarted: restore.running = true
  }

  // WirePlumber restores a stream's last volume by application.name, so the
  // 0% the ramp leaves would silence the NEXT summon. Poll for the sink-input
  // (up to 3 s) and set it to the configured level.
  Process {
    id: restore
    command: ["sh", "-c",
      "for n in $(seq 1 30); do idx=$(" + root.findIdx + "); [ -n \"$idx\" ] && break; sleep 0.1; done\n"
      + "[ -z \"$idx\" ] && exit 0\n"
      + "pactl set-sink-input-volume \"$idx\" " + root.ambienceVolume + "%"]
  }

  // Dismiss: -6% per 40 ms on the sink-input (pactl get-sink-input-volume does
  // not exist; do not read back with it), then let the Process stop. If the
  // stream is gone already, stop at once.
  Process {
    id: ramp
    command: ["sh", "-c",
      "idx=$(" + root.findIdx + ")\n"
      + "[ -z \"$idx\" ] && exit 0\n"
      + "for n in $(seq 1 16); do pactl set-sink-input-volume \"$idx\" -6% 2>/dev/null || break; sleep 0.04; done"]
    onExited: {
      if (root.opened) restore.running = true   // re-summoned mid-ramp: bring it back
      else root.audioOn = false
    }
  }
  function stopAudio() {
    if (!bed.running) { root.audioOn = false; return }
    if (!ramp.running) ramp.running = true
  }

  // Test handles for selftest.qml: read-only aliases, no behaviour of their own.
  readonly property alias sceneItem: scene
  readonly property alias clickArea: clickArea
  readonly property alias panelVisible: panel.visible
  readonly property alias bedRunning: bed.running
  readonly property alias rampRunning: ramp.running

  // ramp stop i as vec4: rgb (0-1) + stop position in w
  function stopVec(i) {
    return Qt.vector4d(pal.c[i][0] / 255, pal.c[i][1] / 255, pal.c[i][2] / 255, pal.p[i])
  }

  function open(payloadJson) {
    root.opened = true
    root.audioOn = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.stopAudio()
  }

  function dismiss() {
    root.opened = false
    root.stopAudio()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.marko-builds.borealis")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "borealis"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    ShaderEffect {
      id: scene
      anchors.fill: parent
      property real time: 0
      property vector2d resolution: Qt.vector2d(width, height)
      property vector4d stop0: root.stopVec(0)
      property vector4d stop1: root.stopVec(1)
      property vector4d stop2: root.stopVec(2)
      property vector4d stop3: root.stopVec(3)
      property vector4d stop4: root.stopVec(4)
      property vector4d stop5: root.stopVec(5)
      property vector4d skyBase: Qt.vector4d(root.pal.sb[0] / 255, root.pal.sb[1] / 255,
                                             root.pal.sb[2] / 255, 0)
      property vector4d skyAmp: Qt.vector4d(root.pal.sa[0] / 255, root.pal.sa[1] / 255,
                                            root.pal.sa[2] / 255, 0)
      fragmentShader: Qt.resolvedUrl("shaders/aurora.frag.qsb")

      // All animation gated on the overlay being open: zero work while dismissed.
      NumberAnimation on time {
        from: 0
        to: 3600
        duration: 3600000
        loops: Animation.Infinite
        running: root.opened
      }
    }

    MouseArea {
      id: clickArea
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        event.accepted = true
        root.dismiss()
      }
    }
  }
}
