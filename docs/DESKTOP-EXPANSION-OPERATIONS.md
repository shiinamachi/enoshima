# 데스크톱 확장 운영 가이드

이 문서는 `DESKTOP-EXPANSION.md`의 구현을 실제 워크스테이션에 적용하고,
Git이 소유하지 않는 계정 등록과 수동 검증을 완료하는 순서를 설명한다.
명령은 저장소 루트에서 실행하며, 계정 정보와 문서 데이터는 터미널 출력이나
저장소 파일에 기록하지 않는다.

## 소유권과 안전 경계

- pacman 패키지, greetd/Enoshima Auth, fallback SDDM, 시스템 서비스와 `/usr` 아래 파일은 Ansible 또는 로컬
  PKGBUILD가 소유한다.
- 배경화면, 데스크톱 설정, 실행 helper와 사용자 서비스는 chezmoi가 소유한다.
- rclone, Proton Mail Bridge, Cloudflare One, Bottles, KakaoTalk, Thunderbird,
  Obsidian, PhotoGIMP와 문서 편집 상태는 로컬 mutable state이며 Git에 넣지 않는다.
- rclone 설정 암호는 GNOME Keyring에만 저장한다. 설정 파일, systemd unit 또는
  셸 초기화 파일에 암호를 복사하지 않는다.
- fingerprint-only 로그인에서는 GNOME Keyring이 잠긴 채일 수 있다. 계정
  온보딩과 첫 전체 검증은 Enoshima Auth에서 비밀번호로 로그인한 세션에서 수행한다.
- Windows VM과 Obsidian vault는 이 단계에서 만들지 않는다. Parsec의 작은 관리
  UI는 선명한 XWayland 스트림을 위한 승인된 예외다.

## 자동 적용

적용 전에 저장소와 chezmoi 변경을 확인한다.

```bash
./scripts/validate.sh
make chezmoi-diff
```

기존 사용자 파일은 기본적으로 백업하면서 전체 구성을 적용한다.

```bash
./bootstrap.sh tpx1c13 --conflict-policy backup
```

bootstrap 순서는 다음과 같다.

1. `pacman -Syu` 방식의 Arch 전체 업그레이드와 bootstrap 의존성 설치
2. 검토·고정된 로컬 PKGBUILD 설치
3. Ansible 시스템 상태 적용
4. `packages/aur.txt`에 승인된 최신 AUR package base 설치
5. `ilysenko/codex-desktop-linux`에서 Codex Desktop native package 빌드·설치
6. AUR 패키지에 의존하는 Ansible 역할 재수렴
7. chezmoi 사용자 구성 적용
8. 기존 통합 postflight 실행

부분 업그레이드나 별도의 `pacman -Sy`를 실행하지 않는다.
실행 전 host·사용자·profile·policy 검증을 통과한 뒤에는 각 단계를 독립적으로
시도한다. 실패한 단계는 즉시 `FAILURE`로 기록하지만 AUR, chezmoi, plugin,
postflight를 포함한 실행 가능한 후속 단계는 계속한다. 마지막 요약에 실패가
하나라도 남으면 전체 종료 코드는 non-zero이며 성공 문구를 출력하지 않는다.

`packages/aur.txt` 자체가 AUR package base 승인 목록이다. 목록에 있는 package는
현재 upstream revision을 별도 commit/hash 승인 없이 설치한다. 한 package 설치가
실패하면 `FAILURE`로 기록하고 다음 승인 package 설치를 계속한다.

Codex Desktop은 `chatgpt-desktop-bin` AUR package를 사용하지 않는다.
`scripts/install-codex-desktop.sh`가 `ilysenko/codex-desktop-linux`의 `main`
checkout을 XDG cache에서 fast-forward로만 갱신하고 upstream의 Arch native
package를 로컬에서 빌드한다. 설치된 source revision이 같으면 재빌드하지 않으며,
upstream update manager는 package에 포함한다. 이 단계만 복구 목적으로 생략할
때는 `SKIP_CODEX_DESKTOP=true`를 사용한다.

`pear-desktop-bin`도 같은 승인 목록에 포함된다. 설치 후 Launcher 검색, Dock pin/unpin,
최소화·복원·닫기를 확인하고 `hyprctl clients -j`로 실제 class/title을 관찰하기 전에는
앱별 window rule을 추가하지 않는다. Pear Desktop의 desktop entry와 실행 파일
이름에는 upstream 호환성을 위해 아직 `youtube-music`이 남아 있다. FileZilla는 공식
Arch 패키지로 관리하며 Launcher 검색과 FTP/FTPS/SFTP 연결 시작을 별도로 확인한다.

`cloudflare-warp-bin`은 첫 실행에서 Ansible보다 뒤의 AUR 단계에 설치된다.
bootstrap은 AUR 단계 직후 desktop expansion 역할을 자동으로 다시 수렴시켜
`warp-svc.service`까지 같은 실행에서 enable/start한다. `SKIP_AUR=true`이면 새 AUR
설치는 의도적으로 생략하지만, 이미 설치된 패키지에 대한 재수렴은 계속 수행한다.

재부팅 후 Enoshima Auth에서 `enoshima Desktop` 세션으로 비밀번호 로그인한다.
Ansible은 현재 그래픽 세션을 종료하지 않기 위해 실행 중 display manager를
즉시 교체하지 않고, greetd를 다음 부팅의 유일한 display manager로 설정한다.
Enoshima Auth가 단일 관리 세션만 시작하도록 `/usr/local/share`의 session override를 이용해
패키지 소유 `Hyprland`와 `Hyprland (uwsm-managed)` 엔트리는 같은 파일명의
`Hidden=true` 로컬 override로 숨긴다. `/usr/share/wayland-sessions` 아래의
패키지 파일은 삭제하거나 수정하지 않는다.
chezmoi의 user-service hook은 Cyberdock을 enable하고 활성 그래픽 세션에서는
재시작한다. 다음 상태를 확인한다.

