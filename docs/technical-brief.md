# AdiButtonAuras on "WoW: Forever" — engineering brief

Porting a retail addon (11.0.4) to a Wrath-era client running on a modern binary
(Interface 16001, `X-Flavor: Forever`). The hard problem was not API compatibility;
it was **cache coherence under partial observability**.

---

## 1. Elevator pitch

The client lets addons read the player's own buffs, but in combat it hides other
units entirely and can return buff data as *secret values* — opaque handles you may
hold but not inspect. Worse, the enumeration API signals "hidden" as an **empty
list**, not an error. A retail addon reads that as "the unit has no auras" and wipes
its cache.

So: a stateful, event-driven UI whose authoritative input is intermittently
unreadable, with no debugger. Everything below is the consequence of taking
"unknown" seriously.

---

## 2. Constraints

| Constraint | Consequence |
| --- | --- |
| No git, no Lua interpreter | `luaparser` (Python) for syntax, byte-level BOM/CRLF checks, pristine backup dir |
| Addon folders read at startup | New files need a full client restart; `.lua` edits need `/reload` |
| No debugger, no stdout | In-band probe commands (`/abaforever`) mirrored into SavedVariables, flushed on `/reload` |
| Combat lockdown | Player auras readable; non-player auras unreadable; some values secret |
| Custom spell ids (1.3M range) | Aura ids do not always equal spellbook ids; names are the stable key |
| User policy: no false info | A button stays neutral rather than show a guessed timer |

---

## 3. Failure modes found (symptom -> root cause -> fix)

1. **Lua errors on login.** Retail APIs absent (`C_AddOns`, `C_Spell`, `GetItemSpell`,
   `IsHarmfulItem`, `TooltipDataProcessor`); `LibDualSpec` guard read
   `WOW_PROJECT_CLASSIC` (nil) and called a nonexistent `C_Seasons`; `LibSpellbook`
   used the modern `C_SpellBook` struct API; `SMBH` derived its path from
   `debugstack()` with a forward-slash regex.
   -> Compat shim (`Forever.lua`, loaded first) + defensive library patches.

2. **Zero highlights.** All working rules came from retail data (Holy Power,
   Crusader Strike); none exist on a Wrath paladin.
   -> 34 Forever-specific rules from the actual spellbook.

3. **30-minute buffs showed no timer.** Upstream draws countdowns only in the last
   600 s.
   -> `maxCountdown` 600 -> 3600, with migration of existing profiles.

4. **"Nothing works after 3-4 seal swaps."** In combat `GetAuraSlots` returns an
   empty slot list; the rebuild treated it as "no auras" and wiped every button.
   -> Restricted empty read = **unknown**: freeze, keep cache.

5. **Seal cast in combat never lit.** The client hides the aura the instant it is
   applied; no read can observe it.
   -> Remembered-cast subsystem: own `UNIT_SPELLCAST_SUCCEEDED` writes an optimistic
   entry with an absolute expiration under a private key range; reconciled when the
   real aura becomes readable.

6. **Countdown wrong (14m vs 30m).** The duration was never measured because the
   buff was cast while hidden.
   -> Measure durations from any readable instance; remembered casts use that cache,
   with a 30 s fallback for seals.

7. **Seal button went dark on every Judgement.** Upstream assumed Judgement consumes
   the seal (Wrath Classic). On this client it does not.
   -> Deleted that branch; added seal-replacement semantics on cast instead.

8. **Old seal stayed lit after a swap.** The restricted read kept *reporting the
   old seal*, and the merge only adds auras.
   -> Seal **families** (`seal of fury`, `seal of light`, ...) resolved from id or
   display name; `lastSeal` + `IsStaleSeal` + `DropReplacedSeals`.

9. **Seal of Wisdom never lit.** The aura id the client applies is not one of the
   spellbook rank ids.
   -> Match rules by id **or** normalized aura name. Secret names count as "no
   match", never as an error.

10. **Another paladin's Blessing of Wisdom was invisible.** Rules only read
    `HELPFUL PLAYER` (own casts).
    -> Scan own auras first, then all helpful auras on the player.

11. **Target debuff buttons stayed dark.** Non-player units are fully unreadable in
    combat (both slot and index APIs return nothing). Verified with probes, not
    guesswork.
    -> Removed the Judgement/Consecration rules. Nothing beats a wrong timer.

