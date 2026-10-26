#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_HOME="${IOS_USE_HOME:-$HOME/.ios-use/test-homes/audio}"
mkdir -p "$TEST_HOME"
TEST_ROOT="$(mktemp -d "$TEST_HOME/native.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
  -DIOS_USE_PLAY_AUDIO_TESTING -dynamiclib -framework Foundation -framework CoreAudio \
  "$ROOT_DIR/playcover-runtime/IOSUsePlayAudio.m" -o "$TEST_ROOT/Audio.dylib"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
  -Wno-deprecated-declarations -I"$ROOT_DIR/playcover-runtime" -framework Foundation -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
  "$ROOT_DIR/playcover-runtime/tests/AudioHarness.m" "$TEST_ROOT/Audio.dylib" -o "$TEST_ROOT/harness"
"$TEST_ROOT/harness" unit
if [[ "${1:-}" == "--output" ]]; then
  # Quiet synthetic PCM, no recording or microphone access. Exercises the real
  # HAL output callbacks; isolated helpers never change system output volume.
  python3 - "$TEST_ROOT" <<'PY'
import concurrent.futures, math, pathlib, struct, subprocess, sys, wave
root=pathlib.Path(sys.argv[1]); tone=root/'tone.wav'
with wave.open(str(tone),'wb') as out:
    out.setparams((1,2,48000,0,'NONE','none'))
    frame=b''.join(struct.pack('<h',int(300*math.sin(2*math.pi*440*i/48000))) for i in range(48000))
    out.writeframes(frame*15)
def run(mode):subprocess.run([str(root/'harness'),mode,str(tone)],check=True,timeout=30)
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
    control=executor.submit(run,'control')
    for mode in ['player','avplayer','engine','queue','callback','block','dual']:run(mode)
    control.result()
PY
elif [[ -n "${1:-}" ]]; then
  echo "Usage: $0 [--output]" >&2; exit 64
fi
