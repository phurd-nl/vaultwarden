# 6. NextVault rebrand (scope, palette, identifier policy)

Date: 2026-06-09

## Status

Accepted (in progress — see slices)

## Context

The deployment is branded **NextVault** at `nextvault.nxlink.com`. "Fully
rebrand" spans surfaces with very different cost/risk:

- Server-controlled operator surfaces (admin pages, emails, error pages).
- The end-user **web vault** UI, which is a *separate* component (the
  `vaultwarden/web-vault` image — the Bitwarden web client), not in this repo.
- The installed **Bitwarden clients** (browser/desktop/mobile), which are
  Bitwarden-branded, store-distributed, and not forkable in practice.
- **Internal identifiers**: crate/binary name, the `vaultwarden::audit` log
  target (the Wazuh decoders key on it), container/network/volume names, image
  names, HTTP user-agent.

A blanket find/replace is unsafe: renaming the crate cascades to the binary path
(`/vaultwarden`), the upstream Dockerfile build, and the `<bin> hash` command;
renaming the audit target silently breaks the SIEM decoders (ADR-0005/wazuh).

## Decision

- **Scope:** rebrand operator surfaces **and** build a branded web vault; accept
  that installed clients stay Bitwarden-branded.
- **Palette — "Navy + Aqua":** primary navy `#112F45`, accent aqua `#4D9CB9`,
  link hover `#6FB4CE`, success `#3E8D61`, error `#D84836`, warning `#F4BA41`,
  text `#303030`, muted `#595959`, border `#D0D0CE`, background `#F7F7F7`.
  Derived from the Nextlink 2026 brand book but deliberately *not* a clone
  (aqua accent instead of Nextlink's gold-forward identity).
- **Identifier policy:** rename internal identifiers to `nextvault` **except**
  the crate/binary name, which stays `vaultwarden` — keeping it avoids editing
  the upstream build and minimizes the upstream-merge surface (ADR-0001), for no
  user-visible benefit.
- **Styling is additive:** the theme lives in the existing
  `scss/user.vaultwarden.scss` override partial as Bootstrap `--bs-*` variable
  overrides (the admin UI is Bootstrap, same as `NextPass/brand/custom.css`),
  not by forking upstream SCSS.

## Slices

1. Operator-surface text (admin + email + 404 templates) → "NextVault". Kept:
   the `vaultwarden hash` command, css class `vaultwarden-icon`, asset filenames
   `vaultwarden-*.png` (until the asset swap), the `scss/vaultwarden.scss`
   include, and admin-only **upstream** doc/forum links (no NextVault equivalent;
   repointing the text would mislead). Email footer source links repointed to the
   fork (also satisfies the AGPL source-offer).
2. Visual theme (Navy + Aqua) via the additive SCSS partial. Logo/favicon asset
   swap deferred until NextVault assets exist.
3. Internal identifier rename (NOT crate/binary): `vaultwarden::audit` →
   `nextvault::audit` **in lockstep with the Wazuh decoders/rules**; user-agent;
   container/network/volume/image names + all cross-references.
4. Branded web vault: patch/build a custom web-vault (name, logo, favicon,
   colors, page title), serve it, pin the digest. Ongoing upstream-tracking cost.

## Consequences

- Slices 1–2 are additive and low-risk; slice 3 is mechanical but must keep the
  audit target and the Wazuh decoders in sync or the SIEM silently stops parsing.
- AGPLv3 source-availability obligation persists after rebranding; the email
  footer and 404 "contact us" links now point to the published fork.
- The end-user browser/desktop/mobile clients will still display Bitwarden
  branding; only the web vault and server surfaces become NextVault.