12. **Errors were hidden.** The release bundle's BugGrabber replaced the Lua error
    handler and kept stacks out of the client log.
    -> Restored/wrapped the handler; every error is also copied into the probe
    buffer and reaches disk on `/reload`.

---

## 4. Architecture

```
Forever.lua            compat shim, global ABACompat, loaded before libraries
  |                    - spell/aura/cooldown API resolution by feature detection
  |                    - secret-value-safe readers (Field, IsSecret, Restricted)
  |                    - slot + index enumeration, probes, error capture
core/
  AuraTools.lua        per-unit, per-filter aura caches + update state machine
  Overlays.lua         per-button rule evaluation, pcall'd, timer/highlight render
  RuleDSL.lua          rule registration, sandboxed rule environment
  Display.lua          borders, countdowns, textures (with fallbacks)
rules/
  Forever.lua          Wrath paladin rules: seals, blessings, auras, Righteous Fury
```

### Cache model

Four cache kinds per unit: `PlayerBuff` (`HELPFUL PLAYER`), `PlayerDebuff`
(`HARMFUL PLAYER`), `Buff` (`HELPFUL`), `Debuff` (`HARMFUL`). Lazily created.

### Update state machine (per `UNIT_AURA`)

```
enumerate slots
  nil                -> FREEZE (keep cache, record reason)
  restricted & <=1   -> FREEZE ("empty while restricted")
  per slot:
    no data          -> INCOMPLETE
    filter unknown   -> INCOMPLETE
    spellId unreadable (secret) -> INCOMPLETE
  INCOMPLETE         -> FREEZE; out of combat retry up to 3x @ 250 ms
  complete & restricted -> MERGE  (add/refresh; absent entries keep last absolute expiry)
  complete & open       -> REPLACE (client is authoritative; drops speculation)
```

### Merge semantics

- Keyed by `auraInstanceID` where available, else `-spellId`.
- **Add-wins** while restricted; nothing is removed by absence.
- Absent auras keep their last known **absolute** expiration, so they self-expire
  into the neutral state without a delete event. Time-based tombstones instead of
  event-based deletes.
- `PLAYER_REGEN_ENABLED` triggers a full refresh, not a wipe (a wipe flashes every
  buff as "missing" right after combat).

### Remembered casts (optimistic concurrency, offline-style)

- Key space: `-100000 - spellId`, disjoint from real instance ids.
- Written on own `UNIT_SPELLCAST_SUCCEEDED`, with `expiration = now + duration`.
- Removed the moment the real aura is readable again, or when a new seal replaces it.
- Final patch adds seal identity across ranks/custom ids:

```
SealFamily(id, name) -> "seal of light" | ... | nil
lastSeal = { id, name, family, expires }         -- set on every seal cast
IsStaleSeal(aura)                                 -- skip known, different families
DropReplacedSeals(cache)                          -- purge at the top of FullUpdate,
                                                  -- before any early return
```

Unknown ids are never treated as stale: the filter can only suppress a **known**
different seal, so it cannot hide a real aura.

### Rule evaluation

- Rules run in a **sandboxed environment** (allowlisted globals/libraries), so a
  rule file cannot touch arbitrary client state.
- Every handler is `pcall`'d per button update; the first error per handler is
  recorded and surfaced as `herrs=` in the probe. One bad rule cannot freeze the UI.
- Self-buff handler: id set + normalized name set; scans `IteratePlayerBuffs`
  (own, includes remembered casts) then `IterateBuffs` (all helpful auras on the
  player). Only a buff actually on the player lights a button.
- Display policy: green border + countdown only while active; neutral otherwise;
  no `missing` reminder by default. No `flash` (the client lacks LibButtonGlow's
  `SpellActivationOverlay\IconAlert` textures).

---

## 5. Observability (no debugger)

`/abaforever` family, all mirrored into `ABAForeverProbe` (SavedVariables, flushed
by `/reload`, ring-buffered):

