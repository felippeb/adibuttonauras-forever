# CurseForge listing copy

Paste-ready text for the project page. **Summary** goes in the short description field;
**Description** goes in the Description tab (its editor has a source/HTML view if the
markdown does not survive a plain paste).

## Summary

> Green borders and live timers on a paladin's seals, blessings and auras — and nothing at all when the client cannot prove the buff is there.

## Description

### What it does

While a buff this addon tracks is active, its action button gets a green border and the
time remaining. When the buff is not there, the button stays neutral. It does not nag you
about missing buffs, and it never shows a timer it cannot justify.

Tracked for paladins on Forever:

- **Seals** — Light, Wisdom, Fury, Justice, Command, Righteousness, the Crusader, all ranks
- **Blessings** — Might, Wisdom, Kings, Protection, Freedom
- **Auras** — Devotion, Retribution, Concentration, the resistance auras
- **Self-buffs** — Righteous Fury

Seals are matched by family, so custom spell ids and unusual ranks still work, and swapping
Fury to Light drops Fury immediately instead of leaving both lit. Buffs cast on you by other
players count too — the other paladin's Blessing of Wisdom lights your button.

### Built for WoW Forever (1.60.1, interface 16001)

This is a port of AdiButtonAuras 11.0.4 to the Forever client, which hands addons much less
aura data than retail does. In combat it hides other units and can return aura fields as
opaque "secret" values, and it reports hidden auras as an empty list rather than an error.
A retail addon reads that as "no auras" and wipes its display.

This version treats an unreadable answer as *unknown*: it keeps the last good state, merges
while the client is blind, and lets the client be authoritative again as soon as it can be
read. Your own casts are remembered only while the client hides the truth.

### What it deliberately does not do

- **No Judgement or Consecration timers.** Enemy auras are unreadable by addons in combat on
  this client, so a timer would be a guess. Those buttons stay neutral.
- **No "missing buff" reminders** by default.
- **No proc flash.** The client does not ship the retail spell-activation overlay textures.

### Install

1. Extract so that `Interface\AddOns\AdiButtonAuras\` and
   `Interface\AddOns\AdiButtonAuras_Config\` exist side by side.
2. Restart the client — new addon folders are only read at startup.
3. Configure with `/aba`. Editing a `.lua` file only needs `/reload`.

### Diagnostics

`/abaforever` prints the build, which APIs the client exposes, the cache state, live auras
per unit, remembered casts, per-button rule state and the spellbook. Every line is also
written to `ABAForeverProbe` in SavedVariables, so a bug report does not need a screenshot.

### Source and license

Modified version of **AdiButtonAuras 11.0.4** by the AdiAddons authors.
Licensed **GPL-3.0**; full source, change notice and history:

https://github.com/felippeb/adibuttonauras-forever

Not affiliated with or endorsed by the original authors, Blizzard Entertainment or CurseForge.

## Suggested project settings

- **Category:** Buffs & Debuffs (secondary: Action Bars)
- **License:** GNU General Public License v3.0
- **Game version:** WoW Forever — 1.60.1
- **Avatar:** `docs/assets/logo-400.png`
- **Summary:** the line above