```bash
systemctl --user is-enabled cyberdock.service
systemctl --user status cyberdock.service --no-pager
```

`cyberdock.service`는 Quickshell Dock을 실행하며 비정상 종료나 stop 뒤에
`cyberdock-recover`를 호출한다. Dock 설정은
`~/.config/quickshell/cyberdock/shell.qml`이고, 모든 출력에 6픽셀 하단 hotspot과
숨김 상태의 짧은 reveal indicator를 만든다. 평시에는 74픽셀 작업 영역을
예약한 채 표시되고 CyberLauncher 또는 true fullscreen에서만 숨는다. Dock은
58픽셀 높이, 44x46 앱 표적, 420ms fullscreen 숨김 지연을 사용한다.

bootstrap이 적용하는 테마 자산은 다음과 같다.

- 외부·fallback: `~/.local/share/backgrounds/cyberpunk-library-16x9.jpg`
  (3840x2160)
- 내부 `eDP-1`: `~/.local/share/backgrounds/cyberpunk-library-16x10.jpg`
  (2880x1800)

Hyprpaper와 Hyprlock은 두 자산을 같은 모니터 규칙으로 사용한다. Waybar는 상단
14픽셀 여백과 48픽셀 높이를 사용한다. SwayNC의 8픽셀 top margin은 Waybar의
exclusive zone 뒤에 적용되어 화면 상단 약 70픽셀에서 panel을 시작한다.
Waybar는 출력 단위의 전역 상태만 표시하며 활성 앱 title과 앱 창 control을
표시하지 않는다.
Waybar의 network leader에 pointer를 올리면 WWAN과 Bluetooth
상태가 drawer로 나타나며, SwayNC에는 Wi-Fi, Bluetooth, Night Light, volume,
brightness의 실제 제어만 표시된다.

bootstrap은 공식 `hyprland-plugins` 저장소를 `hyprpm`으로 ABI에 맞춰 빌드하고,
`hyprbars`를 disable한 뒤 `hyprfocus`만 enable한다. C++ plugin은 compositor 안에서
실행되므로 임의의 `.so`를 직접 복사하거나 `--force`로 ABI 검사를 우회하지 않는다.
활성 session에서는 plugin reload 직후 config-only reload를 이어서 실행해 새로
등록된 plugin option이 managed Lua config로 다시 파싱되도록 한다.

```bash
hyprpm list
hyprctl plugin list -j | jq
hyprctl configerrors
```

`hyprfocus`가 실패해도 기본 cyan-violet 2픽셀 border와 모든 focus 단축키는
그대로 동작한다. 즉시 plugin을 분리해 진단하려면 다음 명령을 사용하고, 다음
bootstrap에서 원하는 상태로 다시 수렴시킨다.

Hyprland 0.55.4의 ABI pin에서는 `mode = flash`, `fade_opacity = 0.94`만 사용해
window geometry를 움직이지 않는다. reduced-motion과 accessible profile은
지원되는 `fade_opacity`를 1.0으로 덮어써 focus flash를 시각적으로 제거한다.
업그레이드 후 최신 schema가 노출되면 runtime detection이 keyboard flash와
mouse `none`을 선택하며, reduced-motion profile은 plugin `enable`을 끈다.

```bash
hyprpm disable hyprfocus
hyprpm reload
hyprctl reload config-only
```

모션이나 투명도에 민감한 경우 managed config를 수정하지 않고 아래 profile을
선택한다. 선택은 `$XDG_STATE_HOME/desktop-appearance/mode`에만 저장된다.

```bash
desktop-appearance reduced-motion
desktop-appearance reduced-transparency
desktop-appearance accessible
desktop-appearance default
```

## 디스플레이 프로젝션 모드

`Super+P` 또는 SwayNC의 **Display**를 누르면 현재 focus된 출력에 프로젝션
overlay가 열린다. 숫자 1–4, 화살표, Enter, Escape만으로도 다음 네 모드를 선택할
수 있다.

- **PC 화면만**: 내부 `eDP-1`만 활성화
- **복제**: 두 출력이 실제로 함께 지원하는 가장 높은 해상도와 주사율을 사용
- **확장**: topology에 저장한 배치 또는 managed seed 사용
- **두 번째 화면만**: 외부 출력만 활성화

적용 직전 layout은 `$XDG_RUNTIME_DIR/enoshima/display/`에 저장된다. 15초 안에
**변경 내용 유지**를 누르지 않으면 `desktop-display-revert.timer`가 직전 layout을
복원한다. 확인한 모드와 배치는 connector 이름 대신 monitor metadata로 계산한
topology 아래 `~/.config/enoshima/user/display-topologies/`에 저장되며 chezmoi가
덮어쓰지 않는다. hotplug와 config reload 후에는
`desktop-display-events.service`가 해당 topology를 다시 수렴시킨다.

CLI 진단과 복구 경로는 다음과 같다.

```bash
desktop-display-mode status --json
desktop-display-mode list --json
desktop-display-mode doctor
desktop-display-mode revert
desktop-display-mode import-current
desktop-display-mode apply-profile balanced
desktop-display-mode apply-profile matched
```

