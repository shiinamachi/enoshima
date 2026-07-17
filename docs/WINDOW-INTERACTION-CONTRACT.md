# Enoshima 창 상호작용 계약

이 문서는 키보드, 포인터, 앱 자체 titlebar, Enoshima titlebar, Cyberdock이
동일한 창을 서로 다르게 해석하지 않도록 하는 런타임 계약이다. 앱별 장식 소유권의
source of truth는 `home/dot_config/enoshima/window-interaction.yaml`이다.

## 장식 소유권

우선순위는 `client-native`, `client-system`, `enoshima-system` 순서다.
`enoshima-decoration`은 positive allowlist의 class glob에만 붙으며, 그 외 모든
창은 client 소유로 간주한다. 공식 `hyprbars`는 계속 비활성화한다. 동일 창에 CSD와
Enoshima bar가 함께 보이면 정책 실패다.

플러그인은 설치된 Hyprland의 40자 ABI와 동일한 header로 매 bootstrap마다 빌드해
`$XDG_DATA_HOME/enoshima/plugins/<ABI>/`에 설치한다. ABI 기록이 다르면 loader는
플러그인을 로드하지 않는다.

## 주소 기반 상태 머신

`cyberdock-state` schema 2가 창 address별 상태를 소유한다.

```text
visible → minimizing → minimized → restoring → visible
   └──────────────────── closing → closed
```

각 record는 `desiredState`, `origin`, `sequence`, `generation`, 원래 workspace,
monitor, floating/fullscreen 상태를 가진다. 허용 origin은 `client`, `titlebar`,
`dock`, `keyboard`, `compositor`, `recovery`, `migration`이다.

Hyprland `minimized` 이벤트는 명령이 아니라 관측 결과다. event bridge는 이벤트를
`observe-minimized`에 전달할 뿐 controller를 재호출하지 않는다. 이로써 앱의
native 버튼과 Dock 버튼이 서로 최소화/복원을 반복하는 순환을 차단한다. 닫기는
항상 client close request이며 PID kill을 사용하지 않는다.

## 포인터와 키보드

- 제목 영역 drag: 수정키 없이 창 이동
- 제목 영역 double-click: 최대화/복원
- 제목 영역 right-click 또는 `Alt+Space`: 시스템 창 메뉴
- 시스템 메뉴 이동/크기 조절: 방향키 20px, Enter 완료, Esc 취소
- edge/corner 16px 진입: Snap Assist preview
- release: 화면 scale과 reserved area를 반영한 geometry commit
- threshold 이탈 또는 drag 중 Esc: preview 취소
- `Super+Left/Right/Up/Down`: 같은 snap controller로 절반/절반/최대화/최소화
- `Super+H/J/K/L`: 타일 focus 유지
- `Super+drag`: 장식 없는 client를 위한 power-user fallback 유지

Preview는 2px border와 fill을 함께 사용하며 reduced-transparency에서는 불투명
surface를 쓴다. 최종 geometry는 각 monitor의 logical size와 `[top, bottom, left,
right]` reserved extents를 적용한다.

## 진단 및 수동 acceptance

`hypr-window-control-doctor --json`은 title을 노출하지 않고 effective mouse/Snap
bind, border grab area, 플러그인 로드 상태를 검사한다. Electron/Chromium 앱은
버튼별로 다음 결과를 구분한다.

| 관측 결과 | 분류 | 수정 소유자 |
| --- | --- | --- |
| PID 생존, `special:minimized`에 창 존재 | 정상 최소화 또는 상태 복원 문제 | Enoshima state/controller |
| PID 종료, coredump 존재 | client crash | 앱별 Wayland/XWayland flag 또는 upstream |
| PID 정상 종료, coredump 없음 | 앱 close 동작 | client titlebar/upstream |
| 창은 존재하나 입력 불가 | focus/backend 문제 | Hyprland rule와 backend |

필수 앱마다 내부/외부 화면과 tiled/floating 상태에서 최소화·복원·최대화·닫기를
20회 반복한다. coredump, PID, `hyprctl clients -j`, Cyberdock snapshot을 함께
비교하되 보고서에는 title, 문서명, 계정 정보를 남기지 않는다.

## 완료 조건

- allowlist 앱에만 Enoshima titlebar가 있으며 중복 titlebar가 없다.
- 36px visual bar의 caption control은 44px input extent를 가진다.
- 모든 close가 저장 확인 dialog를 보존한다.
- native button과 Dock의 20회 최소화/복원에서 상태 순환이나 창 유실이 없다.
- 내부/외부 출력에서 half, corner, maximize Snap이 clipping 없이 동작한다.
- `scripts/validate.sh`와 실기기 acceptance를 모두 통과한다.
