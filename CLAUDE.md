# Borealis — dev notes

Fullscreen `overlay` plugin for Omarchy Quattro: GPU-procedural aurora over water.
Math ported from the monolith's `play/aurora.py`; `lookdev/index.html` is the browser
twin (same shader structure, faster iteration — keys 1-5/m/s/w/c/e, `?t=&freeze=1`
for deterministic captures).

## Shader/runtime gotchas (each cost a debugging round — don't relearn)

- **No `const` arrays in the fragment shader, ever.** The shell's OpenGL RHI uses the
  qsb package's GLSL 120 translation, where constant-array initializers don't exist.
  Failure mode: `qsb` compiles CLEAN, `omarchy plugin validate` passes, the overlay
  summons BLANK, and the only evidence is `journalctl --user` ("C7516: OpenGL does not
  allow constant arrays"). Tables go in as uniforms computed in QML (see the palette
  vec4 stops).
- **`keepLoaded: true` caches the component across `omarchy plugin update` AND
  disable/enable.** The dev reload path is `omarchy restart shell` (bar blinks ~1s).
- **After every first summon of a changed shader, grep the journal:**
  `journalctl --user -b --since "-5 min" | grep -iE "shader|C[0-9]{4}"` — a shader
  error renders as nothing, not as a message. Note the PID: a dying old shell process
  can log errors that look like the new one's.
- Rebuild: `/usr/lib/qt6/bin/qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 -o
  shaders/aurora.frag.qsb shaders/aurora.frag` (qsb is not on PATH).
- Uniform block: `qt_Matrix` + `qt_Opacity` first, then scalars/vec2/vec4 only —
  matched by name to ShaderEffect properties; arrays are unreliable across the
  property bridge.
- **Config = the plugin's own entry in `~/.config/omarchy/shell.json`** (the shell
  injects `shell`; `shell.shellConfig` is reactive, reassigned on file save, so a
  binding over it applies live while summoned). Env vars can NEVER work here:
  `omarchy-restart-shell` respawns via `hyprctl dispatch exec` precisely so the
  shell gets the canonical session env, not the caller's variables.

## Visual tuning history lives in git log (lookdev commits)

Sparse blur taps ghost thin features into double images; near-pixel shimmer
frequencies alias into moire; hard floor() column phase tiles rectangles; >81deg
meteor angles read as plumb lines; dark gradients band without a +-0.5/255 dither.
