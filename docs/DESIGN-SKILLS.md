# Project-local design skills

> 조사 및 고정 기준일: 2026-07-15

이 저장소는 Taste Skill과 UI/UX Pro Max를 전역 Codex 환경이 아닌
`.agents/skills/`에만 포함한다. Codex는 현재 작업 디렉터리에서 저장소 루트까지
이 경로를 검색하므로, 다른 프로젝트에는 두 skill이 노출되지 않는다. 디자인
변경의 자동 적용 조건은 루트 `AGENTS.md`가 정의한다.

## 조사한 원본

| Skill | 검토한 원본 | 고정 commit | 상태 | 라이선스 |
| --- | --- | --- | --- | --- |
| Taste Skill (`design-taste-frontend`) | [Leonxlnx/taste-skill](https://github.com/Leonxlnx/taste-skill/tree/b17742737e796305d829b3ad39eda3add0d79060/skills/taste-skill) | `b17742737e796305d829b3ad39eda3add0d79060` | v2 experimental, tag 없는 `main` snapshot | MIT |
| UI/UX Pro Max | [nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill/tree/f8ac5e1266dba8354ea96e19994d9f4345e7ec31/.claude/skills/ui-ux-pro-max) | `f8ac5e1266dba8354ea96e19994d9f4345e7ec31` | `v2.11.0` 이후 core hardening을 포함한 `main` snapshot | MIT |

정확한 source path, Git tree, 원본 `SKILL.md` SHA-256, 로컬화 설명은
`.agents/skills/sources.json`에 기록한다. 각 skill 폴더에는 upstream MIT
license notice를 함께 둔다. 자동 updater는 두지 않는다.

## Taste Skill 평가

원본은 1,206줄의 instruction-only skill이다. 실행 스크립트나 런타임
의존성은 없으며 다음 흐름을 강하게 규정한다.

- brief, audience, brand, reference와 접근성 제약을 먼저 읽는 design read;
- design variance, motion intensity, visual density 세 dial;
- 기존 프로젝트에서 brand, information architecture, content, 접근성,
  analytics를 먼저 감사하는 preserve/overhaul redesign 구분;
- semantic token, 계층, 반복 레이아웃, 상태, motion, reduced-motion,
  performance와 최종 pre-flight 검토;
- 가짜 product UI, 기능 없는 mock, 근거 없는 수치, 과잉 glow와 템플릿형
  구성을 피하는 anti-pattern 목록.

그러나 원본의 주 대상은 landing page, portfolio, website redesign이다.
React/Next.js, Tailwind, Motion, GSAP, web hero/CTA/SEO, image generation과
여러 design-system package를 기본 전제로 삼는다. dashboard, data table,
multi-step product UI와 native UI는 명시적 비대상이다. 또한 단일 accent,
단일 radius, consumer page dual mode, 보라색 억제 같은 일반 규칙은 이
저장소가 이미 승인한 dark-first Cyberpunk Library semantic palette와
control/panel/pill radius 역할에 맞지 않는다.

따라서 활성 `SKILL.md`는 desktop adapter로 유지하고, 검토한 원문은
`references/taste-skill-v2.md`에 보존한다. 기존 surface 감사, hierarchy,
consistency, accessibility, purposeful motion과 anti-slop review만 문맥에 맞게
가져오며 web stack과 package 권고는 실제 web 작업이 아닌 한 비활성화한다.

## UI/UX Pro Max 평가

upstream CLI는 Codex 대상을 `.codex/skills/`에 설치하지만, 현재
[Codex skill 문서](https://learn.chatgpt.com/docs/build-skills.md)는 저장소 범위를
`.agents/skills/`로 정의한다. CLI는 core 외에도 banner, brand, design-system,
slides 등 요청하지 않은 sibling skill 여섯 개를 설치한다. 이 저장소에서는
CLI와 Node/npm 공급망을 실행하지 않고, 검토한 core 43파일만 고정했다.

고정한 core에는 다음 로컬 자료가 들어 있다.

- 84 styles, 192 color palettes, 74 font pairings, 192 product types;
- 99 UX guidelines, 105 icon entries, 16 motion presets, 25 chart types;
- 1,923 Google Fonts records와 22개 구현 stack CSV;
- `core.py`, `search.py`, `design_system.py`, `validate_data.py`와 16개 unit
  tests;
- accessibility, interaction, performance, style, layout, typography,
  animation, forms, navigation, chart reference.

runtime은 Python standard library만 사용한다. 일반 검색은 local CSV만 읽고
network, subprocess, `eval`, package install을 사용하지 않는다. 파일 쓰기는
`--persist` 경로에서만 발생한다. 고정 commit은 2026-07-10의 persist path
sanitization과 이후 search/data hardening을 포함한다. 자세한 upstream 보안
범위는 [SECURITY.md](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill/blob/f8ac5e1266dba8354ea96e19994d9f4345e7ec31/SECURITY.md)를 따른다.

Hyprland, QML, GTK, Waybar, SwayNC와 SDDM은 지원 stack 목록에 없다. 따라서
`html-tailwind`로 대체하지 않고 `ux`, `style`, `color`, `typography`, `icons`,
`web` domain을 조사·검증 보조로만 사용한다. 검색 결과의 palette나 font를
자동 적용하지 않으며 GSAP 예제를 QML/Hyprland에 직역하지 않는다. 기존 design
문서가 이미 master이므로 `--persist`, `--force`와 별도 `design-system/` tree도
금지한다.

## 적용 범위와 우선순위

두 skill은 항상 함께 사용한다.

| 적용 | 적용하지 않음 |
| --- | --- |
| QML shell, Waybar, SwayNC, GTK CSS, Hyprlock, SDDM, Hyprland의 사용자 표시·상호작용 | package manifest, service, network, inventory |
| 색, type, spacing, hierarchy, layout, icon, motion, focus, navigation | 시각 영향이 없는 shell/Python/Ansible 로직 |
| concept asset과 visual design 문서 | 일반 운영 문구와 비디자인 문서 정리 |
| 접근성, reduced motion/transparency, scaling과 상태 표현 | 기존 디자인 결정을 바꾸지 않는 순수 기능 수정 |

판단 우선순위는 다음과 같다.

1. 현재 요청의 명시적 사용자 결정;
2. `AGENTS.md`, `docs/DESKTOP-UI-CONCEPT.md`,
   `docs/DESKTOP-UX-REFERENCES.md`와 더 구체적인 저장소 문서;
3. 현재 구현, semantic token, 테스트와 toolkit 제약;
4. 두 외부 skill의 문맥에 맞는 권고.

외부 skill은 source of truth가 아니라 critique와 evidence layer다. 충돌하면
상위 저장소 결정을 유지하고, 충돌 이유를 작업 중 명시한다.

## 디자인 작업 순서

1. 영향받는 surface, 구현 파일, 관련 테스트와 design contract를 읽는다.
2. 기존 surface는 별도 승인 전까지 **Redesign - Preserve**로 분류한다.
3. Taste adapter에 따라 한 줄 design read와 세 dial을 정한다.
4. UI/UX Pro Max에서 필요한 domain만 검색한다. 예:

   ```bash
   python3 "$(git rev-parse --show-toplevel)/.agents/skills/ui-ux-pro-max/scripts/search.py" \
     "desktop shell keyboard focus reduced motion contrast" --domain ux
   ```

5. 결과를 기존 palette, type, spacing, motion, 기능과 대조하고 적용 가능한
   원칙만 현재 QML/CSS/Lua 구조로 번역한다.
6. focused test와 `scripts/validate.sh`를 실행한다.
7. 정적 검사가 판단하지 못하는 clipping, contrast, motion, internal/external
   scaling은 문서화된 visual acceptance에서 확인한다.

## 검증과 업데이트

`scripts/validate.sh`는 다음을 검사한다.

- 두 active `SKILL.md`의 frontmatter와 UI metadata;
- exact upstream repository, commit, source hash와 MIT notice 기록;
- 중첩되거나 repository 밖을 가리키는 skill/symlink 부재;
- UI/UX Pro Max local path adapter와 persistence 금지;
- CSV schema/data integrity, 16개 core unit test와 대표 local search.

upstream 변경은 자동으로 가져오지 않는다. 업데이트할 때는 새 commit의 전체
diff, license, security history, prompt 지시, 실행 코드와 dependency 변화를 먼저
검토한다. 임시 디렉터리에서 data validator, unit test와 representative search를
통과시킨 뒤 source commit/hash, adapter와 문서를 함께 바꾸고 독립 Conventional
Commit으로 남긴다.
