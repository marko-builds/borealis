// Standalone integration selftest for Borealis.qml (no shell restart needed):
// summons the overlay beside the live shell, proves the shader paints (a blank
// shader is the silent failure class), proves the animation advances, switches
// all five palettes live while summoned, checks the prototype-key guard,
// dismisses with a REAL key press (wtype) and a synthetic click, checks focus
// returns to the window that had it, proves the aurora pad is OFF by default
// (no PipeWire stream on a plain summon), ON with ambience:true (exactly one
// stream), gone after dismiss + ramp, and samples idle CPU after dismiss.
// Palette checks read stop2 (the peak ramp stop): aurora [35,200,200],
// ember [235,75,60], ice [90,210,235]. Ported from Downpour's selftest 2026-08-22.
// Run: quickshell -p selftest.qml   (or ./selftest.sh for the full gate)
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

ShellRoot {
  id: harness

  // Grabs go under XDG_RUNTIME_DIR (user-owned, mode 0700), never a shared
  // /tmp path another local user could pre-create with symlinks.
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string outDir: runtimeDir + "/borealis-selftest"
  readonly property string pluginId: "io.github.marko-builds.borealis"
  property int tick: 0
  property int pendingGrabs: 0
  property int hideCalls: 0
  property string focusBefore: ""
  property string focusAfter: ""
  property real timeA: -1
  property bool cpuDone: false

  function log(msg) { console.log("SELFTEST t=" + tick + " " + msg) }

  function cfg(palette, ambience) {
    var entry = { id: pluginId }
    if (palette !== undefined) entry.palette = palette
    if (ambience !== undefined) entry.ambience = ambience
    return { plugins: [ { id: "omarchy.bar" }, entry ] }
  }

  function grabItem(item, name) {
    if (!item) { log("grab " + name + " SKIPPED (null item)"); return }
    pendingGrabs++
    const ok = item.grabToImage(function(result) {
      const saved = result.saveToFile(harness.outDir + "/" + name + ".png")
      harness.log("grab " + name + " saved=" + saved)
      harness.pendingGrabs--
    })
    if (!ok) { log("grab " + name + " REFUSED"); pendingGrabs-- }
  }

  function fmt(v) { return v.x.toFixed(3) + "," + v.y.toFixed(3) + "," + v.z.toFixed(3) }

  Component.onCompleted: {
    if (runtimeDir === "") {
      console.log("SELFTEST FAIL: XDG_RUNTIME_DIR is unset; refusing to write grabs")
      Qt.quit()
    }
  }

  Process {
    id: mkOut
    command: ["mkdir", "-p", harness.outDir]
    running: harness.runtimeDir !== ""
  }

  // The shell object the real shell injects: a reactive shellConfig plus hide().
  QtObject {
    id: fakeShell
    property var shellConfig: harness.cfg()
    function hide(id) {
      harness.hideCalls++
      harness.log("shell.hide(" + id + ") ID_OK=" + (id === harness.pluginId))
    }
  }

  Borealis {
    id: plugin
    shell: fakeShell
    manifest: ({ id: harness.pluginId })
  }

  // hyprctl activewindow -j -> address of the focused toplevel.
  Process {
    id: focusProbe
    property string phase: ""
    command: ["hyprctl", "activewindow", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        var addr = ""
        try { addr = JSON.parse(text).address || "" } catch (e) { addr = "PARSE_ERR" }
        if (focusProbe.phase === "before") harness.focusBefore = addr
        else harness.focusAfter = addr
        harness.log("focus " + focusProbe.phase + " = " + addr)
      }
    }
  }
  function probeFocus(phase) { focusProbe.phase = phase; focusProbe.running = true }

  // Proves the overlay is a real compositor surface, not just opened=true.
  Process {
    id: layerProbe
    command: ["sh", "-c", "hyprctl layers | grep -c 'namespace: borealis' || true"]
    stdout: StdioCollector {
      onStreamFinished: harness.log("compositor layers namespace=borealis count="
                                    + text.trim() + " LAYER_OK=" + (parseInt(text) > 0))
    }
  }

  // Audio: the bed is a real PipeWire stream or it is nothing. Counts the
  // plugin's sink-inputs by application.name; the bed's pid is read from the
  // Process, never searched (pgrep -f would match this harness's own sh).
  Process {
    id: audioProbe
    property string phase: ""
    command: ["sh", "-c", "pactl list sink-inputs | grep -c 'application.name = \"" + harness.pluginId + "\"' || true"]
    stdout: StdioCollector {
      onStreamFinished: {
        var n = parseInt(text)
        if (audioProbe.phase === "on")
          harness.log("sink-inputs while summoned=" + n + " bedRunning=" + plugin.bedRunning
                      + " AUDIO_ON_OK=" + (n === 1 && plugin.bedRunning))
        else if (audioProbe.phase === "off")
          harness.log("sink-inputs after dismiss=" + n + " bedRunning=" + plugin.bedRunning
                      + " AUDIO_OFF_OK=" + (n === 0 && !plugin.bedRunning))
        else
          harness.log("sink-inputs with ambience=false: " + n + " bedRunning=" + plugin.bedRunning
                      + " AUDIO_GATED_OK=" + (n === 0 && !plugin.bedRunning))
      }
    }
  }
  function probeAudio(phase) { audioProbe.phase = phase; audioProbe.running = true }

  // A real key press through the compositor. Shift_L on its own is inert if the
  // overlay somehow does not own the keyboard, so a miss cannot type into
  // whatever Marko has focused.
  Process { id: keyPress; command: ["wtype", "-k", "Shift_L"] }

  // Idle CPU after dismiss: top's SECOND iteration is a 2s delta, not the
  // lifetime average ps reports. $PPID of the sh is this quickshell.
  Process {
    id: cpuProbe
    command: ["sh", "-c", "top -bn2 -d3 -p $PPID | grep -E \"^ *$PPID \" | tail -1 | awk '{print $9}'"]
    stdout: StdioCollector {
      onStreamFinished: {
        harness.log("idle CPU after dismiss = " + text.trim() + "% CPU_IDLE_OK="
                    + (parseFloat(text) <= 0.5))
        harness.cpuDone = true
      }
    }
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: {
      harness.tick++
      const t = harness.tick
      const scene = plugin.sceneItem

      if (t === 1) {
        harness.log("initial palette=" + plugin.palette + " opened=" + plugin.opened
                    + " panelVisible=" + plugin.panelVisible + " ambience=" + plugin.ambience
                    + " DEFAULT_OK=" + (plugin.palette === "aurora" && !plugin.opened && !plugin.ambience))
        harness.probeFocus("before")
      }
      if (t === 2) {
        plugin.open("{}")
        harness.log("open(): opened=" + plugin.opened + " panelVisible=" + plugin.panelVisible
                    + " SUMMON_OK=" + (plugin.opened && plugin.panelVisible))
      }
      if (t === 3) {
        layerProbe.running = true
        harness.timeA = scene.time
        harness.log("scene " + scene.width + "x" + scene.height + " time=" + scene.time.toFixed(3)
                    + " stop2=" + harness.fmt(scene.stop2))
        harness.grabItem(scene, "FRAME-A-aurora")
        // Default OFF: a plain summon must start no stream at all.
        harness.probeAudio("gated")
      }
      if (t === 4) {
        harness.log("time advance " + harness.timeA.toFixed(3) + " -> " + scene.time.toFixed(3)
                    + " ANIM_OK=" + (scene.time > harness.timeA + 0.5))
        harness.grabItem(scene, "FRAME-B-aurora")
      }
      if (t === 5) {
        fakeShell.shellConfig = harness.cfg("ember")
        harness.log("live switch ember: palette=" + plugin.palette + " stop2=" + harness.fmt(scene.stop2)
                    + " PALETTE_EMBER_OK=" + (plugin.palette === "ember" && scene.stop2.x > 0.9))
      }
      if (t === 6) harness.grabItem(scene, "FRAME-C-ember")
      if (t === 7) {
        fakeShell.shellConfig = harness.cfg("ice")
        harness.log("live switch ice: palette=" + plugin.palette + " stop2=" + harness.fmt(scene.stop2)
                    + " PALETTE_ICE_OK=" + (plugin.palette === "ice" && scene.stop2.z > 0.9))
      }
      if (t === 8) harness.grabItem(scene, "FRAME-D-ice")
      if (t === 9) {
        fakeShell.shellConfig = harness.cfg("nord")
        harness.log("live switch nord: palette=" + plugin.palette
                    + " PALETTE_NORD_OK=" + (plugin.palette === "nord"))
        harness.grabItem(scene, "FRAME-E-nord")
      }
      if (t === 10) {
        fakeShell.shellConfig = harness.cfg("gold")
        harness.log("live switch gold: palette=" + plugin.palette + " stop2=" + harness.fmt(scene.stop2)
                    + " PALETTE_GOLD_OK=" + (plugin.palette === "gold" && scene.stop2.x > 0.85 && scene.stop2.z < 0.3))
        harness.grabItem(scene, "FRAME-F-gold")
      }
      if (t === 11) {
        // Prototype keys answer a plain lookup; the guard must fall back to aurora
        // with every colour uniform still a finite vector.
        var bad = ["__proto__", "constructor", "toString", "hasOwnProperty", "valueOf", "rain", ""]
        var allOk = true
        for (var i = 0; i < bad.length; i++) {
          fakeShell.shellConfig = harness.cfg(bad[i])
          var ok = plugin.palette === "aurora" && isFinite(scene.stop2.x) && isFinite(scene.skyBase.x)
          if (!ok) harness.log("  guard MISS for key '" + bad[i] + "' -> palette=" + plugin.palette)
          allOk = allOk && ok
        }
        fakeShell.shellConfig = harness.cfg("aurora")
        harness.log("prototype-key guard over " + bad.length + " keys PROTO_GUARD_OK=" + allOk)
      }
      if (t === 12) {
        harness.log("sending real key (wtype Shift_L) while summoned")
        keyPress.running = true
      }
      if (t === 13) {
        harness.log("after key: opened=" + plugin.opened + " panelVisible=" + plugin.panelVisible
                    + " hideCalls=" + harness.hideCalls
                    + " KEY_DISMISS_OK=" + (!plugin.opened && !plugin.panelVisible && harness.hideCalls === 1))
        harness.probeFocus("after")
      }
      if (t === 14) {
        harness.log("focus return " + harness.focusBefore + " -> " + harness.focusAfter
                    + " FOCUS_RETURN_OK=" + (harness.focusBefore !== "" && harness.focusBefore === harness.focusAfter))
        plugin.open("{}")
        harness.log("re-summon: opened=" + plugin.opened + " RESUMMON_OK=" + plugin.opened)
      }
      if (t === 15) {
        // Synthetic click: emits the MouseArea's own clicked signal (the exact
        // handler a pointer click runs). No tool on this box synthesises a
        // Wayland pointer click; the key path above is the real-input proof.
        try { plugin.clickArea.clicked(null) } catch (e) { harness.log("click emit threw: " + e) }
        harness.log("after click: opened=" + plugin.opened + " hideCalls=" + harness.hideCalls
                    + " CLICK_DISMISS_OK=" + (!plugin.opened && harness.hideCalls === 2))
        harness.log("animation stopped while dismissed: time frozen check starts")
        harness.timeA = scene.time
      }
      if (t === 16) {
        harness.log("dismissed time " + harness.timeA.toFixed(3) + " -> " + scene.time.toFixed(3)
                    + " ANIM_GATED_OK=" + (scene.time === harness.timeA))
      }
      if (t === 17) {
        // Dedicated ambience run: config set BEFORE the summon.
        fakeShell.shellConfig = harness.cfg("aurora", true)
        harness.log("ambience:true set, ambience=" + plugin.ambience)
      }
      if (t === 18) {
        plugin.open("{}")
        harness.log("ambience summon: opened=" + plugin.opened + " bedRunning=" + plugin.bedRunning)
      }
      // 2 s lead: cold mpv launch + sink-input registration (restore polls up to 3 s).
      if (t === 20) harness.probeAudio("on")
      if (t === 21) {
        plugin.dismiss()
        harness.log("ambience dismiss: opened=" + plugin.opened + " rampRunning=" + plugin.rampRunning
                    + " hideCalls=" + harness.hideCalls)
        fakeShell.shellConfig = harness.cfg("aurora")
      }
      // ~2 s after dismiss: the ramp (16 x 40 ms) is done and the bed stopped.
      if (t === 23) harness.probeAudio("off")
      // Sample once the grabs have flushed, so the number is the dismissed
      // overlay and not the harness writing PNGs.
      if (t === 25) cpuProbe.running = true
      if (t >= 30 && harness.pendingGrabs === 0 && harness.cpuDone) harness.finish()
      if (t >= 42) { harness.log("TIMEOUT pendingGrabs=" + harness.pendingGrabs + " cpuDone=" + harness.cpuDone); harness.finish() }
    }
  }

  function finish() {
    log("done")
    Qt.quit()
  }
}