복제 후보가 없으면 화면을 변경하지 않고 실패한다. 고급 물리 배치는 overlay의
**고급 디스플레이 설정**에서 `nwg-displays`로 조정한 뒤
`desktop-display-mode import-current`로 현재 topology에 저장할 수 있다.
새 profile은 schema 2와 display policy revision을 함께 기록한다. schema 1의
관리 기본값과 이전 policy revision에서 `balanced`로 저장한 schema 2 profile은
`reconcile`에서 현재 기본값으로 갱신한다. `custom`, `matched`와 다른 배율이나
좌표가 있는 사용자 profile은 그대로 보존한다.

## 전원 및 세션 제어

Waybar 우측 전원 아이콘, `Super+M`, SwayNC의 **Power**는 모두 현재 focus된
출력에 같은 전원 메뉴를 연다. 잠금과 절전은 즉시 실행하며, 재시작과 시스템
종료는 확인을 한 번 더 요구한다. desktop action에는 `sudo`를 사용하지 않고
systemd-logind의 가능 여부와 polkit 인증 경로를 따른다.

```bash
desktop-power status --json
desktop-power lock
desktop-power logout
desktop-power suspend
desktop-power doctor
```

재시작과 종료는 `hyprshutdown --no-exit --no-fork`로 앱의 정상 close 요청과
저장 확인을 먼저 처리하되 Hyprland와 user manager는 유지한다. 앱 정리가 끝나면
systemd-logind의 `Reboot` 또는 `PowerOff` D-Bus method를 직접 호출하며,
직접 호출이 실패할 때만 `systemctl`을 fallback으로 사용한다. 요청 직전에 현재
boot ID와 `requested` phase가
`$XDG_STATE_HOME/enoshima/power/pending.json`에 기록되고, login1 호출 직전에
phase가 `login1_dispatching`으로 바뀐다. 다음 그래픽
로그인에서 `desktop-power-verify.service`는 boot ID 변화와 dispatch phase를 모두
비교해 `last-result.json`에 저장한다. 따라서 전원 버튼 종료처럼 boot ID만 바뀐
경우는 `boot_changed_without_dispatch`로 기록된다. `status --json`에 pending
action이 남아 있거나 결과가 `succeeded`가 아니면 다음 비파괴 진단을 먼저
수집한다.

```bash
desktop-power doctor | tee /tmp/enoshima-power-doctor.txt
journalctl -b -1 -n 200 --no-pager
systemd-inhibit --list
```

`doctor`는 reboot command 해석, logind 가능 여부, inhibitor, 실패한 system/user
unit, 이전 boot journal, firmware와 Thunderbolt 장치를 함께 보여준다. 원인이
확인되기 전에는 강제 재부팅이나 `reboot=` kernel parameter를 추가하지 않는다.
실제 완료 검증은 dock 미연결 10회와 연결 10회에서 `last-result.json`이 모두
`succeeded`인지 확인한다.

Quectel WWAN modem은 종료 직전 재탐색과 sleep preparation에서 멈출 수 있다.
`enoshima-wwan-quiesce.service`는 stop ordering상 NetworkManager와
ModemManager보다 먼저 active GSM 연결, modem, WWAN radio를 하나의 10초
monotonic deadline 안에서 정리한다. 각 단계의 exit status와 elapsed time은
구조화된 journal field로 남긴다. 확인된 90초 기본 stop timeout은
ModemManager에만 15초로 제한한다.
전역 systemd stop timeout은 변경하지 않는다. 이전 종료의 증거는 식별자를
redact하는 다음 helper로 수집한다.

```bash
enoshima-shutdown-doctor | tee /tmp/enoshima-shutdown-doctor.txt
```

### 덮개와 최대절전 검증

`@swap` 생성과 resume offset 반영은 boot artifact 변경이므로 Secure Boot key를
확인한 뒤 다음 경로로 적용한다.

```bash
./bootstrap.sh --apply-boot-artifacts
sudo sbctl sign-all
sudo sbctl verify
enoshima-power-doctor capture | tee /tmp/enoshima-power-capture.txt
```

먼저 `systemctl hibernate` 단독 경로를 테스트하고 linux-lts UKI rollback이
부팅되는지 확인한다. 이후 battery lid-close 20회, AC lid-close, docked
lid-close를 각각 검증한다. battery에서는 30분 뒤 최대절전으로 넘어가야 하며,
AC에서는 suspend를 유지하고, 외부 출력이 연결된 상태에서는 세션을 유지해야
한다. 각 복귀 후 Wi-Fi, Bluetooth, WWAN, audio, fingerprint, touchpad를 확인한다.

짧은 s2idle 구간은 시간당 0.7% 이하, 8시간 lid-close는 총 2% 이하를 목표로
측정한다. 기준을 넘으면 `enoshima-power-doctor capture`를 WWAN/Bluetooth/USB
조합별로 다시 수집한다. `powertop --auto-tune`은 상시 서비스로 적용하지 않는다.

## 권장 대화식 온보딩 순서

자동 적용과 재로그인을 마친 뒤 아래 순서를 사용한다. Cloudflare One이 DNS 경로를
바꾸므로 먼저 등록하고, 그 다음 cloud·mail·Bottles 연결을 설정하는 편이 회귀
검사를 단순하게 만든다.

1. 세션 테마, Dock과 기본 입력을 확인한다.
2. `cloudflare-one-setup`으로 tray를 켜고 GUI에서 Zero Trust 등록을 마친다.
3. `rclone-cloud-setup all`로 Google Drive와 Proton Drive를 등록한다.
4. `protonmail-bridge-setup`에서 Bridge와 Thunderbird를 연결한다.
5. `kakaotalk-connectivity-check`와 `kakaotalk-setup`을 실행한다.
6. ONLYOFFICE, RHWP Desktop과 PhotoGIMP를 복사본으로 검증한다.
7. Enoshima Auth 로그인과 SDDM 비상 rollback을 모두 수동 검증한다.

