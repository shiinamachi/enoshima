# Desktop UX reference and design direction

> 조사 기준일: 2026-07-14
> 대상: Hyprland 0.55 기반 Arch Linux 워크스테이션
> 주요 구성요소: Hyprland, Waybar, Hyprlauncher, Quickshell Cyberdock,
> SwayNC, Hyprlock, Hyprpaper

## 1. 목적과 판단 순서

이 문서는 보라·파랑·마젠타 계열의 미래형 도서관 도시 이미지를 시각적
출발점으로 삼되, 보기에 화려한 rice에 머물지 않고 매일 사용하는
워크스테이션으로서 다음 품질을 만족하기 위한 기준을 정의한다.

- 앱과 창을 찾고 전환하는 과정이 빠르고 예측 가능해야 한다.
- 상태 표시, 앱 실행, 알림, 작업 전환의 역할이 서로 겹치지 않아야 한다.
- Waybar, launcher, dock, SwayNC, lock screen이 하나의 제품처럼 보여야 한다.
- 네온 색상은 의미와 초점을 전달할 때만 사용해야 한다.
- 키보드, 포인터, 터치패드 어느 입력에서도 기능을 발견할 수 있어야 한다.
- 애니메이션·투명도·색상에 민감한 사용자를 위한 대체 경로가 있어야 한다.
- Hyprland 플러그인은 명확한 UX 이득이 있고 안정성 비용을 감수할 가치가
  있을 때만 사용해야 한다.

설계 판단에는 다음 우선순위를 적용한다.

1. Windows와 macOS의 공식 UX 지침
2. 현재 Hyprland 공식 문서와 ABI·보안 제약
3. 이 저장소의 Ansible·chezmoi 구조와 유지보수 가능성
4. unixporn 및 공개 dotfiles의 시각적·기능적 아이디어

커뮤니티 사례는 영감의 원천이지 설치 지침이나 안전성의 근거가 아니다.

## 2. Windows에서 가져온 원칙

### 2.1 Fluent 2와 Windows 11

Microsoft Fluent 2는 다음 네 가지 원칙을 제시한다.

- **Natural on every platform**: 이미 익숙한 플랫폼 관습을 활용하고 장치와
  화면에 맞게 적응한다.
- **Built for focus**: 시각적 소음과 방해를 줄여 사용자가 작업 흐름을
  유지하도록 한다.
- **One for all, all for one**: 능력과 입력 방식이 서로 다른 사람을 처음부터
  고려한다.
- **Unmistakably Microsoft**: 색, 형태, 아이콘과 같은 반복되는 특징을 통해
  제품군 전체의 정체성을 만든다.

