# 데스크톱 확장 운영 가이드

이 문서는 `DESKTOP-EXPANSION.md`의 구현을 실제 워크스테이션에 적용하고,
Git이 소유하지 않는 계정 등록과 수동 검증을 완료하는 순서를 설명한다.
명령은 저장소 루트에서 실행하며, 계정 정보와 문서 데이터는 터미널 출력이나
저장소 파일에 기록하지 않는다.

## 소유권과 안전 경계

- pacman 패키지, SDDM, 시스템 서비스와 `/usr` 아래 파일은 Ansible 또는 로컬
  PKGBUILD가 소유한다.
- 배경화면, 데스크톱 설정, 실행 helper와 사용자 서비스는 chezmoi가 소유한다.
- rclone, Proton Mail Bridge, Cloudflare One, Bottles, KakaoTalk, Thunderbird,
  Obsidian, PhotoGIMP와 문서 편집 상태는 로컬 mutable state이며 Git에 넣지 않는다.
- rclone 설정 암호는 GNOME Keyring에만 저장한다. 설정 파일, systemd unit 또는
  셸 초기화 파일에 암호를 복사하지 않는다.
- fingerprint-only 로그인에서는 GNOME Keyring이 잠긴 채일 수 있다. 계정
  온보딩과 첫 전체 검증은 SDDM에서 비밀번호로 로그인한 세션에서 수행한다.
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
4. 검토된 AUR allowlist 설치
5. AUR 패키지에 의존하는 Ansible 역할 재수렴
6. chezmoi 사용자 구성 적용
7. 기존 통합 postflight 실행

부분 업그레이드나 별도의 `pacman -Sy`를 실행하지 않는다.

`cloudflare-warp-bin`은 첫 실행에서 Ansible보다 뒤의 AUR 단계에 설치된다.
bootstrap은 AUR 단계 직후 desktop expansion 역할을 자동으로 다시 수렴시켜
`warp-svc.service`까지 같은 실행에서 enable/start한다. `SKIP_AUR=true`이면 새 AUR
설치는 의도적으로 생략하지만, 이미 설치된 패키지에 대한 재수렴은 계속 수행한다.

로그아웃 후 SDDM에서 `Hyprland (uwsm-managed)` 세션으로 비밀번호 로그인한다.
chezmoi의 user-service hook은 Cyberdock을 enable하고 활성 그래픽 세션에서는
재시작한다. 다음 상태를 확인한다.

```bash
systemctl --user is-enabled cyberdock.service
systemctl --user status cyberdock.service --no-pager
```

`cyberdock.service`는 Quickshell Dock을 실행하며 비정상 종료나 stop 뒤에
`cyberdock-recover`를 호출한다. Dock 설정은
`~/.config/quickshell/cyberdock/shell.qml`이고, 모든 출력에 1픽셀 하단 hotspot과
작업 영역을 예약하지 않는 Dock을 만든다.

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
7. 전체 수동 acceptance를 통과한 뒤에만 SDDM cyberpunk theme를 활성화한다.

계정 등록 중 표시되는 계정명, 팀·조직 정보, 토큰과 생성된 메일 비밀번호를
문서, 이슈, 셸 기록 또는 Git에 복사하지 않는다.

## SDDM 활성화 게이트와 rollback

Ansible은 cyberpunk SDDM theme와 배경화면을 설치하지만 기본값
`desktop_expansion_sddm_theme_enabled: false`에서는 선택 drop-in을 제거한다.
기본 fallback theme는 `maya`이며, 해당 theme의 `Main.qml`이 없으면 Ansible이
cyberpunk theme 활성화를 거부한다. 이 작업은 기존 SDDM PAM과 fingerprint 정책을
수정하지 않는다.

활성화 전 다음을 세션 안에서 먼저 검증한다.

- Hyprpaper, Waybar, SwayNC, Hyprlauncher, Hyprlock, Dock과 앱 자체 titlebar의 색·글꼴
- 내부·외부 출력의 배경 crop과 가독성
- Hyprlock의 비밀번호와 fingerprint 인증
- TTY 로그인과 root 셸 접근 가능성

검증 후 host inventory에 다음 desired state를 기록하고 desktop expansion 역할을
적용한다.

```yaml
desktop_expansion_sddm_theme_enabled: true
desktop_expansion_sddm_fallback_theme: maya
```

재부팅 전 `/etc/sddm.conf.d/20-cyberpunk-theme.conf`가 cyberpunk theme만
선택하는지 확인한다. SDDM에서 비밀번호 로그인, fingerprint 로그인, 세션 선택과
실패 후 재입력을 모두 시험한다.

정상 rollback은 inventory 값을 `false`로 되돌리고 같은 Ansible 역할을 다시
적용하는 것이다. 로그인이 불가능한 비상 상황에서는 TTY에서 다음 drop-in만
제거해 package fallback으로 복구한 뒤, inventory도 반드시 `false`로 고친다.

```bash
sudo rm -f /etc/sddm.conf.d/20-cyberpunk-theme.conf
```

실행 중인 그래픽 세션에서 SDDM을 재시작하면 세션이 종료되므로, 재시작은 TTY나
다음 부팅에서 수행한다. `/etc/pam.d/sddm`은 rollback 과정에서 수정하지 않는다.

