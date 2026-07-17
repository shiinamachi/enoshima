# 애플리케이션 창 장식 정책

## 소유권 계약

애플리케이션 창의 titlebar와 최소화, 최대화/복원, 닫기 control은 해당
애플리케이션 또는 그 toolkit이 소유한다. Waybar는 출력에 고정된 전역 상태
surface이며 애플리케이션 창 장식을 소유하지 않는다. 따라서 Waybar에는 활성 창
title과 창 control을 두지 않는다.

기본 우선순위는 다음과 같다.

1. 애플리케이션의 native client-side decoration 또는 toolkit decoration
2. 애플리케이션이 제공하는 system titlebar/border 설정
3. 장식 없는 앱만 `window-interaction.yaml` positive allowlist의 Enoshima titlebar

공식 `hyprbars`는 계속 비활성화한다. 공식
[`hyprbars:no_bar`](https://github.com/hyprwm/hyprland-plugins/tree/main/hyprbars#window-rules)는
일치하는 창에서 전역 bar를 끄는 exclude 규칙이며 특정 앱에서만 bar를 켜는
allowlist가 아니다. fallback을 도입하면 새 CSD 앱이 추가될 때마다 제외 규칙을
관리해야 하므로 사용하지 않는다. 대신 저장소가 직접 관리하는
`enoshima-decoration`은 positive allowlist를 내장하고, 설치된 Hyprland ABI로
매번 다시 빌드한다. 상세 상태·Snap 계약은
`docs/WINDOW-INTERACTION-CONTRACT.md`를 따른다.

## 관리 대상 매트릭스

`예상 class`는 현재 launcher, Hyprland rule, 실제 IPC 관찰을 합친 매칭 기준이다.
앱 update 뒤 달라질 수 있으므로 수동 acceptance에서는 다시 수집한다. `runtime
metadata 확인`은 class와 Wayland/XWayland backend만 확인했다는 뜻이며 titlebar의
시각·동작 acceptance를 대신하지 않는다.

| Application | 예상 class | Backend | 장식 소유자 | 관리 설정 | Fallback | 검증 상태 |
| --- | --- | --- | --- | --- | --- | --- |
| Google Chrome | `google-chrome` | Wayland | Chromium native decoration | `chrome-flags.conf`의 `WaylandWindowDecorations` | 없음 | runtime metadata 확인 2026-07-16, 수동 UI 검증 필요 |
| Notion | `.*notion.*` | Electron/Wayland | Electron native decoration | `notion-flags.conf`의 `WaylandWindowDecorations` | 없음 | 구성 확인 2026-07-16, 수동 UI 검증 필요 |
| Ghostty | `com.mitchellh.ghostty` | Wayland/GTK | Ghostty GTK decoration | `window-decoration = auto` | 없음 | runtime metadata 확인 2026-07-16, 수동 UI 검증 필요 |
| Thunar | `thunar` | Wayland/GTK | GTK native decoration | GTK 기본 설정 | 없음 | 수동 UI 검증 필요 |
| Zed | `dev.zed.Zed` | Wayland | 애플리케이션 native decoration | 애플리케이션 기본 설정 | 없음 | 수동 UI 검증 필요 |
| Discord | `discord` | Electron/Wayland | Electron native decoration | `discord-wayland`의 `WaylandWindowDecorations` | 없음 | 구성 확인 2026-07-16, 수동 UI 검증 필요 |
| Slack | `slack`, `com.slack.Slack` | Electron/Wayland | Electron native decoration | `slack-wayland`의 `WaylandWindowDecorations` | 없음 | 구성 확인 2026-07-16, 수동 UI 검증 필요 |
| Obsidian | `obsidian`, `md.obsidian` | Electron/Wayland | Electron native decoration | `obsidian/user-flags.conf`의 `WaylandWindowDecorations` | 없음 | 구성 확인 2026-07-16, 수동 UI 검증 필요 |
| Thunderbird | `thunderbird`, `org.mozilla.Thunderbird` | Wayland/GTK | 애플리케이션 native decoration | native Wayland launcher | 없음 | 수동 UI 검증 필요 |
| ONLYOFFICE | `onlyoffice.*`, `desktopeditors` | Qt/Wayland 또는 XWayland | 애플리케이션/toolkit decoration | 애플리케이션 기본 설정 | 없음 | backend와 수동 UI 검증 필요 |
| RHWP Desktop | `rhwp.*` | Electron/Wayland | Electron native decoration | package wrapper의 `WaylandWindowDecorations` | 없음 | 구성 확인 2026-07-16, 수동 UI 검증 필요 |
| Pear Desktop | upstream `youtube-music` 계열 | Electron/Wayland | Electron native decoration | upstream launcher와 실제 class 우선 | 없음 | backend와 수동 UI 검증 필요 |
| KakaoTalk | `kakaotalk.exe` | Wine/XWayland | Wine decoration | 전용 Bottles X11/Wine profile | 없음 | runtime metadata 확인 2026-07-16, 수동 UI 검증 필요 |
| Parsec | `parsecd` | XWayland | 애플리케이션/XWayland decoration | zero scaling 승인 예외 | 없음 | runtime metadata 확인 2026-07-16, 수동 UI 검증 필요 |
| mpv | `mpv` | Wayland/XWayland | Enoshima system titlebar | positive allowlist | 공식 hyprbars 없음 | 수동 UI 검증 필요 |
| imv | `imv` | Wayland | Enoshima system titlebar | positive allowlist | 공식 hyprbars 없음 | 수동 UI 검증 필요 |
| Zathura | `org.pwmt.zathura` | Wayland | Enoshima system titlebar | positive allowlist | 공식 hyprbars 없음 | 수동 UI 검증 필요 |

## 수동 검증 절차

앱별 metadata를 먼저 수집한다. title에 문서명이나 계정 정보가 포함될 수 있으므로
공유 보고서에는 필요한 class/backend만 남긴다.

```bash
hyprctl clients -j |
  jq -r '.[] |
    [.class, .initialClass, (.xwayland | tostring), .address] |
    @tsv'
```

각 필수 앱에서 다음 항목을 내부·외부 출력, 100%·fractional scaling, tiled·floating
상태로 확인한다.

- titlebar를 끌면 해당 앱 창과 함께 이동한다.
- native 최소화가 `special:minimized`와 Cyberdock indicator에 반영된다.
- Cyberdock restore가 기록된 정확한 Hyprland address와 원래 workspace/output을
  복원한다.
- 최대화/복원은 Waybar와 Cyberdock의 exclusive zone을 침범하지 않는다.
- true fullscreen은 `Super+F`로 별도 동작하며 최대화와 혼동되지 않는다.
- 닫기는 강제 process kill이 아니라 client close 요청이며, 저장되지 않은 문서는
  앱의 확인 dialog를 표시한다.
- CSD와 compositor titlebar가 중복되지 않는다.
- 확대와 fractional scaling에서도 control이 잘리거나 pointer target이 지나치게
  작아지지 않는다.

Electron CSD 최소화 경로를 확인할 때는 별도 터미널에서 Hyprland의 문서화된
`minimized` 이벤트만 관찰한다. title이 포함되는 다른 이벤트는 기록하지 않는다.

```bash
socat -u \
  UNIX-CONNECT:"$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" - |
  stdbuf -oL grep -E '^(minimized|fullscreen)>>'
```

필요하면 테스트용 profile로 앱 하나를 실행하고 `WAYLAND_DEBUG=client`에서
`xdg_toplevel.set_minimized()`와 `set_maximized()` 요청을 확인한다. 이 로그에는
업무 데이터가 포함될 수 있으므로 저장소나 공유 보고서에 원문을 남기지 않는다.

`cyberdock-event-bridge`는 시간 기반 debounce나 문서화되지 않은 `minimize`
이벤트에 의존하지 않는다. 이벤트를 새로운 명령으로 바꾸지 않고 schema 2 상태
머신의 관측 입력으로만 전달해 다음 전이만 허용한다.

| 현재 상태 | 이벤트 | 결과 |
| --- | --- | --- |
| 일반 | `minimized(...,1)` | 원래 workspace/output/창 상태를 기록하고 최소화 |
| 최소화 | `minimized(...,1)` | no-op |
| 최소화 | `minimized(...,0)` | 기록된 상태로 복원 |
| 일반 | `minimized(...,0)` | no-op |

자동 회귀 검사는 정책과 관리 설정을 검증하지만 실제 titlebar hit target,
dragging, dialog, multi-monitor 동작을 증명하지 않는다. 수동 통과 결과는 이 표의
`검증 상태`를 실제 날짜와 함께 갱신한다.

## Enoshima system titlebar 등록 조건

현재 positive allowlist는 `mpv`, `imv`, `org.pwmt.zathura`다. 공식 `hyprbars`
fallback은 없다.

allowlist를 추가하려면 다음 정보를 같은 변경에 기록하고 focused test와
`scripts/validate.sh`를 통과해야 한다.

- application과 정확한 runtime class/backend
- native/system decoration이 없다는 재현 절차와 증거
- fallback을 선택한 이유와 검증 날짜
- CSD가 없다는 증거와 class가 client-owned registry에 없다는 검사
- 앱 update, Hyprland ABI 변경, multi-monitor, scaling 재검증 절차
- 한 커밋으로 되돌릴 수 있는 rollback