출처: [Fluent 2 design principles](https://fluent2.microsoft.design/design-principles)

Windows 11의 별도 설계 원칙은 **Effortless, Calm, Personal, Familiar,
Complete + Coherent**이다. 이 환경에서는 이를 각각 다음처럼 번역한다.

- Effortless: 자주 쓰는 기능은 한 번의 단축키 또는 클릭으로 접근한다.
- Calm: 항상 보이는 영역은 작고 안정적으로 유지한다.
- Personal: 작업공간 이름과 dock 즐겨찾기는 실제 사용 목적을 반영한다.
- Familiar: `Alt+Tab`, 검색 중심 launcher, task-view형 overview 등 기존
  데스크톱 습관을 존중한다.
- Complete + Coherent: 같은 의미는 모든 셸 구성요소에서 같은 색, 아이콘,
  간격, 상태 표현을 사용한다.

출처: [Windows 11 design principles](https://learn.microsoft.com/en-us/windows/apps/design/design-principles)

### 2.2 재질과 레이어

Windows는 장기 유지되는 바탕과 일시적으로 나타나는 표면을 구분한다.

- Mica와 같은 낮은 대비의 표면은 장기 유지되는 기반 계층에 적합하다.
- Acrylic과 같은 강한 반투명·블러 표면은 메뉴, flyout, launcher처럼
  일시적인 표면에 적합하다.
- 레이어는 장식이 아니라 현재 초점과 정보 계층을 설명해야 한다.

출처: [Windows application best practices](https://learn.microsoft.com/en-us/windows/apps/get-started/best-practices),
[Materials used in Windows apps](https://learn.microsoft.com/en-us/windows/apps/design/signature-experiences/materials)

적용 기준은 다음과 같다.

- Waybar와 dock은 배경이 안정적으로 읽히도록 비교적 불투명하게 유지한다.
- launcher, SwayNC, window chooser처럼 호출 중에만 나타나는 표면에 제한적으로
  블러를 사용한다.
- 블러 뒤의 배경이 텍스트 대비를 깨뜨리면 단색 반투명 표면으로 폴백한다.
- 여러 겹의 glow, shadow, border를 동시에 사용하지 않는다.

### 2.3 간격, 형상, 토큰

Fluent는 4px 기반 간격 체계와 전역 값·의미별 별칭으로 나뉜 design token을
권장한다. 하드코딩된 색과 크기를 구성요소마다 반복하지 않는 것이 핵심이다.

출처: [Fluent design tokens](https://fluent2.microsoft.design/design-tokens),
[Fluent layout](https://fluent2.microsoft.design/layout)

Windows geometry는 top-level container, overlay, control에 서로 다른 radius를
사용하면서도 중첩된 요소가 하나의 규칙처럼 보이게 한다.

출처: [Geometry in Windows](https://learn.microsoft.com/en-sg/windows/apps/design/signature-experiences/geometry)

이 저장소에는 다음 규칙을 적용한다.

- 기본 간격 단위는 4px로 한다.
- 내부 간격은 주로 4, 8, 12, 16, 20, 24px 중에서 선택한다.
- control, panel, pill의 radius를 별도 token으로 정의한다.
- 중첩된 패널의 안쪽 radius가 바깥쪽 radius보다 커지지 않도록 한다.
- 색은 원시 hex가 아니라 `surface`, `text`, `focus`, `selection`,
  `critical` 같은 의미로 참조한다.
- Waybar와 SwayNC CSS, Hyprland Lua, Quickshell QML이 동일한 의미 매핑을
  유지하는지 검증한다.

### 2.4 창과 작업 전환

Windows의 멀티태스킹 모델은 빠른 전환과 전체 조망을 구분한다.

- `Alt+Tab`: 최근 사용한 창을 빠르게 순환한다.
- Task View: 모든 창과 desktop을 공간적으로 조망한다.
- Snap: 화면 가장자리와 정해진 배치 규칙을 사용한다.
- Multiple desktops: 관계없는 진행 중 작업을 분리한다.

출처: [How to multitask in Windows](https://support.microsoft.com/en-us/windows/how-to-multitask-in-windows-b4fa0333-98f8-ef43-e25c-06d4fb1d6960),
[Customize the Windows taskbar](https://support.microsoft.com/en-us/windows/experience/personalization/customize-the-taskbar-in-windows)

적용 기준은 다음과 같다.

- `Alt+Tab`은 현재 작업공간의 창을 빠르게 순환한다. Hyprland 0.55의 native
  `cycle_next`는 MRU switcher가 아니므로 문서와 tooltip에서도 MRU라고
  오표기하지 않는다.
- 별도 overview 동작은 모든 작업공간과 창을 한눈에 보는 기능을 담당한다.
- overview를 launcher나 dock의 또 다른 변형으로 만들지 않는다.
- tiling은 Hyprland의 native layout과 방향키 이동을 기본 경로로 유지한다.
- 1–5 작업공간은 수량보다 목적을 강조하며, Waybar에는 실제 사용하는 공간만
  표시한다.

## 3. macOS에서 가져온 원칙

Apple의 현재 HIG는 다음 세 가지를 전면에 둔다.

- **Hierarchy**: control과 content의 우선순위가 명확해야 한다.
- **Harmony**: 하드웨어, 시스템 표면과 내부 요소의 형상·리듬이 조화를 이뤄야
  한다.
- **Consistency**: 창 크기와 화면이 바뀌어도 플랫폼 관습과 동작이 유지되어야
  한다.

출처: [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)

이 문서에서는 이를 목적성, 익숙함, 유연성, 단순함, 세공, 즐거움이라는 여섯
가지 실무 판단 기준으로 풀어 사용한다. 이 여섯 단어는 Apple의 공식 원칙
이름을 인용한 것이 아니라 현재 HIG를 이 환경에 적용하기 위한 해석이다.

### 3.1 메뉴 막대, Dock, Spotlight의 역할 분리

macOS에서 menu bar, Dock, Spotlight, Notification Center는 서로 다른 질문에
답한다.

- menu bar: 현재 맥락과 시스템 상태는 무엇인가?
- Dock: 자주 쓰거나 현재 실행 중인 앱은 무엇인가?
- Spotlight: 지금 찾거나 실행하려는 것은 무엇인가?
- Notification Center: 놓친 이벤트와 조절 가능한 상태는 무엇인가?

이 저장소에서도 같은 역할 분리를 유지한다.

- Waybar: 작업공간, 시간, 연결, 전원, 알림 유무 등 지속적인 전역 맥락
- Cyberdock: 즐겨찾기, 실행 중 앱, 최소화된 창
- Hyprlauncher: 앱·설정·명령 검색과 실행
- SwayNC: 알림 기록, 방해 금지, 빠른 제어
- Hyprlock: 인증과 보안 상태만 표시

한 기능을 여러 표면에 반복 배치하면 기능이 풍부해 보이는 대신 어디를
사용해야 하는지 판단하는 비용이 커진다.

### 3.2 Mission Control과 Spaces

macOS는 빠른 앱 전환, 앱별 창 보기, 전체 창 조망, Spaces 전환을 서로 다른
동작으로 제공한다.

출처: [See all your open windows on Mac](https://support.apple.com/guide/mac-help/see-all-your-open-windows-on-mac-mchlb7beb9af/mac),
[Work in multiple Spaces](https://support.apple.com/en-ie/guide/mac-help/mh14112/mac),
[Manage windows on your Mac](https://support.apple.com/guide/mac-studio/manage-windows-on-your-mac-apd2345fc25d/2025/mac/26)

적용 기준은 다음과 같다.

- 한 작업공간 안의 빠른 창 전환과 전체 작업공간 overview를 구분한다.
- 작업공간은 1–5의 고정 번호와 목적별 label을 함께 사용한다.
- 예비 공간 6–10을 상시 노출하지 않는다. 빈 선택지는 기능이 아니라 탐색
  부담이다.
- 터치패드 또는 `Super+Ctrl+Left/Right`로 인접 작업공간을 이동할 수 있게
  한다.
- 실행 중 앱의 여러 창은 dock에서 별도 chooser로 구분할 수 있어야 한다.

### 3.3 Spotlight형 검색

검색은 셸 전체에서 하나의 일관된 진입점을 가져야 한다.

출처: [Apple HIG: Searching](https://developer.apple.com/design/human-interface-guidelines/searching),
[Search with Spotlight](https://support.apple.com/en-ie/guide/mac-help/-mchlp1008/mac)

적용 기준은 다음과 같다.

- `Super+Space`를 primary launcher로 사용한다.
- 열리는 즉시 입력 focus가 검색창에 있어야 한다.
- 결과는 앱, 설정, 작업 등의 의미 그룹으로 구분한다.
- 첫 번째 결과가 명확히 focus되고 Enter로 실행된다.
- Escape는 언제나 취소한다.
- 검색어가 없을 때 지나치게 많은 추천과 장식 요소를 표시하지 않는다.
- launcher가 별도의 full-screen dashboard로 변질되지 않도록 한다.

## 4. 구성요소별 구현 원칙

### 4.1 Waybar

Waybar는 항상 보이는 얇은 맥락 계층이다.

- 좌측: 현재 작업공간과 실제 사용하는 1–5 작업공간
- 중앙: 시간 또는 현재 핵심 맥락
- 우측: 알림, 연결, 오디오, 전원처럼 즉시 확인할 가치가 있는 상태
- WWAN, Bluetooth, backlight처럼 상황에 따라 필요한 상태는 connectivity
  또는 hardware drawer로 묶는다.
- 클릭, 우클릭, 스크롤 동작이 있으면 tooltip에 드러낸다.
- 상호작용 영역은 최소 40×40px 수준을 확보한다.
- 작은 아이콘만으로 critical 상태를 전달하지 않는다.
- 정상 상태의 모든 모듈에 네온 glow를 주지 않는다.

Windows는 일반적인 터치 목표로 약 40×40px을 제시한다. 데스크톱 바도 포인터
오조작과 고해상도 화면을 고려해 이 기준을 하한으로 사용한다.

출처: [Windows targeting guidance](https://learn.microsoft.com/en-us/windows/apps/develop/input/guidelines-for-targeting)

### 4.2 Cyberdock

Dock은 앱의 위치 기억과 실행 상태를 지원한다.

- pointer hotspot만 극단적으로 작게 만들지 않는다.
- dock이 숨겨져 있어도 접근 위치를 예측할 수 있어야 한다.
- 즐겨찾기와 실행 중 상태는 형태 또는 marker로 구분한다.
- focus, running, urgent 상태가 색 하나에만 의존하지 않게 한다.
- 단일 클릭, 우클릭, scroll 동작을 tooltip 또는 context menu로 설명한다.
- 키보드만으로도 dock을 열고 항목을 이동·실행할 수 있는 경로를 제공한다.
- 같은 앱의 여러 창은 chooser에서 제목과 현재 작업공간을 구분해 표시한다.

### 4.3 Hyprlauncher

- 입력창, 결과 목록, 보조 설명의 세 단계 hierarchy를 유지한다.
- 선택된 행은 violet selection surface와 cyan focus edge처럼 중복된 단서로
  표시한다.
- 아이콘 크기와 텍스트 baseline을 정렬한다.
- 배경은 dim 처리하되 wallpaper를 판독 방해 수준으로 투과시키지 않는다.
- 실행 실패는 기술 오류만 노출하지 말고 사용자가 취할 수 있는 다음 행동을
  함께 표시한다.

### 4.4 SwayNC

알림은 사용자를 멈추게 하는 장식이 아니라 시간을 절약하는 정보여야 한다.
Microsoft는 알림의 목적이 명확하고, 가치가 있으며, 과도하게 시끄럽지 않고,
사용자의 의도에 맞는 행동을 제공해야 한다고 설명한다.

출처: [Windows notification UX guidance](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/app-notifications-ux-guidance),
[Apple HIG: Managing notifications](https://developer.apple.com/design/human-interface-guidelines/managing-notifications)

적용 기준은 다음과 같다.

- 일반 알림은 읽을 충분한 시간이 지난 뒤 사라지고 기록에는 남는다.
- critical 알림은 사용자가 확인하기 전까지 유지한다.
- 동일 앱의 반복 이벤트는 가능한 경우 묶는다.
- DND는 panel header에서 즉시 확인하고 토글할 수 있게 한다.
- 알림 전체 지우기는 개별 알림 닫기와 시각적으로 구분한다.
- 가능한 알림은 본문을 열지 않고 수행할 수 있는 짧은 action을 제공한다.
- critical은 마젠타/빨강뿐 아니라 icon, label, border로 중복 표현한다.
- panel과 toast는 같은 카드, radius, typography, severity token을 사용한다.

### 4.5 Hyprlock

- wallpaper가 주인공이되 시간, 날짜, 인증 필드는 즉시 읽혀야 한다.
- 인증 필드는 화면의 안정적인 위치에 둔다.
- 실패·Caps Lock·layout 상태는 색 외의 텍스트 또는 아이콘으로도 전달한다.
- power와 accessibility 동작은 인증 입력과 충분히 떨어뜨린다.
- lock screen에는 workspace, media visualizer, 시스템 telemetry 같은 비필수
  정보를 추가하지 않는다.

## 5. 시각 시스템

첨부 이미지에서 추출한 방향은 **neon library at night**이며, 다음 의미 체계를
사용한다.

| 역할 | 제안 색 | 용도 |
| --- | --- | --- |
| canvas | `#050623` | wallpaper 위의 가장 어두운 기반 |
| surface | `#0a0c3e` | bar, dock, 기본 panel |
| raised surface | `#161151` | 선택 카드, flyout, notification |
| focus / info | `#62d8ff` | keyboard focus, 링크, 진행 상태 |
| selection | `#9a5cff` | 선택된 workspace와 행 |
| expressive accent | `#e56bff` | 제한적인 강조 |
| primary text | `#f2ecff` | 본문과 중요 label |
| success | `#77e0c6` | 완료·연결 |
| warning | `#ffb86b` | 주의 |
| critical | `#ff5d8f` | 오류·긴급 |

적용 규칙은 다음과 같다.

- cyan은 focus와 정보, violet은 selection, magenta는 강한 강조 또는 critical
  인접 상태로 역할을 분리한다.
- 같은 의미에 구성요소마다 다른 accent를 쓰지 않는다.
- wallpaper에 이미 네온이 많으므로 셸 표면의 대부분은 저채도 navy로
  유지한다.
- 텍스트 본문에 순수 magenta를 남용하지 않는다.
- 기본 글꼴, 숫자 글꼴, monospace 사용 범위를 명시한다.
- label은 일반 문장형을 기본으로 하고 cyberpunk식 대문자·구분자는 짧은
  section label에만 쓴다.
- 분위기를 위한 표현이 핵심 기능 이해를 늦추면 평범하고 짧은 기능 label을
  우선한다.

## 6. 모션과 접근성

Windows는 모션이 입력에 반응하고 공간 관계를 설명해야 한다고 본다. Apple도
Reduce Motion과 Reduce Transparency 같은 시스템 수준의 대안을 제공한다.

출처: [Motion in Windows](https://learn.microsoft.com/en-us/windows/apps/design/signature-experiences/motion),
[Apple HIG: Motion](https://developer.apple.com/design/human-interface-guidelines/motion),
[Customize on-screen motion on Mac](https://support.apple.com/guide/mac-help/customize-onscreen-motion-mchlc03f57a1/mac)

적용 기준은 다음과 같다.

- 일반 surface 전환은 대체로 140–220ms 범위의 짧은 easing을 사용한다.
- 움직임은 panel이 어디서 왔고 어디로 사라지는지 설명해야 한다.
- 배터리 부족, 알림, focus에 무한 pulse·flicker를 사용하지 않는다.
- motion을 끄더라도 상태 변화가 border, icon, text로 남아야 한다.
- reduced-motion profile에서는 workspace, window, panel 애니메이션과 focus
  플러그인을 끈다.
- reduced-transparency profile에서는 blur를 끄고 surface alpha를 높인다.
- 확대 또는 fractional scaling에서 텍스트가 잘리거나 hit target이 줄지
  않는지 확인한다.
- 모든 주요 셸 기능은 키보드만으로 실행할 수 있어야 한다.
- focus outline을 제거하지 않는다.
- hover에만 의존하는 기능은 금지한다.
- 색각 차이를 고려해 상태에 icon·text·shape를 함께 사용한다.

키보드 접근성은 power-user 기능이면서 보조기술 접근성의 기반이다.

출처: [Windows keyboard interactions](https://learn.microsoft.com/en-us/windows/apps/develop/input/keyboard-interactions),
[Apple HIG: Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards),
[Windows accessibility overview](https://learn.microsoft.com/en-us/windows/apps/design/accessibility/accessibility-overview)

## 7. Hyprland 플러그인 결정

Hyprland 플러그인은 compositor 프로세스 안에서 실행되는 C++ shared object다.
공식 문서는 신뢰할 수 없는 `.so`를 로드하지 말고 소스를 검토하라고 경고한다.
플러그인 충돌은 compositor 전체 안정성에 영향을 줄 수 있다.

출처: [Hyprland plugin guidance](https://wiki.hypr.land/Plugins/Using-Plugins/)

### 7.1 설치 정책

- 공식 지원 경로인 `hyprpm`만 사용한다.
- `hyprpm`의 Hyprland 버전 pinning을 이용한다.
- Hyprland 업데이트 후 plugin ABI 일치 여부를 검증한다.
- plugin 미설치 또는 로드 실패 시 desktop 기본 기능이 사라지지 않아야 한다.
- 임의의 prebuilt `.so`를 저장소에 포함하거나 직접 복사하지 않는다.
- plugin 옵션은 Lua에서 plugin 존재 여부를 확인한 뒤 설정한다.

공식 플러그인 저장소의 2026-07-14 기준 목록은 `borders-plus-plus`,
`csgo-vulkan-fix`, `hyprbars`, `hyprfocus`다.

출처: [hyprland-plugins](https://github.com/hyprwm/hyprland-plugins)

### 7.2 채택: hyprfocus

`hyprfocus`는 키보드로 focus가 바뀔 때 사용자가 새 focus 위치를 놓치지 않도록
돕는 제한적인 용도로 적합하다.

출처: [hyprfocus configuration](https://github.com/hyprwm/hyprland-plugins/tree/main/hyprfocus)

권장 설정 방향은 다음과 같다.

- keyboard focus는 매우 약한 `shrink` 또는 짧은 `flash`
- mouse focus animation은 `none`
- floating window animation은 기본적으로 끔
- shrink 비율은 1에 가깝게 설정
- reduced-motion profile에서는 비활성화

이 효과는 테마 장식이 아니라 focus 접근성을 위한 보조 단서여야 한다.

### 7.3 기본 미채택: hyprbars

`hyprbars`는 모든 창에 title bar를 추가할 수 있지만 GTK·Qt·Electron 앱의
client-side decoration과 중복될 수 있다. 전역 적용은 창마다 서로 다른 이중
title bar와 control 위치를 만들 가능성이 높다.

출처: [hyprbars configuration](https://github.com/hyprwm/hyprland-plugins/tree/main/hyprbars)

따라서 stale `hyprbars` enable 상태를 제거하고 전역 사용하지 않는다. 장차
server-side decoration이 전혀 없는 특정 앱에 필요해질 경우에만 명시적인
window rule로 제한해 재평가한다.

### 7.4 미채택: borders-plus-plus

추가 border는 native active border와 역할이 중복된다. 여러 네온 테두리는
focus hierarchy를 강화하기보다 content 주변의 시각적 소음을 늘린다. 기본
2px 수준의 active border와 단일 glow만 유지한다.

### 7.5 보류: hyprexpo

`hyprexpo`는 공식 플러그인 저장소에서 retired되었고 현재는 별도 third-party
fork로 유지된다.

출처: [sandwichfarm/hyprexpo](https://github.com/sandwichfarm/hyprexpo)

overview 자체는 Windows Task View와 macOS Mission Control에 대응하는 유용한
기능이지만 third-party compositor plugin을 기본 desktop 경로로 넣는 비용이
크다. 현재는 Quickshell 또는 native Hyprland IPC 기반 overview를 우선한다.
이후 다음 조건을 만족할 때만 재검토한다.

- 소스 검토 완료
- 현재 Hyprland 0.55 ABI용 pinned build
- nested session에서 crash·multi-monitor·keyboard navigation 검증
- plugin이 없어도 `Alt+Tab`, workspace 이동, launcher가 정상 작동
- 제거가 한 커밋으로 되돌릴 수 있음

Hyprland 0.55는 Lua configuration, user-defined layout, 개선된 native
scrolling을 제공하므로 과거 layout plugin을 그대로 도입할 필요도 줄었다.

출처: [Hyprland 0.55 release](https://hypr.land/news/update55/)

## 8. 커뮤니티 레퍼런스

### 8.1 HyprPunk

[HyprPunk](https://github.com/tuconnaisyouknow/HyprPunk)와
[unixporn 게시물](https://www.reddit.com/r/unixporn/comments/1u86zj7/oc_hyprland_hyprpunk_neon_rain_mauve_borders/)은
이 프로젝트와 가장 가까운 cyberpunk·mauve 방향이다.

가져올 점은 다음과 같다.

- wallpaper, Waybar, launcher, SwayNC, lock screen, GTK/Qt를 하나의 palette로
  연결한다.
- 어두운 표면과 제한된 mauve accent를 사용한다.
- 시각적 테마보다 일상 가독성을 우선한다.

주의할 점은 다음과 같다.

- 게시물 피드백에서도 launcher 배경이 전체 테마와 다르다는 지적이 나왔다.
- 공유 token과 자동 검증이 없으면 작은 불일치가 전체 완성도를 깨뜨린다.
- fresh-install용 원격 install script를 이 저장소에 복사하지 않는다.

### 8.2 Wallpaper-derived palette 사례

[Clean looks so crisp](https://www.reddit.com/r/unixporn/comments/1rshhbi/hyprland_clean_looks_so_crisp/)
사례는 wallust를 통해 Waybar, launcher, terminal, editor, SwayNC, file manager를
같은 wallpaper palette로 연결한다.

가져올 점은 한 palette가 모든 surface에 전파될 때 강한 통일성이 생기고,
terminal과 shell까지 desktop shell과 같은 색 역할을 공유할 수 있다는 것이다.
이 저장소에서는 wallpaper가 주 컨셉으로 고정되어 있으므로 매번 색을
재추출하기보다 검토된 semantic token을 고정하고 테스트하는 방식이 더
예측 가능하다.

### 8.3 Quickshell 기반 셸

- [end-4/dots-hyprland](https://github.com/end-4/dots-hyprland):
  usability-first 접근
- [Caelestia Shell](https://github.com/caelestia-dots/shell): 유동적인 QML shell과
  일관된 전환
- [Noctalia](https://github.com/noctalia-dev/noctalia): bar, launcher,
  notification, dock, lock screen을 하나의 shell로 묶어 구성 불일치를 줄이는
  구조

가져올 점은 다음과 같다.

- 구성요소별로 독립된 설정 파일이 있더라도 공유 token과 component 규칙은
  하나여야 한다.
- Quickshell은 dock, chooser, overview처럼 shell 전용 상호작용을 구현하기에
  적합하다.
- 상태와 전환 모델을 중앙화하면 중복 daemon과 불일치가 줄어든다.

가져오지 않을 점은 다음과 같다.

- 현재 Waybar·SwayNC·Hyprlauncher 스택 전체를 새 shell로 교체하는 대규모 전환
- beta shell에 desktop 기본 기능을 한 번에 의존시키는 것
- 항상 움직이는 morphing 효과를 테마의 핵심으로 삼는 것

### 8.4 대형 Hyprland 배포형 dotfiles

- [HyDE](https://github.com/HyDE-Project/HyDE)
- [ML4W dotfiles](https://github.com/mylinuxforwork/dotfiles)
- [JaKooLit Hyprland-Dots](https://github.com/JaKooLit/Hyprland-Dots)
- [awesome-hyprland](https://github.com/hyprland-community/awesome-hyprland)

가져올 점은 laptop/desktop 차이, theme 전파, notification·lock·launcher까지
포함한 범위, 사용자 설정 UI와 post-install 검증, 여러 모니터와 hardware
state에 대한 방어적 구성이다.

다음은 가져오지 않는다.

- monolithic installer
- 사용자 파일을 광범위하게 덮어쓰는 설치 방식
- 현재 Ansible·chezmoi 경계를 우회하는 package 또는 system 설정
- awesome list에 있다는 이유만으로 plugin을 신뢰하는 것

### 8.5 추가 시각 사례

[My Cyberpunk Themed Hyprland](https://www.reddit.com/r/unixporn/comments/1jlhja3/hyprland_my_cyberpunk_themed_hyprland_didnt_do/)
같은 사례는 네온 배경과 shell surface의 조합을 비교하는 시각 자료로만
사용한다. 정지 화면에서 인상적인 scanline, glitch, flicker는 장시간 작업에서
피로와 가독성 저하를 일으킬 수 있으므로 실제 구현 기준으로 복사하지 않는다.

## 9. 금지할 안티패턴

- 사용하지 않는 workspace 6–10을 혹시 모른다는 이유로 항상 표시하는 것
- 모든 surface에 투명도, blur, glow를 동시에 적용하는 것
- 정상 상태에서도 끊임없이 pulse하거나 flicker하는 요소
- battery critical 상태를 빨간색 하나로만 표현하는 것
- Waybar, dock, launcher가 모두 앱 실행과 창 전환을 중복 제공하는 것
- 3px hotspot, 작은 icon 등 pointer로 찾기 어려운 목표
- hover나 우클릭으로만 발견할 수 있는 핵심 기능
- 앱 자체 title bar 위에 전역 hyprbars를 중복 표시하는 것
- 구성요소마다 서로 다른 navy, violet, radius, shadow를 하드코딩하는 것
- concept image의 네온 밀도를 UI control까지 그대로 복사하는 것
- 커뮤니티 install script를 검토 없이 실행하는 것
- third-party plugin failure가 session 시작을 막는 구성

## 10. 저장소 적용 매핑

| UX 결정 | 저장소 영역 |
| --- | --- |
| 1–5 목적형 workspace | `home/dot_config/hypr/hyprland.lua`, Waybar workspace 설정 |
| 공통 palette와 semantic token | Waybar/SwayNC CSS, Hyprland Lua, Quickshell QML |
| 상태 bar 단순화와 drawer | Waybar config/style |
| Spotlight형 검색 | Hyprlauncher config/style |
| 즐겨찾기·실행 상태·multi-window chooser | Quickshell Cyberdock |
| 알림 가치·DND·critical 표현 | SwayNC config/style |
| wallpaper 중심의 안전한 인증 UI | Hyprlock/Hyprpaper |
| subtle keyboard focus cue | 선택적 `hyprfocus` 관리 |
| stale title-bar plugin 제거 | `hyprpm` convergence 및 postflight |
| reduced motion/transparency | desktop appearance helper와 문서 |
| 회귀 방지 | `scripts/validate.sh`, `scripts/postflight.sh`, 관련 tests |

## 11. 수용 기준

- Waybar와 Hyprland 어디에도 6–10 workspace의 상시 label·binding·route가 남지
  않는다.
- persistent control의 클릭 영역은 최소 약 40px을 목표로 한다.
- 주요 기능은 키보드만으로 접근 가능하다.
- focus는 색, edge 또는 motion 중 최소 두 가지 단서로 구분되며 motion을 꺼도
  남는다.
- 일반·warning·critical 상태는 색 외 icon 또는 text를 포함한다.
- Waybar, launcher, dock, SwayNC, lock screen이 동일한 semantic palette를
  사용한다.
- 상시 반복되는 pulse·flicker 애니메이션이 없다.
- blur는 주로 transient overlay에 제한된다.
- `hyprfocus`가 로드되지 않아도 session과 기본 focus 이동이 정상이다.
- stale `hyprbars`는 비활성화된다.
- 100%, fractional scaling, multi-monitor에서 panel clipping과 hit target을
  확인한다.
- concept art와 실제 구현을 나란히 검토하되 가독성과 조작성이 시각적
  일치보다 우선한다.
