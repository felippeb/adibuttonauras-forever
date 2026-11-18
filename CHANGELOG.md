# Changelog

## 11.0.4-forever.2 — 2026-11-18

### Blessings

- Blessings follow the client's **one-blessing-per-paladin-per-target** rule: casting a
  blessing on yourself removes your previous blessing from the player.
- A self-cast drops the replaced blessing immediately, and a restricted (combat) read can
  no longer re-light it; the guard lasts until the replaced copy would have expired.
- The cast target is taken from `UNIT_SPELLCAST_SENT`, so blessing another player never
  darkens or remembers a blessing on you.
- Auras keep `isFromOwnCast`/`sourceUnit` when the client exposes them: a blessing known
  to come from another paladin is never hidden by your own cast.

### Diagnostics

- `/abaforever auras` prints the last blessing cast on the player (id, name, family,
  guard) and `own`/`src` for every live aura, to verify cast attribution.

## 11.0.4-forever.1 — 2026-11-16

First WoW Forever port, based on upstream 11.0.4.

### Platform compatibility

- `Forever.lua` compat shim, loaded before the embedded libraries: spell, aura, cooldown,
  item and addon APIs resolved by feature detection, with legacy fallbacks.
- TOC targets `Interface: 16001`, `X-Flavor: Forever`.
- Library hardening: LibDualSpec season guard, LibSpellbook defensive scan
  (`IsPlayerSpell` → `IsSpellKnown` → `C_SpellBook.IsSpellKnown`), SMBH texture-path
  fallback, DebugTooltip guard, nil-safe core/display code.
- Item API fallbacks: `IsHarmfulItem`, `IsHelpfulItem`, `GetItemSpell`, `GetItemInfo`.

### Aura engine

- Restricted reads **freeze** the cache instead of wiping it — an empty slot list in
  combat means "unknown", not "no auras".
- Full rebuild on `UNIT_AURA`; **merge** while restricted, **replace** when readable.
- `PLAYER_REGEN_ENABLED` refreshes instead of wiping (no "missing" flash after combat).
- Remembered own casts (`UNIT_SPELLCAST_SUCCEEDED`) for auras hidden in combat,
  reconciled as soon as the real aura is readable.
- Active-only display: a frozen entry that has expired no longer holds a green border.
- Secret-safe field reads: a hidden value is never reported as missing.

### Rules

- Forever paladin rules: seals, blessings, auras, Righteous Fury.
- Countdowns up to 60 minutes (`maxCountdown` 600 → 3600, existing profiles migrated).
- All ranks, plus **aura-name matching** for custom ids.
- Buffs cast by other players on the player count as present.
- Judgement does **not** consume the seal on this client (unlike Wrath Classic).
- Seal **families**: swapping Fury → Light drops Fury immediately, even when the
  combat read still reports the old seal.
- Seal casts fall back to the observed 30 s duration when the client hides it.
- Target-debuff rules removed (Judgement, Consecration): enemy auras are unreadable
  in combat, so nothing is shown rather than a guessed timer.

### Diagnostics

- `/abaforever` probes: build/API presence, live auras per unit, cache state,
  remembered casts, last seal, button/overlay state, registered rules, spellbook.
- Probe output mirrored into `ABAForeverProbe` (SavedVariables), flushed on `/reload`.
- Per-handler `pcall` with first-error reporting (one broken rule cannot freeze the UI).
- Lua error handler wrapped so errors reach both chat and the probe buffer.