| Command | Purpose |
| --- | --- |
| `/abaforever` | build, API presence matrix, restricted flag, cache snapshot, rule counts |
| `/abaforever spells` | full spellbook dump (id + name) to write rules |
| `/abaforever rules` | registered rules, units, events |
| `/abaforever buttons [n]` | per-slot: action, rule, enabled, handlers, highlight/flash/hint, `herrs=` |
| `/abaforever aura <id>` | single-buff check against the cache |
| `/abaforever auras [unit]` | live slots + cache state + remembered casts + last seal + event counters |
| `/abaforever target` | non-player unit: method used, name/id secrecy, cached debuffs |
| `/abaforever judge` | runs the Judgement handlers directly (handler vs overlay isolation) |

Counters: `full`, `frozen`, `retries`, last rebuild reason, last slot count,
per-button handler-error count. That is enough to distinguish "API returned
nothing", "read was incomplete", and "rule did not match" from a single dump.

Error capture: wraps whatever handler is active, records into the probe, then
delegates — compatible with BugGrabber being present.

Video forensics: ffmpeg frame extraction + PIL contact sheets, cropped to the action
bar and the buff bar, to timestamp behaviour (e.g. seal at 29 s -> dark on the
Judgement frame).

---

## 6. Timeline

| Time | Patch |
| --- | --- |
| 16:36 | Install release zip (vendored libs), toc `16001`/`Forever`, compat shim loaded first |
| pre-restart | LibSpellbook silent-failure hardening (no rules = no error was the worst case) |
| 19:30 | Four error classes cleared; Forever paladin rules; probe tooling |
| 20:05 | Full Judgement rank sets; `maxCountdown` 3600 (+ migration) |
| 20:40 | Cache-wipe fix (restricted = freeze/merge); remembered casts; active-only display |
| 21:05 | Judgement does not consume seals; seal replacement; 30 s seal duration |
| 21:40 | Index-API enumeration for other units; aura-name matching |
| 22:10 | Target-debuff rules deleted (enemy auras unreadable in combat) |
| 22:25 | Self-buffs match by aura name (custom ids) |
| 22:45 | Seal casts in combat never dropped; 30 s fallback; order fixed |
| 22:55 | Foreign buffs: scan `HELPFUL` as well as `HELPFUL PLAYER` |
| 23:30 | Seal families, `lastSeal`, stale-seal suppression, pre-return purge |

---

## 7. Takeaways for the DevOps crowd

1. **Unknown is a state, not a value.** Three-valued logic (present / absent /
   unknown); on unknown, freeze and keep the last good snapshot.
2. **Never let tainted data falsify an assertion.** A secret value must produce
   "no match", never "missing".
3. **Full resync beats deltas when the delta key is unavailable.** Instance ids are
   secret in combat, so every event rebuilds from enumeration.
4. **Absence is not deletion.** Add-wins merge + absolute-expiry tombstones is
   simpler and safer than event-driven removes.
5. **Optimistic local writes need reconciliation.** Speculation only inside the
   unobservable window; drop it the moment authority returns.
6. **Feature-detect, do not version-detect.** Build strings and project constants
   lie; `type(fn) == "function"` does not.
7. **Observability is a feature.** In-band probes, counters, last-reason fields and
   a disk-backed ring buffer replaced a debugger.
8. **Fail soft internally, fail honest externally.** Guard every handler; never
   show a user a claim the data cannot support.
9. **Guard the extension boundary.** Sandboxed rule env, per-handler `pcall`,
   first-error reporting.
10. **Byte discipline where there is no VCS.** Parse, BOM/CRLF scan, pristine
    backup, smallest possible diff.

---

## 8. Known limits / next option

- **Enemy auras in combat:** impossible for addon Lua on this client. A display-only
  path exists: parent a Blizzard secure `AuraContainer`
  (`CustomAuraContainerTemplate`, `HARMFUL|PLAYER`, candidate spell ids) to the
  Judgement/Consecration buttons; it renders border/timer without exposing data.
  Not implemented, because the candidate debuff ids must be learned out of combat
  and the result would sit outside the rule engine.
- **Seal duration** relies on the observed 30 s; if the server changes it, update
  the `ProcessAura` fallback.
- **Rule coverage** is for the current spellbook (34 rules); new ranks/spells need
  new entries.

---

## 9. For the record

Grumnir Coppercog, dwarf Protection paladin, Engineering 450. Motto:
"An empty slot list is not an empty buff list."