계정 등록 중 표시되는 계정명, 팀·조직 정보, 토큰과 생성된 메일 비밀번호를
문서, 이슈, 셸 기록 또는 Git에 복사하지 않는다.

## greetd 전환, Enoshima Auth acceptance와 SDDM rollback

`tpx1c13` inventory는 `desktop_login_manager: greetd`를 선택한다. Ansible은
`greetd.service`를 enable하고 `sddm.service`를 disable하지만, 기본
`desktop_login_manager_apply_now: false`에서는 실행 중인 display manager를
정지하지 않는다. 따라서 bootstrap을 실행한 현재 세션은 유지되고 실제 전환은
다음 재부팅에서 일어난다. 그래픽 세션 안에서 apply-now를 켜면 현재 세션이
종료되므로 이 값은 복구용 TTY에서만 임시 extra-var로 사용한다.

재부팅 전 다음을 확인한다.

```bash
systemctl is-enabled greetd.service
systemctl is-enabled sddm.service || true
Hyprland --verify-config -c /etc/greetd/hyprland.conf
grep -F 'Exec=uwsm start -e -D Hyprland start-hyprland' \
  /usr/local/share/wayland-sessions/enoshima-desktop.desktop
grep -F 'Hidden=true' \
  /usr/local/share/wayland-sessions/{hyprland,hyprland-uwsm}.desktop
```

첫 Enoshima Auth acceptance는 laptop-only, docked dual, lid-closed external-only에서
각각 수행한다.

`enoshima Desktop`은 UWSM에 `start-hyprland` 실행 파일을 직접 전달한다. UWSM
메타데이터 옵션의 다중 단어 인수가 greetd 실행 경로에서 다시 분리되지 않도록
실행 명령에는 표시 이름과 설명을 중복 지정하지 않는다. 표시 목록에서 숨긴
package session ID를 다시 참조하면 UWSM이 `Entry ... is hidden`으로 거부하므로
`hyprland.desktop`도 간접 실행 대상으로 사용하지 않는다.

- eDP는 2880x1800 scale 2.0, Dell은 3840x2160 scale 1.5로 표시된다.
- lid가 닫힐 때 활성 외장 출력이 있으면 eDP만 비활성화되고 Enoshima Auth가 외장
  출력으로 이동한다. 외장 출력이 없으면 마지막 eDP를 끄지 않는다.
- `enoshima Desktop` 세션 하나만 표시되고 비밀번호 로그인에 성공한다.
- 빈 비밀번호 제출 후 fingerprint 인증에 성공한다.
- 실패 메시지, 긴 사용자명과 login1 power controls가 잘리지 않는다.
- Waybar, Quickshell, Cyberdock, clipboard/history와 사용자 서비스가 greeter
  compositor에서 실행되지 않는다.
- 로그인 후 UWSM graphical session과 GNOME Keyring이 정상 시작된다.

Hyprlock은 로그인 관리자가 아니다. 이미 인증된 Hyprland 세션의 suspend/resume
잠금만 담당하며 greetd/Enoshima Auth를 대체하지 않는다.

SDDM은 한 릴리스 동안 package와 responsive cyberpunk theme를 유지한다. QML은
고정 1920x1080 root를 사용하지 않고, X11 greeter의 `QT_SCALE_FACTOR=1.5`만
적용한다. `QT_FONT_DPI`를 동시에 지정하지 않는다. `maya` fallback theme가 없으면
Ansible은 cyberpunk theme 선택을 거부한다.

Enoshima Auth에서 로그인할 수 없는 경우 `Ctrl+Alt+F2`로 TTY에 들어가 root 권한을
확보한 뒤 다음 순서로 즉시 되돌린다.

```bash
sudo systemctl disable --now greetd.service
sudo systemctl enable --now sddm.service
```

그 다음 inventory를 `desktop_login_manager: sddm`으로 바꾸고 전체 bootstrap을
다시 실행해 수동 상태를 desired state와 일치시킨다. cyberpunk SDDM theme 자체가
문제라면 로그인 전 TTY에서 다음 drop-in도 제거해 package fallback을 선택한다.

```bash
sudo rm -f /etc/sddm.conf.d/20-cyberpunk-theme.conf
```

SDDM에서 비밀번호, 빈 비밀번호 fingerprint, `enoshima Desktop` 세션 선택과
Power Off를 확인한다. fallback 검증 뒤에는 inventory를 `greetd`로 되돌리고
bootstrap과 재부팅으로 정상 경로를 복구한다. `/etc/pam.d/greetd`와
`/etc/pam.d/sddm`은 rollback 중 임의로 편집하지 않는다.

## Hyprlock 혼합 DPI acceptance

Hyprlock은 logical output에 대해 fractional scaling auto 모드를 명시하고, 인증
card의 너비와 input 높이는 읽기·터치 가능한 상한으로 유지한다. card는 논리 화면
중앙에 고정되고 `balanced`, `matched`, external-only에서 화면 밖으로 밀려나지
않는다. 정적 모델은 1920x1200, 1280x800, 2560x1440,
1920x1080, 1024x768, 800x600 logical output을 검사한다.

실제 장치에서는 다음을 모두 확인한다.

- eDP scale 1.5와 Dell scale 1.5에서 card, input, fingerprint/error text가 잘리지 않음
- laptop-only, docked dual, lid-closed external-only에서 password input이 즉시 focus됨
- 비밀번호와 fingerprint가 병렬로 동작하고 실패 후 재입력이 가능함
- suspend 직전에 잠기고 resume 직후 입력할 수 있음
- Caps Lock, 인증 중, 실패 상태가 색상뿐 아니라 기존 text/state 변화로도 구분됨

