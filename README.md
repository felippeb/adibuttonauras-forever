<img src="docs/assets/logo-400.png" width="112" align="right" alt="AdiButtonAuras Forever logo">

# AdiButtonAuras Forever

[![ci](https://github.com/felippeb/adibuttonauras-forever/actions/workflows/ci.yml/badge.svg)](https://github.com/felippeb/adibuttonauras-forever/actions/workflows/ci.yml)

An unofficial port of [AdiButtonAuras](https://github.com/AdiAddons/AdiButtonAuras) 11.0.4 to
**WoW Forever** (interface `16001`, game version `1.60.1`).

While a tracked buff is up, its action button gets a green border and the remaining time. When it
is not up, the button stays neutral. No nagging, no guessed timers.

## Why this exists

My paladin's seals, blessings and auras were invisible on the action bars. Retail AdiButtonAuras
assumed the client hands addon Lua the same aura data the default UI sees. Forever does not: in
combat it hides other units entirely and can return aura fields as *secret* values, while the
enumeration API reports "hidden" as an **empty list** rather than an error. A retail addon reads
that as "no auras" and wipes its cache.

The port is mostly one idea: **unknown is a state, not a value.** A restricted read freezes the
last good snapshot; the client stays authoritative whenever it is readable; our own casts are
remembered only while the client is blind.

## What it tracks

| Group | Examples |
| --- | --- |
| Seals | Light, Wisdom, Fury, Justice, Command, Righteousness, the Crusader — all ranks, including custom 1.3M-range ids |
| Blessings | Might, Wisdom, Kings, Protection, Freedom |
| Auras | Devotion, Retribution, Concentration, resistance auras |
| Self-buffs | Righteous Fury |

- Seals are matched by **family** (id or display name), so custom ids and different ranks still work.
- Buffs cast by **other players** on you light your button too — e.g. the other paladin's Blessing of Wisdom.
- Only the current seal shows: swapping Fury → Light drops Fury immediately, even if the combat read lags.

## What it deliberately does not do

- **No Judgement / Consecration timers.** On Forever, addon Lua cannot read non-player auras in
  combat — not via the slot API, not via the index API. Remembering our own casts would be
  guesswork (seal-dependent debuff ids, target swaps, ground effects). The buttons show nothing
  instead. Doing this properly needs a display-only secure `AuraContainer`, outside the rule engine.
- **No "missing buff" reminders** by default.
- **No proc flash** — the client does not ship `Interface\SpellActivationOverlay\IconAlert`.

## Install

1. Download the latest zip from [Releases](../../releases).
2. Extract it so that `Interface\AddOns\AdiButtonAuras\` and
   `Interface\AddOns\AdiButtonAuras_Config\` exist as siblings.
3. Restart the client — new folders are only read at startup.
4. After editing any `.lua`, `/reload` is enough.

## Diagnostics

```text
/abaforever                  build, API presence, restricted flag, cache state
/abaforever auras [unit]     live slots, cache, remembered casts, last seal, counters
/abaforever buttons [n]      per-slot rule/overlay state, handler errors
/abaforever rules            registered rules, units, events
/abaforever spells           spellbook dump (id + name)
```

Every probe line is also mirrored into `ABAForeverProbe` (SavedVariables) and flushes to disk on
`/reload`, so a bug report never needs a screenshot.

## Documentation

- [The chronicle](https://felippeb.github.io/adibuttonauras-forever/) — the story, for humans (nice to share)
- [Technical brief](docs/technical-brief.md) — failure modes, cache state machine, observability, takeaways
- [Port notes](docs/port-notes.md) — the chronological patch log

The chronicle is also readable in-repo at [docs/index.md](docs/index.md).

## Compatibility

Verified on WoW Forever `1.60.1` / interface `16001` with a level-38 paladin. Other classes are
untouched: the retail rules are still registered, filtered to spells the client actually knows.
Open the config with `/aba`.

## Credits and license

Based on **AdiButtonAuras 11.0.4** by the
[AdiAddons](https://github.com/AdiAddons/AdiButtonAuras) authors, licensed **GPL-3.0**. This is a
modified version — see [NOTICE](NOTICE). Not affiliated with or endorsed by the original authors,
Blizzard Entertainment, or CurseForge.

GPL-3.0 — see [LICENSE](LICENSE).
