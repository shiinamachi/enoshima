# Prompt template

Use the following structure for each candidate and final board.

```text
Create a high-fidelity desktop UI concept board for the Enoshima Linux desktop.

Purpose: <surface and user task>
Frame: 1920x1080 logical desktop, <full desktop or focused crop>
Style references: <workspace paths>; use only as visual-language references, not edit targets.

Required composition:
- <placement and hierarchy>
- <controls and exact labels>
- <default and alternate states>
- <pointer/focus targets>

Enoshima contract:
- deep navy #050623 canvas, #0a0c3e and #161151 surfaces
- cyan #62d8ff focus, violet #9a5cff selection, sparse magenta #e56bff accent
- #f2ecff primary text, #c9bfe8 secondary text
- Pretendard-like Korean typography, Papirus-style symbolic icons
- 14px panels, 12px controls, calm workstation density, restrained glow

Accessibility and behavior:
- 44px preferred targets; visible keyboard focus
- Korean primary copy plus English overflow sample where useful
- reduced-transparency and reduced-motion notes
- no mobile UI, web dashboard, glassmorphism, emoji controls, remote fonts, or fake code

Output: <candidate board with three labeled directions OR selected final board with redlines and state strip>.
```

For a final board, name all interaction states with short, real labels. Keep annotations outside the production UI frame so they cannot be mistaken for implemented copy.
