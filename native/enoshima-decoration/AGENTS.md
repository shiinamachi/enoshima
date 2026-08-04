# Native window-decoration instructions

- Follow the root design contract for every visible titlebar, menu, snap, focus,
  or window-action change. The primary surfaces are `system-titlebar`,
  `cyberdock-window-state`, and `snap-assist` in `docs/ui-surfaces.yaml`.
- Preserve the capability-based client/server decoration boundary. Do not add
  application-name or class allowlists as a substitute for protocol behavior.
- Keep titlebar rendering, compositor ownership, window-action transport, and
  Quickshell menu responsibilities explicit; read `docs/WINDOW-DECORATIONS.md`
  and the window-interaction contract before editing.
- Run the selector-provided focused tests plus the affected fresh desktop and UI
  review checkpoint. Retain real internal/external display interaction as the
  final physical gate.