## 앱 장식과 창 상태

공통 compositor titlebar는 사용하지 않는다. GTK·Electron 등 자체 장식을 지원하는
앱은 client-side titlebar를 사용하고, Ghostty도 `window-decoration = auto`로 이를
명시한다. 앱이 자체 titlebar를 제공하지 않더라도 keyboard와 Dock 제어는 유지된다.

Acceptance에서는 다음을 확인한다.

- `Super+C`는 close, `Super+N`은 `cyberdock-minimize`
- `Super+F`는 true fullscreen
- 앱 자체 titlebar가 compositor titlebar와 중복되지 않음
- 최소화된 창은 `special:minimized`에 있고 Dock에서 원래 workspace/output으로
  돌아옴

최소화 상태는 `$XDG_RUNTIME_DIR/cyberdock/`에만 저장된다. Dock 문제로
창이 보이지 않으면 다음 명령으로 모든 최소화 창을 안전한 현재 workspace로
복구한다.

```bash
cyberdock-recover
```

## Quickshell Cyberdock

현재 구현은 `cyberdock.service`, `shell.qml`, `cyberdock-state`,
`cyberdock-activate`, `cyberdock-minimize`, `cyberdock-recover`로 구성된다.
각 모니터에 동일한 pinned app과 모든 실행 창을 표시한다. pinned 순서는 Thunar,
Chrome, Ghostty, Zed, KakaoTalk, Thunderbird, Obsidian, Bottles, PhotoGIMP,
ONLYOFFICE, RHWP Desktop이다.

다음 동작을 확인한다.

- 기본은 숨김이고 각 출력의 최하단 1픽셀에서 reveal됨
- pointer가 Dock과 hotspot을 떠나면 다시 숨김
- 정지된 pinned app은 실행되고, 실행 중인 app은 최근 창으로 이동
- 이미 focus된 단일 창을 다시 클릭해도 상태가 바뀌지 않음
- 창이 여러 개면 compact chooser가 표시됨
- 다른 출력의 창을 누르면 해당 monitor/workspace로 전환됨
- minimize 후 Dock indicator가 바뀌고 원래 위치로 restore됨

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

Mount와 cache 정책은 다음과 같다.

| Remote | Mount | Directory policy | Cache |
| --- | --- | --- | --- |
| Google Drive | `~/Cloud/GoogleDrive` | 168시간 cache, 1분 polling | 최대 50 GiB |
| Proton Drive | `~/Cloud/ProtonDrive` | 5분 cache, polling off, backend metadata cache off | 최대 50 GiB |

두 unit 모두 VFS full cache, 15분 write-back, 5 GiB 최소 여유 공간, `0700`
directory와 `0600` file mode를 사용한다. `--allow-other`는 사용하지 않으며 stop
때 lazy unmount한다. Proton Drive backend는 experimental이며 다른 client와 같은
파일을 동시에 편집하지 않는다.

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
XWayland/Wine, 144 DPI와 `XMODIFIERS=@im=fcitx`를 설정한다. 파일 권한은 Downloads,
Documents, Pictures로 제한된다. installer 동의, 로그인과 snapshot 생성은
대화식이다. update 전 Bottles에서 snapshot을 만들고 동작 중인 runner를 유지한다.
Bottles 64.1은 GUI main loop가 없는 `bottles-cli`에서 component catalog callback을
완료하지 못하므로, setup helper가 해당 버전에서만 callback을 worker thread로
전달하고 runner·DXVK·VKD3D를 준비한 뒤 동일한 Bottles bottle builder를 호출한다.

채팅, 한글 조합, clipboard, 파일 송수신, tray 복원과 notification을 검증한다.
voice/video call과 screen sharing은 acceptance 대상이 아니다.

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

- 두 출력이 scale 1.5이고 wallpaper, lock, bar, launcher, notification, Dock과
  titlebar palette가 일치한다.
- `fc-match sans-serif`에서는 Pretendard가, `fc-match monospace`에서는
  Jetendard가 우선한다.
- Ghostty와 Zed에서 한글 폭, Nerd Font icon과 emoji fallback을 확인한다.
- Calibri/Cambria 호환 글꼴을 명시한 office 문서가 Carlito/Caladea로 적절히
  렌더링된다.
- Dock reveal/hide, multi-window chooser, cross-monitor focus, minimize/restore와
  crash recovery가 모두 동작한다.
- close, minimize, maximize/restore와 true fullscreen이 tiled·floating 창에서
  중복 titlebar 없이 동작한다.

### HiDPI와 입력

- Discord, Slack, Thunderbird와 Parsec를 모두 실행한 뒤 다음을 확인한다.

  ```bash
  desktop-scaling-status
  ```

- Discord, Slack, Thunderbird는 `xwayland=false`, Parsec는 `xwayland=true`여야 한다.
- Chrome, Notion, Obsidian과 RHWP Desktop은 native Wayland에서 1.5 scale과 Fcitx
  입력이 정상이어야 한다.
- `wev`로 physical Right Alt가 즉시 `Hangul`을 발생시키고 Alt modifier로 남지
  않는지 확인한다. F9 Hanja도 확인한다.
- native Wayland editor, Electron 앱과 KakaoTalk에서 한/영 전환과 조합을 시험한다.

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
