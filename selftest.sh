#!/usr/bin/env bash
# Live-compositor gate for Borealis. Runs validate + qmllint, then selftest.qml
# beside the live shell, then checks the frame grabs offline (a blank shader
# paints black; palettes must differ; animation must move pixels).
# A red is only a verdict if the live shell outlived the run: the shell pid is
# recorded before and after, and a changed pid refuses the verdict (drift, not
# regression -- re-run).
cd "$(dirname "$0")" || exit 2
OUT="${XDG_RUNTIME_DIR:?}/borealis-selftest"
LOG="$OUT/selftest.log"
mkdir -p "$OUT"; rm -f "$OUT"/*.png

shell_pid() { ps -eo pid,cmd | awk '/quickshell -n -p \/usr\/share\/omarchy\/shell/ && !/awk/ {print $1; exit}'; }
hypr_pid() { pgrep -x Hyprland | head -1; }
SHELL0=$(shell_pid); HYPR0=$(hypr_pid)
echo "== shell pid $SHELL0 (etimes $(ps -o etimes= -p "$SHELL0" | tr -d ' ')s)  Hyprland pid $HYPR0"

fail=0
echo "== omarchy plugin validate"
omarchy plugin validate . || fail=1
echo "== qmllint"
qmllint -I /usr/lib/qt6/qml Borealis.qml selftest.qml || fail=1

echo "== selftest.qml (live compositor)"
timeout 60 quickshell -p selftest.qml >"$LOG" 2>&1
echo "quickshell exit $?"
grep -E "SELFTEST|qml|shader|C[0-9]{4}" "$LOG"

echo "== shader/runtime errors in harness output"
if grep -iE "C[0-9]{4}|shader.*(error|fail)|TypeError|ReferenceError" "$LOG"; then fail=1; else echo "none"; fi

echo "== frame analysis"
python3 - "$OUT" <<'PY' || fail=1
import subprocess, sys, glob, os
out = sys.argv[1]; ok = True
def mean(p):
    raw = subprocess.run(["ffmpeg","-v","error","-i",p,"-f","rawvideo","-pix_fmt","rgb24","-"],capture_output=True).stdout
    n = len(raw)//3
    return tuple(sum(raw[c::3])/n for c in range(3)), raw
frames = {}
for p in sorted(glob.glob(out+"/FRAME-*.png")):
    m, raw = mean(p); frames[os.path.basename(p)[6:-4]] = (m, raw)
    lit = sum(1 for i in range(0,len(raw),3) if raw[i]+raw[i+1]+raw[i+2] > 90)
    painted = max(m) > 3.0 and lit > 200
    print(f"  {os.path.basename(p)}: mean rgb=({m[0]:.1f},{m[1]:.1f},{m[2]:.1f}) lit_px={lit} PAINTED_OK={painted}")
    ok &= painted
need = ["A-aurora","B-aurora","C-ember","D-ice","E-nord","F-gold"]
missing = [k for k in need if k not in frames]
if missing: print("  MISSING grabs:", missing); ok = False
else:
    a, b = frames["A-aurora"][1], frames["B-aurora"][1]
    diff = sum(1 for x,y in zip(a,b) if abs(x-y) > 24)
    print(f"  A->B changed bytes={diff} ANIM_PIXELS_OK={diff > 1000}"); ok &= diff > 1000
    def d(x,y): return sum(abs(p-q) for p,q in zip(frames[x][0],frames[y][0]))
    for x,y in [("B-aurora","C-ember"),("C-ember","D-ice"),("D-ice","E-nord"),("E-nord","F-gold")]:
        print(f"  {x} vs {y} mean-rgb distance={d(x,y):.2f} PALETTE_DIFF_OK={d(x,y) > 1.0}"); ok &= d(x,y) > 1.0
    ember = frames["C-ember"][0]; ice = frames["D-ice"][0]
    print(f"  ember warmer than ice (R-B): ember={ember[0]-ember[2]:.2f} ice={ice[0]-ice[2]:.2f} HUE_OK={ember[0]-ember[2] > ice[0]-ice[2]}")
    ok &= ember[0]-ember[2] > ice[0]-ice[2]
    gold = frames["F-gold"][0]
    print(f"  gold warmer than ice (R-B): gold={gold[0]-gold[2]:.2f} ice={ice[0]-ice[2]:.2f} GOLD_HUE_OK={gold[0]-gold[2] > ice[0]-ice[2]}")
    ok &= gold[0]-gold[2] > ice[0]-ice[2]
sys.exit(0 if ok else 1)
PY

echo "== assertion tally"
grep -oE "[A-Z_]+_OK=(true|false)" "$LOG" | sort | uniq -c
if grep -qE "_OK=false" "$LOG"; then fail=1; fi
if ! grep -q "SELFTEST.*done" "$LOG"; then echo "harness did not reach done"; fail=1; fi

SHELL1=$(shell_pid); HYPR1=$(hypr_pid)
if [ "$SHELL0" != "$SHELL1" ] || [ "$HYPR0" != "$HYPR1" ]; then
  echo "== VERDICT REFUSED: live shell/compositor pid changed during the run ($SHELL0->$SHELL1, $HYPR0->$HYPR1). Re-run."
  exit 3
fi
echo "== shell pid $SHELL1 unchanged"
if [ $fail -eq 0 ]; then echo "== VERDICT GREEN"; else echo "== VERDICT RED (shell outlived the run; re-run once to separate drift from regression)"; fi
exit $fail
