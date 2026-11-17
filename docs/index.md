---
layout: default
title: The Chronicle
---

<img src="assets/logo-400.png" width="88" alt="AdiButtonAuras Forever">

# The Chronicle of the Dimmed Buttons

*A retail addon, a Wrath-era paladin, and a client that answers "no".*

## The problem in one paragraph

AdiButtonAuras highlights action buttons when a buff or debuff is up. It assumes the client hands
addon Lua the same aura data the default UI sees. WoW Forever does not: in combat it hides other
units entirely, and it can return aura fields as *secret* values — opaque handles you may hold but
not inspect. Worse, the enumeration API signals "hidden" as an **empty list** rather than an error.
A retail addon reads that as "this unit has no auras" and wipes its cache. That one sentence
explains most of the work below.

## I. Making it load

Retail code, older client. First job was survival, not features:

- the TOC targets `16001` and a compat layer (`Forever.lua`) loads **before** the embedded libraries;
- spell, aura, cooldown and item APIs are resolved by feature detection, with legacy fallbacks;
- libraries that died silently got defenses: a Classic-season check that was `true` when both
  project constants were nil, a spellbook scan that expected modern structs, a texture path guessed
  from `debugstack()` with the wrong slash.

That took it from "Lua errors" to "no highlights" — progress.

## II. The 44 useless rules

The rules that survived came from retail data: Holy Power, Crusader Strike, Shield of the
Righteous. A level-38 Wrath paladin has none of them. So the addon got a Forever rule file written
against the actual spellbook: seals, blessings, auras, Righteous Fury — and countdowns up to an
hour, because the buffs last thirty minutes and the upstream display only started showing a timer
in the last ten.

## III. The Great Cache Wipe

*"After 3–4 seal switches nothing works at all."*

In combat, `GetAuraSlots` returns an empty list. The rebuild read that as "no buffs" and erased
every button. The fix is a policy, not a patch: **a restricted read is unknown, and unknown means
freeze.** Keep the last good snapshot, merge while blind, and let the client be authoritative again
the moment it is readable.

Seals cast during a fight still cannot be read, so the addon remembers its own successful casts,
with an absolute expiration, and reconciles them the first time the real aura appears.

## IV. The False Prophecy of Judgement

A video showed the seal button going dark on every Judgement while the buff bar kept ticking. The
old code assumed Judgement consumes the seal — true on Wrath Classic, false here. That branch was
deleted. The seal keeps its border, and the countdown keeps going.

## V. The Temptation of Target Debuffs

The target frame showed Judgement at 40 seconds and Consecration with no timer at all. Two rules
were written. Then the probe answered:

```text
HELPFUL: enumeration blocked (nil)
HARMFUL: enumeration blocked (nil)
```

Enemy auras are unreadable in combat, full stop. The two addons that "manage it" either run on
another client, or use Blizzard's secure `AuraContainer`, which renders auras without addon Lua
ever seeing the data. So both rules were removed. The buttons show nothing instead of a guess.

## VI. Names and Neighbours

Seal of Wisdom stayed dark because the aura id the client applies is not always a spellbook rank
id. Rules now match on id **or** normalized aura name. And because a Blessing of Wisdom from the
other paladin lives outside your own-cast cache, the self-buff handler scans every helpful aura on
you, not just the ones you applied.

## VII. The Lingering Fury

The last boss: after swapping Fury → Light in combat, *both* stayed lit. The remembered cast was
correct; the cache merge kept re-adding the old seal the client still reported. Seals are now
identified by **family** (`seal of fury`, `seal of light`, …) resolved from id or name, and the
cache drops replaced families before it rebuilds. Unknown ids are never treated as stale, so the
filter cannot hide a real aura.

---

## The hero

**Grumnir Coppercog, dwarf Protection paladin, Engineering 450.** Shield in one hand, spanner in
the other, and an unreasonable refusal to accept "the API does not work that way."

He is not a damage dealer. He stands in front, takes the hit, and makes sure everyone else's
buttons light up on time — which is, honestly, the job description of a debugging harness with a
beard.

Motto: *"An empty slot list is not an empty buff list."*