`hyprlock`을 실행하면 현재 세션이 즉시 잠기므로 원격 연결이 아닌 로컬 키보드와
fingerprint reader가 준비된 상태에서 시험한다.

## 앱 장식과 창 상태

공통 compositor titlebar는 사용하지 않는다. GTK·Electron 등 자체 장식을 지원하는
앱은 client-side titlebar를 사용하고, Ghostty도 `window-decoration = auto`로 이를
명시한다. Waybar는 앱별 titlebar가 아니므로 활성 앱 title이나
최소화·최대화/복원·닫기 control을 제공하지 않는다. 앱이 자체 titlebar를 제공하지
않더라도 keyboard와 Dock 제어는 유지된다. 앱별 class/backend, 장식 소유권과 검증
상태는 `WINDOW-DECORATIONS.md`에서 관리한다.

Acceptance에서는 다음을 확인한다.

- `Super+C`는 close, `Super+N`은 `cyberdock-minimize`
- `Super+F`는 true fullscreen
- Waybar에 활성 앱 title과 최소화, 최대화/복원, 닫기 controls가 없음
- 각 필수 앱의 자체 titlebar가 창과 함께 이동하고 네이티브 controls가 그 창만
  조작함
- Electron 앱 자체 최소화 요청이 `cyberdock-event-bridge.service`를 통해 Dock
  최소화 상태로 이어짐
- 앱 자체 titlebar가 compositor titlebar와 중복되지 않음
- 최소화된 창은 `special:minimized`에 있고 Dock에서 원래 workspace/output으로
  돌아오며 floating/maximized 상태도 복원됨

최소화 상태는 `$XDG_RUNTIME_DIR/cyberdock/`에만 저장된다. Dock 문제로
창이 보이지 않으면 다음 명령으로 모든 최소화 창을 안전한 현재 workspace로
복구한다.

```bash
cyberdock-recover
desktop-window-action status --json
```

## 마우스 창 이동과 크기 조절

`Super`를 누른 채 왼쪽 버튼으로 drag하면 창을 이동하고, 오른쪽 버튼으로
drag하면 크기를 조절한다. 창 경계 24 logical pixel 안에서는 `Super` 없이도
resize할 수 있다. source 설정이 아니라 현재 compositor에 적용된 상태는 다음으로
확인한다.

```bash
hypr-window-control-doctor
hypr-window-control-doctor --json | jq
```

`healthy: false`이면 `hyprctl binds -j`, `hyprctl devices -j`, 현재 submap과
`general:resize_on_border`를 함께 확인한다. ThinkPad에서는 touchpad physical click,
tap-and-drag, TrackPoint 버튼, USB/Bluetooth mouse를 각각 시험한다. 실제 button
code가 272/273과 다르다는 `wev` 증거가 있을 때만 device별 bind를 추가한다.

## Quickshell Cyberdock

현재 구현은 `cyberdock.service`, `shell.qml`, `cyberdock-state`,
`cyberdock-activate`, `cyberdock-minimize`, `cyberdock-recover`,
`desktop-window-action`, `cyberdock-event-bridge`, `cyberdock-pins`로 구성된다.
각 모니터에 동일한 사용자 pin과 모든 실행 창을
표시한다. 초기 seed는 Ghostty, Files, Zed, Google Chrome이며 Applications는 앱
pin과 분리된 고정 system control이다. 사용자 목록은
`~/.config/enoshima/user/cyberdock-pins.json`에 저장되고 chezmoi가 덮어쓰지 않는다.

다음 동작을 확인한다.

- 평시에는 작업 영역을 예약하고 지속 표시됨
- true fullscreen에서는 숨고 각 출력의 최하단 6픽셀에서 reveal됨
- CyberLauncher가 열린 동안에는 modal surface와 경쟁하지 않도록 숨음
- 정지된 pinned app은 실행되고, 실행 중인 app은 최근 창으로 이동
- 이미 focus된 단일 창을 다시 클릭해도 상태가 바뀌지 않음
- 창이 여러 개면 compact chooser가 표시됨
- 다른 출력의 창을 누르면 해당 monitor/workspace로 전환됨
- minimize 후 Dock indicator가 바뀌고 원래 위치로 restore됨
- Launcher 또는 Dock context menu에서 pin/unpin과 좌우 이동이 즉시 반영됨
- Dock의 pinned app을 가로로 drag하면 놓은 위치에 순서가 저장되고, 같은 동작을
  context menu의 **Move Left / Move Right**로도 수행할 수 있음
- 미설치된 pin은 **Unavailable** 상태로 자리를 유지하고 재설치 후 복원됨

keyboard에서는 `Super+N`으로 현재 창을 최소화하고 `Super+Shift+N`으로 모든
고립된 최소화 창을 복구할 수 있다.

복구 시험은 중요하지 않은 창으로만 수행한다.

```bash
cyberdock-minimize
cyberdock-recover
systemctl --user restart cyberdock.service
```

재시작 후 `hyprctl clients -j`에서 `special:minimized`에 고립된 창이 없어야 한다.

## rclone cloud mounts

GNOME Keyring이 열린 비밀번호 로그인 세션에서 두 remote를 대화식으로 등록한다.

```bash
rclone-cloud-setup all
```

개별 등록은 `rclone-cloud-setup google` 또는 `rclone-cloud-setup proton`을 쓴다.
helper는 고정 remote 이름과 backend type을 확인하고, 암호화된
`~/.config/rclone/rclone.conf`를 `0600`으로 유지한다. 설정 암호는
`rclone-cloud-password`가 실행 시 GNOME Keyring에서 읽는다.
기존 remote의 연결 검사가 실패하면 해당 mount unit을 먼저 중지하고 저장된
로그인 정보를 다시 입력받는다. 인증 복구가 끝나기 전까지 실패한 자격 증명을
백그라운드에서 반복 제출하지 않는다.

