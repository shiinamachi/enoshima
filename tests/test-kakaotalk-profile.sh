#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_kakaotalk-profile
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

config_home=$test_root/config
cache_home=$test_root/cache
runners_dir=$test_root/runners
profile_dir=$config_home/enoshima/kakaotalk/profiles
defaults_dir=$config_home/enoshima/defaults
fake_bin=$test_root/bin
archive_root=$test_root/archive/wine-test
mkdir -p -- "$profile_dir" "$defaults_dir" "$fake_bin" "$archive_root/bin"

printf '#!/usr/bin/env bash\nprintf "wine-11.8 (Staging)\\n"\n' >"$archive_root/bin/wine"
chmod +x "$archive_root/bin/wine"
tar -C "$test_root/archive" -cJf "$test_root/runner.tar.xz" wine-test
archive_sha=$(sha256sum "$test_root/runner.tar.xz" | awk '{print $1}')

cat >"$defaults_dir/kakaotalk.json" <<'EOF'
{"schema":1,"default_profile":"wine-11.8-staging-candidate"}
EOF

jq -n --arg sha "$archive_sha" '
  {
    schema: 1,
    id: "wine-11.8-staging-candidate",
    status: "candidate",
    runner: {
      name: "wine-11.8-staging-amd64",
      wine_version_pattern: "^wine-11\\.8 \\(Staging\\)$",
      source_url: "https://example.invalid/wine.tar.xz",
      sha256: $sha
    },
    bottle: {
      architecture: "win64", environment: "application", graphics: "x11",
      dxvk: false, vkd3d: false, dpi: 144
    },
    dependencies: [
      {id:"cjkfonts",winetricks:"cjkfonts"},
      {id:"vcredist2022",winetricks:"vcrun2022"},
      {id:"riched20",winetricks:"riched20"},
      {id:"msftedit",winetricks:"msftedit"}
    ],
    registry: {input_style:"root"},
    acceptance: {
      direct_hangul_inputs:30,paste_trials:10,focus_transitions:100,
      requires_relogin:true,requires_tray_notification:true
    }
  }
' >"$profile_dir/wine-11.8-staging-candidate.json"

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
while (($#)); do
  if [[ $1 == --output ]]; then output=$2; shift 2; else shift; fi
done
cp -- "${FAKE_ARCHIVE:?}" "$output"
EOF

cat >"$fake_bin/flatpak" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'flatpak %s\n' "$*" >>"${FAKE_CALL_LOG:?}"
if [[ $* == *'--json list bottles'* ]]; then
  printf '{"KakaoTalk":{"Runner":"wine-11.8-staging-amd64"}}\n'
fi
EOF
chmod +x "$fake_bin/curl" "$fake_bin/flatpak"

run_profile() {
  env \
    PATH="$fake_bin:/usr/bin" \
    FAKE_ARCHIVE="$test_root/runner.tar.xz" \
    FAKE_CALL_LOG="$test_root/calls.log" \
    KAKAOTALK_PROFILE_CONFIG_HOME="$config_home" \
    KAKAOTALK_PROFILE_CACHE_HOME="$cache_home" \
    KAKAOTALK_PROFILE_RUNNERS_DIR="$runners_dir" \
    KAKAOTALK_PROFILE_CURL="$fake_bin/curl" \
    KAKAOTALK_PROFILE_FLATPAK="$fake_bin/flatpak" \
    bash "$helper" "$@"
}

current=$(run_profile current --json)
jq -e '
  .id == "wine-11.8-staging-candidate" and
  .runner.name == "wine-11.8-staging-amd64" and
  .promoted == false
' <<<"$current" >/dev/null

run_profile install
[[ -x $runners_dir/wine-11.8-staging-amd64/bin/wine ]]
jq -e --arg sha "$archive_sha" '
  .schema == 1 and
  .profile_id == "wine-11.8-staging-candidate" and
  .archive_sha256 == $sha
' "$runners_dir/wine-11.8-staging-amd64/.enoshima-profile.json" >/dev/null
run_profile verify

run_profile select wine-11.8-staging-candidate
user_file=$config_home/enoshima/user/kakaotalk-profile.json
jq -e '
  .profile_id == "wine-11.8-staging-candidate" and
  .status == "candidate" and
  .previous.profile_id == "wine-11.8-staging-candidate"
' "$user_file" >/dev/null

report=$test_root/report.json
jq -n '{
  schema:1,profile_id:"wine-11.8-staging-candidate",status:"passed",
  results:{direct_hangul_inputs:30,paste_trials:10,focus_transitions:100,
    tray_notification:true,focus_repair:true,relogin:true}
}' >"$report"
run_profile promote wine-11.8-staging-candidate --report "$report"
jq -e '.status == "known-good" and (.report_sha256 | test("^[0-9a-f]{64}$"))' \
  "$user_file" >/dev/null

run_profile rollback
jq -e '.status == "candidate" and .previous == null' "$user_file" >/dev/null
grep -Fq -- 'edit -b KakaoTalk --runner wine-11.8-staging-amd64' \
  "$test_root/calls.log"

jq '.results.focus_transitions = 99' "$report" >"$test_root/failed-report.json"
if run_profile promote wine-11.8-staging-candidate \
  --report "$test_root/failed-report.json" >/dev/null 2>&1; then
  printf 'An insufficient acceptance report was promoted.\n' >&2
  exit 1
fi

printf 'KakaoTalk profile tests passed.\n'
