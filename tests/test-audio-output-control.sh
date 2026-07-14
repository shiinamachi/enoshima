#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_audio-output-control
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

fail() {
  printf 'test-audio-output-control: %s\n' "$*" >&2
  exit 1
}

cat >"$work/wpctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${AUDIO_OUTPUT_LOG:?}"
FAKE
chmod 0700 "$work/wpctl"

export AUDIO_OUTPUT_WPCTL=$work/wpctl
export AUDIO_OUTPUT_LOG=$work/calls

printf '%s\n' '==> volume raise unmutes before changing volume'
: >"$AUDIO_OUTPUT_LOG"
bash "$helper" raise
mapfile -t calls <"$AUDIO_OUTPUT_LOG"
[[ ${#calls[@]} -eq 2 ]] || fail 'raise did not make exactly two wpctl calls'
[[ ${calls[0]} == 'set-mute @DEFAULT_AUDIO_SINK@ 0' ]] || fail 'raise did not unmute first'
[[ ${calls[1]} == 'set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+' ]] || fail 'raise volume call is wrong'

printf '%s\n' '==> lower and mute actions target the default sink'
: >"$AUDIO_OUTPUT_LOG"
bash "$helper" lower
bash "$helper" toggle-mute
bash "$helper" unmute
mapfile -t calls <"$AUDIO_OUTPUT_LOG"
[[ ${calls[0]} == 'set-volume @DEFAULT_AUDIO_SINK@ 5%-' ]] || fail 'lower volume call is wrong'
[[ ${calls[1]} == 'set-mute @DEFAULT_AUDIO_SINK@ toggle' ]] || fail 'mute toggle call is wrong'
[[ ${calls[2]} == 'set-mute @DEFAULT_AUDIO_SINK@ 0' ]] || fail 'explicit unmute call is wrong'

printf '%s\n' '==> invalid actions fail without touching audio state'
: >"$AUDIO_OUTPUT_LOG"
if bash "$helper" invalid 2>/dev/null; then
  fail 'invalid action unexpectedly succeeded'
fi
[[ ! -s $AUDIO_OUTPUT_LOG ]] || fail 'invalid action invoked wpctl'

printf '%s\n' 'Audio output control tests passed.'