Mount와 cache 정책은 다음과 같다.

| Remote | Mount | Directory policy | Cache |
| --- | --- | --- | --- |
| Google Drive | `~/Cloud/GoogleDrive` | 168시간 cache, 1분 polling | 최대 50 GiB |
| Proton Drive | `~/Cloud/ProtonDrive` | 5분 cache, polling off, backend metadata cache off | 최대 50 GiB |

두 unit 모두 VFS full cache, 15분 write-back, 5 GiB 최소 여유 공간, `0700`
directory와 `0600` file mode를 사용한다. `--allow-other`는 사용하지 않으며 stop
때 lazy unmount한다. 두 unit의 `PrivateTmp=false`는 완화 가능한 보안 옵션이 아니라
FUSE mount가 desktop의 mount namespace에 보이기 위한 필수 조건이다. 이를
`true`로 바꾸면 `fusermount3: mount failed: Operation not permitted`가 재발한다.
Proton Drive backend는 experimental이며, 5분 간격으로만 service를 재시도하고
다른 client와 같은 파일을 동시에 편집하지 않는다.

```bash
systemctl --user status rclone-google-drive.service --no-pager
systemctl --user status rclone-proton-drive.service --no-pager
mountpoint "$HOME/Cloud/GoogleDrive"
mountpoint "$HOME/Cloud/ProtonDrive"
```

각 mount에서 임시 디렉터리를 만들어 create, read, rename, delete를 수행하고,
네트워크 재연결과 재로그인 뒤에도 다시 접근되는지 확인한다. `findmnt` 출력에
`allow_other`가 없어야 한다. Thunar sidebar에는 두 mount bookmark가 보여야 한다.

## Proton Mail Bridge와 Thunderbird

Bridge GUI와 분리된 core daemon은 공식 Arch `protonmail-bridge` 패키지로
설치된다. 계정 등록과 localhost IMAP/SMTP 설정은 다음 helper 안에서만
대화식으로 수행한다.

```bash
protonmail-bridge-setup
protonmail-bridge-status
```

Bridge GUI에서 로그인한 뒤 표시되는 localhost 설정을 Thunderbird에 직접
입력한다. 생성된 비밀번호를 터미널이나 Git 파일에 붙여넣지 않는다. 설정 완료를
확인하면 helper가 로컬 readiness marker를 만들고 `protonmail-bridge.service`를
활성화한다. marker가 없으면 unit은 실행되지 않는다.

Thunderbird는 `thunderbird-wayland` desktop entry로 시작되어야 하고 DOCUMENT
workspace 3에 나타나야 한다. send/receive, folder, attachment, notification과
offline reading을 시험한다. fingerprint-only 로그인 뒤 Bridge가 연결되지 않으면
먼저 GNOME Keyring을 대화식으로 unlock한다.

## Cloudflare One

Cloudflare는 Arch Linux를 지원하지 않는다. `cloudflare-warp-bin`은 vendor Ubuntu
package를 재포장한 검토 대상이며, 의미 있는 update마다 AUR 변경을 다시 확인한다.
Ansible은 패키지가 존재할 때만 `warp-svc.service`를 enable/start한다.

시스템 daemon 적용 후 그래픽 세션에서 다음을 실행한다.

```bash
cloudflare-one-setup
cloudflare-one-status
```

tray GUI에서 **Zero Trust security**를 선택하고 팀 입력과 identity-provider 흐름을
대화식으로 마친다. 등록 정보는 Git에 남기지 않는다. `cloudflare-one-status`는
조직 값을 출력하지 않고 package, daemon, tray D-Bus, 등록, connection mode와 DNS
소유 상태만 요약한다.

연결 후 WWAN DNS와 Wi-Fi→WWAN fallback, Bottles endpoint, 두 rclone mount, Proton
Bridge, Parsec와 browser를 다시 시험한다. WARP DNS 주소를 NetworkManager 설정이나
`/etc/resolv.conf`에 hard-code하지 않는다. `warp-diag`는 자동으로 실행하거나
업로드하지 않으며, 문제 분석에 필요한 경우에만 사용자가 직접 실행한다.

## KakaoTalk과 Bottles

Cloudflare 등록이나 네트워크 변경 후 먼저 비파괴 preflight를 실행한다.

```bash
kakaotalk-connectivity-check
kakaotalk-setup
```

preflight는 host와 Bottles Flatpak sandbox 양쪽에서
`https://ping.usebottles.com`의 DNS·HTTPS 경로와 Bottles가 사용하는 5초 제한의
pycurl `HEAD` 검사를 확인한다. 모바일망 DNS가 병렬 A/AAAA 질의를 처리하지 못하면
`kakaotalk-setup`이 Bottles 앱에만 `single-request-reopen` resolver 호환 옵션을
적용한다. 실패하면 DNS를 hard-code하지 말고 보고된 host/sandbox/WARP 경로를
복구한 뒤 retry한다.

