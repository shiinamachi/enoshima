# Enoshima Greeter instructions

- Follow the root design and concept-first contract for the `auth` surface.
- Preserve greetd/PAM protocol, seat handoff, password handling, keyring unlock,
  failure behavior, and the boundary between deterministic visual fixtures and
  real authentication.
- Never add production autologin, persist test credentials, bypass PAM, or
  weaken the real login path to simplify screenshots.
- Read the auth concept and theme/layout contracts with the implementation and
  tests. Validate English/Korean states, required scales, keyboard focus,
  failure recovery, and secret-free logs.
- Run the selector-provided focused tests plus fresh affected login and UI
  review checkpoints. Physical fingerprint enrollment and device behavior
  remain T5 gates.
