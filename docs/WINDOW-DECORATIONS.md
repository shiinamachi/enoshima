# 애플리케이션 창 장식 정책

## 소유권 계약

애플리케이션 창의 titlebar와 최소화, 최대화/복원, 닫기 control은 해당
애플리케이션 또는 그 toolkit이 소유한다. Waybar는 출력에 고정된 전역 상태
surface이며 애플리케이션 창 장식을 소유하지 않는다. 따라서 Waybar에는 활성 창
title과 창 control을 두지 않는다.

기본 우선순위는 다음과 같다.

1. 애플리케이션의 native client-side decoration 또는 toolkit decoration
2. 애플리케이션이 제공하는 system titlebar/border 설정
3. 장식 없는 필수 앱이 실제로 재현된 경우에만 compositor fallback 재검토

`hyprbars`는 기본적으로 비활성화한다. 공식
[`hyprbars:no_bar`](https://github.com/hyprwm/hyprland-plugins/tree/main/hyprbars#window-rules)는
일치하는 창에서 전역 bar를 끄는 exclude 규칙이며 특정 앱에서만 bar를 켜는
allowlist가 아니다. fallback을 도입하면 새 CSD 앱이 추가될 때마다 제외 규칙을
관리해야 하므로, 장식 누락이 확인됐다는 이유만으로 즉시 활성화하지 않는다.

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

자동 회귀 검사는 정책과 관리 설정을 검증하지만 실제 titlebar hit target,
dragging, dialog, multi-monitor 동작을 증명하지 않는다. 수동 통과 결과는 이 표의
`검증 상태`를 실제 날짜와 함께 갱신한다.

## Compositor fallback 등록 조건

현재 `hyprbars` fallback: 없음.

fallback을 추가하려면 다음 정보를 같은 변경에 기록하고 focused test와
`scripts/validate.sh`를 통과해야 한다.

- application과 정확한 runtime class/backend
- native/system decoration이 없다는 재현 절차와 증거
- fallback을 선택한 이유와 검증 날짜
- 기존 및 향후 CSD 앱에서 중복 bar를 막는 전체 exclude 계획
- 앱 update, Hyprland ABI 변경, multi-monitor, scaling 재검증 절차
- 한 커밋으로 되돌릴 수 있는 rollback