`kakaotalk-setup`은 user-scoped Bottles에 64-bit application bottle을 만들고,
관리 프로필이 URL과 SHA-256으로 고정한 Wine 11.8 staging candidate,
X11/XWayland, 144 DPI와 `XMODIFIERS=@im=fcitx`를 설정한다. 144 DPI는 KakaoTalk가
고정되는 내부 OLED의 1.5x compositor scale과 일치한다. 숫자가 가장 큰
runner를 자동 선택하지 않는다. KakaoTalk의 Themida 보호기와 충돌하는 Soda 9를
사용하지 않으며, 게임용 DXVK/VKD3D DLL을 Wine 내장 DLL로 복원해 `Wrong DLL
Present` 오류를 방지한다. 파일 권한은 Downloads, Documents, Pictures로 제한된다.
기존 bottle을 재사용하면 setup이 KakaoTalk를 종료하고 profile 변경 전 private
Bottles snapshot을 자동 생성한다. installer 동의, 로그인과 post-login acceptance
snapshot은 대화식이다. update 전에도 Bottles에서 snapshot을 만들고 검증된 고정
runner를 유지한다. 프로필에 선언된 `cjkfonts`,
`vcrun2022`, `riched20`, `msftedit`도 setup이 같은 bottle에 적용한다.
Bottles 64.1은 GUI main loop가 없는 `bottles-cli`에서 component catalog callback을
완료하지 못하므로, setup helper가 해당 버전에서만 callback을 worker thread로
전달하고 bottle builder에 필요한 runner·DXVK·VKD3D를 준비한다. 생성 직후
KakaoTalk 호환 설정에서 고정 runner로 수렴시키고 DXVK·VKD3D는 제거한다.
KakaoTalk bottle은 `ko_KR.UTF-8`, Windows Korean locale/CP949와 한국 키보드를
사용한다. 관리되는 Pretendard를 bottle에 복사하고 Segoe UI, Tahoma, 맑은 고딕,
굴림과 돋움의 fallback으로 등록하므로 installer부터 한글 glyph를 표시할 수 있다.
launcher는 Wine 실행 직전에 XWayland의 독립 키맵에도
`korean:ralt_hangul`을 적용한다. 전용 bottle에는 `UseXIM=Y`를 명시하고 기존
`InputStyle=root` override를 제거한다. Wine 11.8의 기본 callback preedit가 조합
중인 현재 문자열을 카카오톡에 전달하므로 다음 글자가 입력될 때까지 이전 글자만
보이는 지연을 피한다.

로그인 후 `kakaotalk-smoke-test`로 첫 한글 입력 30회, 붙여넣기 10회,
Wayland↔KakaoTalk focus 전환 100회, tray notification, 수동 focus 복구와 재로그인을
검증한다. 통과 보고서만 다음 명령으로 로컬 known-good 상태로 승격할 수 있다.

```bash
kakaotalk-profile promote wine-11.8-staging-candidate --report REPORT.json
```

두 개 이상의 관리 프로필 사이에서 runner를 변경한 경우에는
`kakaotalk-profile rollback`으로 이전 로컬 선택과 runner를 복원한다. 최초
candidate 적용 자체를 되돌릴 때는 setup이 만든 **Before enoshima profile**
Bottles snapshot을 복원한다. 채팅, clipboard와 파일 송수신도 별도로 검증한다.
voice/video call과 screen sharing은 acceptance 대상이 아니다.

키보드 입력 전체가 끊긴 경우 Dock의 **입력 포커스 복구** 또는
`Super+Ctrl+K`를 사용한다. `kakaotalk-focus-guard.service`는 Hyprland event
socket에서 정확한 `kakaotalk.exe` 주소로 전환되는 순간 투명 Wayland sentinel을
90ms 활성화한 뒤 같은 주소로 focus를 되돌린다. 2초 rate limit으로 입력 도중
반복 실행되는 것을 막는다.

빈 title의 모든 `explorer.exe`를 숨기는 정적 rule은 사용하지 않는다. 최초 configure
후 32×32 이하이고 해당 PID의 `WINEPREFIX`가 KakaoTalk bottle인 surface만 주소
단위로 `special:tray`에 옮긴다. 크기가 큰 알림·대화 surface는 현재 monitor에 남아
클릭할 수 있다. `kakaotalk-doctor --json`으로 runner, XIM callback preedit, Fcitx,
tray proxy, focus guard와 비민감 window metadata를 함께 확인할 수 있다.

## ONLYOFFICE와 RHWP Desktop

ONLYOFFICE는 DOCX, XLSX, PPTX 기본 앱으로 배포된다. PDF 기본 앱은 기존 정책을
유지한다. 다음 MIME을 확인하고 대표 Microsoft 문서의 글꼴·표·수식·페이지 나눔을
검토한다.

```bash
xdg-mime query default application/vnd.openxmlformats-officedocument.wordprocessingml.document
xdg-mime query default application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
xdg-mime query default application/vnd.openxmlformats-officedocument.presentationml.presentation
xdg-mime query default application/pdf
```

RHWP Desktop은 보호된 Chromium sandbox를 쓰는 experimental client다. HWP/HWPX
파일을 `rhwp-desktop`으로 열면 원본 대신 `~/Documents/RHWP-Validation` 아래의
`0600` rollout copy가 열린다. 초기 검증 중에는 항상 **Save As**를 사용하고 원본을
덮어쓰지 않는다. 복잡한 정부 양식은 전달 전 Hancom Docs와 비교한다.

HWP와 HWPX 복사본이 각각 open, Save As, reopen, 비교를 통과한 뒤에만 기본 앱
게이트를 실행한다.

```bash
rhwp-enable-defaults "$VALIDATED_HWP_COPY" "$VALIDATED_HWPX_COPY"
```

helper가 요구하는 확인 문구는 화면을 읽고 직접 입력한다. 게이트 전에는 현재
`xdg-mime query default` 결과를 로컬 메모에 남겨 rollback 대상을 보존한다. RHWP
layout 문제가 있으면 기본 연결을 활성화하지 않고 ONLYOFFICE 또는 검증된 기존
viewer를 유지한다.

## PhotoGIMP와 GIMP rollback

Dock의 PhotoGIMP 항목 또는 다음 명령으로 isolated profile을 초기화한다.

```bash
photogimp
```

single-window layout, Photoshop 계열 shortcut, bracket brush resize, Wayland scale,
한글 텍스트 입력과 파일 열기를 검증한다. 첫 실행 뒤 `~/.config/PhotoGIMP`는 사용자
mutable state이므로 저장소에 추가하지 않는다.

PhotoGIMP profile이나 shortcut에 문제가 있으면 일반 GIMP를 실행해 즉시
rollback한다.

```bash
gimp
```

일반 GIMP profile은 PhotoGIMP profile과 분리되어 있어야 한다.

## 최종 수동 acceptance

자동 검증을 먼저 다시 실행한다.

```bash
./scripts/validate.sh
./scripts/postflight.sh
```

그 다음 아래 항목을 실제 두 출력과 대표 앱에서 확인한다.

### 화면, 글꼴과 창

- `balanced`에서 eDP-1은 scale 1.5/1920x1200, Dell은 scale 1.5/2560x1440이고
  두 출력의 logical bottom이 일치한다. `eDP-1`에는 16:10, 외부 출력에는 16:9 wallpaper가
  표시되며 lock, bar, launcher, notification, Dock과 titlebar palette가
  일치한다.
- `Super+P`의 네 모드를 각각 적용하고, 확인·수동 되돌리기·15초 자동 되돌리기와
  hotplug 후 topology 복원을 확인한다.
- `desktop-display-mode apply-profile matched`에서 eDP-1이 scale 2.25/1280x800,
  Dell이 scale 1.5/2560x1440으로 수렴하고, 되돌리기가 동작하는지 확인한다.
- OLED의 암부 뭉개짐, 120Hz에서 blur size 7/pass 2의 프레임 안정성, 40픽셀
  Waybar 모듈의 포인터 표적과 6픽셀 Dock hotspot을 확인한다.
- `fc-match sans-serif`에서는 Pretendard가, `fc-match monospace`에서는
  Jetendard가 우선한다.
- Ghostty의 최소 대비 4.5와 Zed One Dark override를 포함해 한글 폭, Nerd Font
  icon과 emoji fallback을 확인한다.
- Calibri/Cambria 호환 글꼴을 명시한 office 문서가 Carlito/Caladea로 적절히
  렌더링된다.
- Dock reveal/hide, multi-window chooser, cross-monitor focus, minimize/restore와
  crash recovery가 모두 동작한다.
- CyberLauncher가 두 출력에서 bar와 Dock을 포함한 전체 scrim을 소유하고,
  화면 비율에 맞는 크기와 네 개 quick-app label을 유지한다.
- SwayNC의 40픽셀 notification close target이 timestamp를 가리지 않고, panel이
  Waybar 아래 약 8픽셀 간격에서 시작한다.
- `desktop-appearance reduced-motion`, `reduced-transparency`, `accessible`을 각각
  적용해 공간 전환과 투명도 대체가 해당 profile 계약대로 동작한다.
- 대표 GTK, Electron, Qt, XWayland 앱에서 자체 close, minimize,
  maximize/restore가 해당 창만 조작하고, Hyprland true fullscreen이
  tiled·floating 창에서 중복 titlebar 없이 동작한다.

### HiDPI와 입력

- Discord, Slack, Thunderbird와 Parsec를 모두 실행한 뒤 다음을 확인한다.

  ```bash
  desktop-scaling-status
  ```

- Discord, Slack, Thunderbird는 `xwayland=false`, Parsec는 `xwayland=true`여야 한다.
- Chrome, Notion, Obsidian과 RHWP Desktop은 native Wayland에서 출력별 2.0/1.5
  scale과 Fcitx 입력이 정상이어야 한다. `GDK_SCALE`, `QT_SCALE_FACTOR`,
  `QT_FONT_DPI`, `--force-device-scale-factor` 같은 고정 전역 배율이 없어야 한다.
- `wev`로 physical Right Alt가 즉시 `Hangul`을 발생시키고 Alt modifier로 남지
  않는지 확인한다. F9 Hanja도 확인한다.
- `DISPLAY=:1 setxkbmap -query`에서 `korean:ralt_hangul`이 보이는지 확인하고,
  native Wayland editor, Electron 앱과 KakaoTalk에서 한/영 전환과 조합을 시험한다.

### 계정 기반 기능

- Google Drive와 Proton Drive에서 create/read/rename/delete, reconnect, relogin을
  통과하고 각 cache가 50 GiB 한도를 유지한다.
- Bridge/Thunderbird send·receive와 offline reading이 정상이며 profile이나 생성된
  credential이 Git에 없다.
- Cloudflare tray, Zero Trust 등록, daemon, connection과 DNS 상태가 정상이다.
- WARP 연결 뒤 WWAN fallback과 모든 네트워크 의존 앱을 다시 확인한다.
- KakaoTalk의 chat, Hangul, clipboard, file, tray와 notification이 정상이다.

### 문서와 그래픽

- ONLYOFFICE가 대표 DOCX/XLSX/PPTX를 허용 가능한 layout으로 연다.
- RHWP Desktop은 복사본만 편집하고 선택한 HWP/HWPX를 왕복 저장한다.
- PhotoGIMP가 isolated profile로 동작하고 일반 GIMP가 rollback 경로로 남는다.
- Obsidian은 DOCUMENT workspace 3에서 시작하되 vault를 생성하거나 선택하지 않는다.

마지막으로 다음 명령에서 예상하지 않은 secret·profile·문서·cache 파일이 Git
대상으로 나타나지 않는지 확인한다.

```bash
git status --short
```
