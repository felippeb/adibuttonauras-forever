# AdiButtonAuras on the `_forever_` client — port notes

Started 2026-11-16. Companion to `wow-forever-addons-handoff.md`.

## What was installed

| Item | Path |
| --- | --- |
| Addon | `...\_forever_\Interface\AddOns\AdiButtonAuras\` |
| Config (load-on-demand) | `...\_forever_\Interface\AddOns\AdiButtonAuras_Config\` |
| Pristine 11.0.4 backup | `%USERPROFILE%\OneDrive\Documents\Projects\wow-addons-backup\AdiButtonAuras-pristine-11.0.4\` |
| Source used | GitHub release `11.0.4` (`AdiButtonAuras-11.0.4.zip`, full/no-lib variant with vendored libs) |

Notes:
- The repo tarball is **not** usable directly: its `.toc` has every library line inside `#@non-debug@` packager markers, so the release zip is the right source.
- `SMBH\` (SharedMedia_ButtonHighlight) ships *inside* the AdiButtonAuras folder and is loaded from the main toc (`SMBH\lib.xml`). Its `SharedMedia_ButtonHighlight.toc` is not a separate addon folder.
- Client must be fully restarted before the new folders and toc metadata are read; after that, `.lua` edits only need `/reload`.

## Patches applied (all files parse with luaparser)

### toc
- `AdiButtonAuras.toc`: `## Interface: 16001`, `## X-Flavor: Forever`, and `Forever.lua` loaded **first** (before LibStub and the other libs).
- `AdiButtonAuras_Config.toc`: `## Interface: 16001`, `## X-Flavor: Forever`.

### `Forever.lua` (new, loaded first)
Feature-detection shim exposed as the single global `ABACompat`:
- `GetSpellInfoTable` / `GetSpellInfo` / `GetSpellName` / `GetSpellLink` / `GetSpellTexture` — prefer `C_Spell.*`, fall back to the legacy globals; invalid/empty spell ids are rejected (the client throws a usage error for `""`/`0`).
- `IsSecret`, `Field`, `Restricted` — secret-value safe reads (`C_Secrets.ShouldAurasBeSecret` / `issecretvalue`), with the `RighteousFuryAlerter` rule that an unreadable value is "unknown", never "missing".
- `GetAuraSlots` / `GetAuraDataBySlot` / `IsAuraFilteredOut` — pcall-wrapped slot API, plus an index-based (`GetAuraDataByIndex`) fallback for builds that lack the slot API.
- `NormalizeCooldown` — accepts both the legacy `start, duration` and the newer cooldown table.
- `/abaforever` probe command, `/abaforever spells` dump of the client's spellbook (id + name, via LibSpellbook).

### `core/AuraTools.lua` (the important change)
- Aura fields are read through `ABACompat.Field`; a secret `spellId` means "cannot identify", which makes the whole update **freeze**: the previous cache is kept instead of being rebuilt without that aura. This is what prevents "buff is up but the button says missing" in combat.
- Incremental `UNIT_AURA` updates (instance-ID based, unreadable in combat) were replaced by a full rebuild from the slot enumeration on every `UNIT_AURA`.
- `PLAYER_REGEN_ENABLED` now refreshes all caches instead of `wipe(cache)` (the old code could flash every aura as missing right after combat).
- Auras whose `applications`/`dispelName`/`expirationTime` are hidden keep the last known values (an unreadable expiry is never treated as expired).

### Other startup-critical fixes
- `libs/LibDualSpec-1.0`: the load guard was `if WOW_PROJECT_ID == WOW_PROJECT_CLASSIC and C_Seasons.GetActiveSeason() ...` — with both project constants nil this is true and `C_Seasons` does not exist here, so the library died at load and `Core.lua` then failed on `GetLib('LibDualSpec-1.0')`. Now the season check only runs on a real Classic project; the legacy `ACTIVE_TALENT_GROUP_CHANGED` registration is pcall-guarded and `GetSpecialization` is called through pcall.
- `libs/LibPlayerSpells-1.0` + `libs/LibSpellbook-1.0`: spell-name lookups go through `ABACompat` instead of `C_Spell.*`.
- `SMBH/SMBH.lua`: texture path was derived from `debugstack()` with a forward-slash regex; now tolerates `\` and falls back to `AdiButtonAuras\SMBH\` so a failed match cannot abort the addon load.
- `core/DebugTooltip.lua`: returns early when `TooltipDataProcessor`/`Enum.TooltipDataType` are missing (they are absent from this client's binary).
- `core/Core.lua`: `C_AddOns.*` resolved with legacy fallbacks; `ActionBarButtonEventsFrame`, `PetActionBar`, `StanceBar`, `NumberFontNormalSmall`, `CloseAllWindows`, `Settings.OpenToCategory` are all nil-guarded.
- `core/Display.lua`: `button.cooldown` and `button.."Count"` may be missing; highlight texture falls back to `Interface\Buttons\ButtonHilight-Square` if the `button_highlight` media type was not registered.
- `core/RuleDSL.lua`: `SpellOrItemId` no longer raises for spell ids the client does not know (retail-only spells) — one stale id no longer aborts a whole rules file; `WarnOnStaleData` no longer does arithmetic on the client's non-numeric build string.
- `config/{Debug,Spells,UserRules}.lua`: same `C_Spell`/`C_AddOns` resolution, nil-safe debug dump.

## How to test (first run needs a client restart)

1. Fully exit the game.
2. Start it, at character select open **AddOns** and enable `AdiButtonAuras` **and** `AdiButtonAuras_Config` (both show as out of date? they should not, Interface is 16001 now).
3. In game: `/console scriptErrors 1`
4. `/abaforever` -> prints client build, which C_ APIs exist, whether aura reads are restricted, how many player buffs are readable, the spellbook scan state and what the addon cache holds. Run it once out of combat and once in combat.
5. `/abaforever spells` -> dumps every spell id/name in the spellbook (needed to write Forever-specific rules).
6. `/aba` -> opens the config GUI (tests Ace3 + `Settings` integration).
7. Errors are written by the client to `...\_forever_\Logs\General.log` (`[E][Lua] Lua Error:` lines with full stacks), so no copy/paste from chat is needed.

## Known unknowns / caveats

- Whether the built-in retail rules match this client's spells is unknown. Rules are filtered by `LibSpellbook:IsKnown(spellId)`, so only spells actually in the spellbook can fire; the rest are inert. A Forever-specific rules file (paladin seals/judgements/blessings) will probably be needed for a useful result.
- `C_UnitAuras.GetAuraSlots` + `GetAuraDataBySlot` are present in the client binary, but they have not been exercised yet; the index fallback exists in case the runtime disagrees.
- The combat behaviour chosen here is "freeze on restricted reads" (same philosophy as RighteousFuryAlerter). A buff that expires mid-combat keeps its last known state until data is readable again.

## Patch #2 - LibSpellbook silent-failure hardening (2026-11-16, after install)

State found before the first restart: the addon folders were created at 16:36 but the running client
started at 12:25, so the client cannot see them yet, and no `AdiButtonAuras.lua` exists under
`WTF\Account\<ACCOUNT>\SavedVariables\` (proof it has never been loaded). A restart is still required.

While waiting, the two places where this port could fail *silently* (no error, but zero highlights)
were hardened:

- `libs/LibSpellbook-1.0/core.lua` - `IsKnown` used a bare `IsPlayerSpell(spell)` fallback for any
  spell not in the scanned spellbook. If that global is missing (it is not in the exe strings) every
  rule registration would raise and the rules file would abort. Now: new `KnownSpell()` tries
  `IsPlayerSpell` -> `IsSpellKnown` -> `C_SpellBook.IsSpellKnown` (all pcall'd, `false` is respected,
  `nil` means "cannot tell"), and only as a last resort accepts "the client database knows this id".
  That last resort can never create a false highlight: a rule is still keyed to the spell on the
  button, so it can only fire on a button that really carries that spell.
- `libs/LibSpellbook-1.0/general.lua` - the scan assumed the modern `C_SpellBook` struct API and
  `Enum.SpellBookItemType`/`Enum.SpellBookSpellBank`. It is now fully defensive: numeric enum
  fallbacks (Spell=1, Flyout=2, PetAction=4, Player bank=0, Pet bank=1), pcall on every call,
  a legacy `GetSpellBookItemInfo(index, bookType)` -> `itemType, actionId` fallback, name resolved
  through `ABACompat.GetSpellName`, and `C_PvP`/`C_SpecializationInfo`/`GetPvpTalentInfoByID`
  guarded. If the spellbook cannot be read at all, `LibSpellbook_Spells_Changed` is still fired once
  so rules get registered instead of the addon sitting there with no rules and no error.
- `Forever.lua` - `/abaforever` now also prints the spellbook scan state (spell count, `HasSpells`),
  `C_SpellBook` skill-line count, the shape of slot 1 (`itemType`/`actionID`/`spellID`/`name`, or
  "error" if the call raised) and whether `Enum.SpellBook*` tables exist. That single output decides
  whether the scan works, without guessing from the binary.

Pre-restart checks done: both `AdiButtonAuras*.toc` correctly declare `Interface: 16001` +
`X-Flavor: Forever`; `config.xml` and the `..\AdiButtonAuras\...` toc paths are byte-identical in
layout to upstream (that layout is what CurseForge ships, so `..\` must be supported - no other addon
on this machine uses it, so it is still the top suspect if `AdiButtonAuras_Config` fails to load);
all `.lua` files parse with luaparser and none has a BOM.

Reading the probe without chat copy/paste: `AdiButtonAuras.toc` now also declares
`## SavedVariables: ABAForeverProbe`, and every `/abaforever` line is mirrored into that table.
So: run `/abaforever`, `/abaforever spells`, then `/reload`; the file
`WTF\Account\<ACCOUNT>\SavedVariables\ABAForeverProbe.lua` on disk then holds the exact output
(with a `=== /abaforever <arg> @ HH:MM:SS inCombat=...` header per run, capped at 1500 lines).

## Session 2026-11-16 19:30 - errors cleared, Forever paladin rules added

Log review after the previous reload showed exactly four error classes, all now fixed:
- `core/Items.lua:47` (48x) - `IsHarmfulItem`/`IsHelpfulItem` are gone from this client.
  `Forever.lua` now installs `ABACompat.IsHarmfulItem`/`IsHelpfulItem` (defaulting to
  "helpful") and `Items.lua` falls back to them.
- `core/Items.lua:103` (37x) - legacy `GetItemSpell` global is gone; `ABACompat.GetItemSpell`
  resolves it from `C_Item` and `Items.lua` uses the compat getter.
- `core/RuleDSL.lua:109` (2x) - same for `GetItemInfo`.
- `Blizzard_DeprecatedActionBar:28` (34x) - the legacy `GetActionCooldown` shim raises on empty
  slots; `core/Overlays.lua` now skips slot 0/nil and `pcall`s it (same for stance/pet bars).

Probe work:
- `/abaforever rules` lists every registered rule with units/events; `/abaforever buttons`
  now prints `rule`/`enabled`/`handlers`/`highlight`/`flash`/`hint`/`expiration`
  per action slot.
- `/abaforever aura <spellId>` checks a single player buff against the aura cache.
- `/abaforever` reports how many spells carry a `:Forever` rule.
- Player buffs are now printed with their spell names, so buff ids can be matched to casts.

Why nothing was highlighted: the 44 rules that survived came almost entirely from
LibPlayerSpells' retail paladin data (Holy Power, Crusader Strike, ...), none of which is on a
Wrath-era paladin bar. The player's spellbook is seals / blessings / auras / Judgement.

New `rules/Forever.lua` (registered from `rules/rules.xml`, PALADIN only) covers:
- one seal group (righteousness, crusader, justice, light, wisdom, fury ranks),
- blessings (might, wisdom, kings, protection, freedom),
- auras (devotion, retribution, concentration, shadow/frost/fire resistance),
- Righteous Fury,
- Judgement (tracks the target's judgement debuffs 20184/20185/20186/21183).

Display policy: green border + countdown while the buff is up; red border when it is missing,
but only when `IsAuraReadRestricted()` is false (added to the rule sandbox from
`ABACompat.Restricted`). Under restricted reads the handler stays silent, so a hidden aura can
never become a false "missing". `flash` was avoided on purpose: LibButtonGlow uses the
`Interface\SpellActivationOverlay\IconAlert` textures, which this client does not ship.

## Session 2026-11-16 20:05 - Judgement rank ids + 30 minute countdowns

User report: after judging with Seal of Light the Judgement button stayed dark, and
Righteous Fury showed the green border but no countdown.

- Countdowns: upstream only draws the timer during the last ten minutes
  (`maxCountdown = 600`). Seals/blessings/Righteous Fury last 30 minutes on this client,
  so `DEFAULT_SETTINGS.profile.maxCountdown` is now 3600 and `Initialize` migrates an
  existing 600 profile to 3600. `Display.Timer_Update` then prints `30m` and keeps
  ticking (`timer % 60`).
- Judgement: the old handler only knew the rank 1 debuff ids (20185, 20186, 21183).
  LibClassicDurations ships the full rank sets, now used: Light 20185/20344/20345/20346,
  Wisdom 20186/20354/20355, Crusader 21183/20188/20300..20303, Justice 20184 (plus
  32220/53742/53745). Any target debuff whose name contains "Judgement"/"Judgment" also
  matches, which covers the custom 1.3M ids (e.g. Seal of Fury) that LibClassicDurations
  cannot know.
- The rules sandbox now exposes `GetSpellName` (the ABACompat wrapper, pcall-guarded) and
  allows `pcall`, so the name fallback cannot raise on a secret aura id. A failed read sets
  `restricted` and the handler stays silent instead of reporting "no Judgement".
- Spell groups widened to every rank from LibClassicDurations (seals, blessings, devotion /
  retribution auras) and Seal of Command was added. Rank 1 sets would miss e.g. Seal of Light
  rank 2+ once the character levels.
- New probe: `/abaforever judge` runs the registered `spell:20271` handlers directly with
  `units.enemy = target` and prints result/highlight/expiration, separating a handler bug from
  an overlay/button bug. `/abaforever target` now also prints `secretId`/`secretName`.

Pending user verification after `/reload`: timer on Righteous Fury, border on Judgement after
judging, and the `/abaforever judge` + `/abaforever target` output.
## Session 2026-11-16 20:40 - combat cache wipe + remembered casts

User report: after 3-4 seal switches "nothing works at all", and a seal cast after judging
did not light. Screenshots: Righteous Fury button `14m` while the buff bar showed `30m`.

Root cause found in `core/AuraTools.lua`:

- `C_UnitAuras.GetAuraSlots` does not raise while auras are hidden, it returns an **empty
  slot list**. `FullUpdate` treated that as "the player has no auras" and wiped the cache.
  Every seal switch fires `UNIT_AURA`, so a few switches in combat emptied every button.
  Now an empty answer while `ABACompat.Restricted()` is true is "unknown": the cache is kept.
- While restricted the rebuild now **merges** instead of replacing: auras that are missing
  from the restricted list (the active seal, Righteous Fury) keep their last known absolute
  expiration, so once that time passes the button goes dark on its own.
- Out of combat the client stays authoritative: full replace, which also drops remembered data.

New: remembered casts, mirroring PallyPower.

- `ProcessAura` records each aura's duration (the `duration` field, else
  `C_UnitAuras.GetAuraDuration`, else the first observed remaining time when over 30 s).
- `UNIT_SPELLCAST_SUCCEEDED` on `player`: if the cast spell has a known duration, a
  remembered entry `{id, expiration = now + duration}` is placed in the `PlayerBuff` cache
  under key `-100000 - id`, replacing any stale copy of that spell. This makes a seal or
  Righteous Fury cast while the client hides it readable immediately, and fixes a stale
  countdown (14m vs 30m).
- First version cleared remembered `Seal of *` entries on a Judgement cast (assuming the
  seal is consumed). **Wrong for this client** - see the 21:05 session below.
- The merge drops the remembered entry as soon as the real aura is readable again.

Rules: only *active* auras light now.

- `BuildSelfBuffHandler` requires `expiration - GetTime() > 0` (or no expiration at all).
  Previously a frozen cache entry with a past expiration still showed a green border.
- `JudgementHandler` only counts target debuffs with `expiration > GetTime()`.

Diagnostics: `AuraTools.DebugState(unit)` (per-cache count, retries, last rebuild reason,
remembered casts) and `AuraTools.DebugStats()` (event counts, full/frozen/retry counters).
Probe `/abaforever auras [unit]` dumps every live slot (`id`, `name`, `left`, `dur`, `inst`,
`filtered`) for HELPFUL and HARMFUL plus both tables above.

Robustness: `Overlays.UpdateState` wraps each rule handler in `pcall` and records the first
error per handler, so one bad rule can no longer stop a button (or spam the error log on
every OnUpdate). `/abaforever buttons` prints `herrs=` per button.

All four edited files parse clean (luaparser), CRLF, no BOM. Needs `/reload`; new files are
not involved, so no client restart.

## Session 2026-11-16 21:05 - judging does not consume seals (video)

User video (22 s, <ZONE>, fighting a Sand Crawler) shows the Seal of Fury
button green with `22s` at 00:08, then immediately dark at 00:09 when Judgement is cast,
while the top-right buff bar keeps showing the seal (`21s`, counting down). User confirms:
on WoW Forever, unlike Wrath Classic, judging does **not** consume the seal; it stays on the
paladin.

- The disappearance was self-inflicted: `NoteCast` deleted every `Seal of *` cache entry on
  a `Judgement`/`Judgment` cast. That branch is removed; a Judgement cast now does nothing.
- Seal replacement instead: casting any `Seal of ...` removes the *other* stored seals
  before the new one is remembered. Without it, a restricted (in-combat) read can keep
  listing the previous seal, so two seal buttons would stay lit until the old one expired.
- Seal duration fallback: the video shows 29 s right after a cast, i.e. Forever seals last
  30 s. `ProcessAura` now falls back to 30 s for `Seal of *` auras when the client gives no
  `duration` field, before the generic "remaining time" guess (which cannot work for a 30 s
  aura). Blessings/Righteous Fury keep using their measured duration (~30 min, matching the
  buff bar).

Still to confirm after `/reload`: judge with Seal of Fury up -> border and countdown must
stay; swap seals in combat -> only the new seal lights.

Files: `core/AuraTools.lua` only. Parses clean, CRLF, no BOM. `/reload`, no restart.

## Session 2026-11-16 21:40 - target debuffs (Consecration / Judgement)

Videos (34 s + 28 s, Brineshell Clacker): target frame shows a blue-bordered
"Consecration" debuff (36 s) and a blue-bordered Judgement debuff (40 s) after judging
Seal of Light. Neither action button lights.

Two separate causes:

1. **There was no Consecration rule at all.** Upstream `rules/Paladin.lua` only adds
   HolyPower rules. Added `ForeverConsecration` (ids 26573/20116, unit "enemy",
   `UNIT_AURA`) matching any target debuff whose *name* contains "Consecration", red
   border + countdown while it lasts.

2. **Target units were read through the slot API.** `C_UnitAuras.GetAuraSlots` /
   `GetAuraDataBySlot` only proved reliable for the player. Both known-good consumers
   on this client use the index API instead: PallyPower (`GetAuraDataByIndex`) and
   LiteButtonAuras (`AuraUtil.ForEachAura`, which wraps it). Compat now enumerates every
   non-player unit with `GetAuraDataByIndex` (`ScanByIndex`), records which method was
   used per unit (`auraMethodByUnit`) and `GetAuraDataBySlot` fetches with the same
   method. Player path is unchanged.

Also:
- `ProcessAura` stores the aura `name` and `auraIterator` yields it as a 6th value.
  Rule handlers now match on the aura's own name first and only fall back to
  `GetSpellName(id)`. This is how LiteButtonAuras works (it indexes auras by name, not
  id), which matters on Forever where ids are custom (1.3M range, e.g. 1328548).
- `IsJudgementDebuff(id, name)` takes the cached name; `JudgementHandler` passes it.
  `TargetDebuffByName` (Consecration) treats unnamed entries as "restricted", never as
  "absent".
- `/abaforever target` prints `cachedName` per debuff.
- Research: ActionBarAuras (xod-wow) lists Interface 16001 in its TOC but is built on
  Blizzard `CustomAuraContainer` + `C_RestrictedActions` (11.x secret-safe UI aura
  containers), not on C_UnitAuras enumeration - nothing directly portable to ABA.
  LiteButtonAuras is Classic-only (50504/38002/20506/11509), and its name-based
  index-scan approach is what we adopted above.

If the buttons are still dark after `/reload`, `/abaforever auras target` +
`/abaforever target` with a debuffed target, then `/reload` - the dump shows whether the
client hides enemy auras entirely (`enumeration blocked`, `hidden`, `unreadable spell id`)
or whether it is a rule-matching problem (`debuffs seen: N`).

## Session 2026-11-16 22:10 - target debuffs removed (no false info)

Probe output from the 04:02 video, in combat against Brineshell Clacker:

```
=== /abaforever auras target ... inCombat=true restricted=true
HELPFUL: enumeration blocked (nil)
HARMFUL: enumeration blocked (nil)
```

So this client blocks **all** addon aura reads for non-player units in combat.
`GetAuraSlots` and `GetAuraDataByIndex` both return nothing; only Blizzard's own
UI (target frame) still renders the debuffs. No index/slot API trick changes that.

Verified from the videos what the client itself shows:
- Judgement of Light on the target: blue (Magic) border, timer resets to **40 s**
  on every judge (counts 40,39,38...).
- Consecration on the target: red border, flame icon, **no timer at all**
  (duration 0/unknown) - it is tied to standing in the ground effect.

### Decision: no target-debuff rules at all

Remembering our own casts cannot be made reliable:

- the Judgement debuff depends on the active seal and custom seals have custom
  judgement debuffs (`Seal of Fury` -> a separate physical debuff seen on the
  target);
- the countdown would be a guess (only Light measured, 40 s);
- switching targets, another paladin judging, or a resisted/immune judge would
  all leave a stale border;
- Consecration is impossible: the target can walk out of the area at any time.

User explicitly prefers no information over wrong information. Removed both
`ForeverJudgement` and `ForeverConsecration` from `rules/Forever.lua`; the file
now registers only self-buff rules (seals, blessings, auras, Righteous Fury),
all of which read live data that is not restricted for the player. Left the
index-API enumeration and `aura.name` cache field in place (harmless, useful for
diagnostics/probes; no rule consumes target debuffs anymore).

### Why other addons "can do it"

- **LiteButtonAuras** (xod-wow): Classic-only - TOC 50504 (MoP Classic),
  38002 (Titan Reforged), 20506 (TBC Classic), 11509 (Classic Era). On those
  clients unit auras are plain readable data in combat, so its
  `AuraUtil.ForEachAura` + name matching just works. Its CurseForge page says
  outright: "for WoW classic only ... for retail you want ActionBarAuras". It
  never runs on Forever (16001), so it is not evidence that the reads work here.
- **ActionBarAuras** (xod-wow): does support 16001, but it does **not read
  auras**. Per button it creates a Blizzard `AuraContainer`
  (`CreateFrame('AuraContainer', nil, nil, 'CustomAuraContainerTemplate')`),
  sets `SetUnit('target')`, `SetAuraSlotFilterString('ABA', 'HARMFUL|PLAYER')`
  and `SetAuraSlotCandidateFilters('ABA', { includeSpellIDs = ... })`, then the
  secure container itself matches the aura and renders border + timer
  (`SetDurationText`, `SetApplicationCount`). Addon Lua never sees the aura
  data, which is exactly why it works in combat. The same `AuraContainer` API
  exists on this client (used by BetterBlizzFrames' `forever` modules).

A future option if target debuffs are ever wanted: a separate display path that
parents an `AuraContainer` to the Judgement/Consecration buttons with a
`HARMFUL|PLAYER` filter and candidate spell IDs (the actual debuff ids would
have to be learned out of combat). That would be display-only, outside the ABA
rule engine, and is not implemented.

## Session 2026-11-16 22:25 - self-buffs also match by name

User report: Seal of Wisdom does not light. Other seals do, so the rule is
registered and the handler runs; the buff the client puts on the player just
does not always use an id from the rule's rank list (custom 1.3M-range ids are
normal on this client, e.g. 1328548 Oath of Light).

`BuildSelfBuffHandler` now keeps two sets: the spell ids (`ToSet`) and the aura
names of those spells (`ToNameSet`, normalized: trimmed + lowercased).
`IteratePlayerBuffs` already yields `aura.name` (stored by `ProcessAura`), so a
buff matches if *either* its id is in the group *or* its name matches. Name
lookup runs inside `pcall`, so a secret name can only mean "no match", never an
error. This also covers every other seal/blessing/aura whose aura id differs
from the spellbook id.

`/abaforever auras` now prints `cachedName` for every cached player buff, so a
still-dark button can be diagnosed: compare the aura's real id/name with the
rule group.

Files: `rules/Forever.lua`, `Forever.lua` (probe only). Parse OK, CRLF, no BOM.

## Session 2026-11-16 22:45 - seal swapped in combat (Seal of Light / Wisdom)

Report: the seal you swap *to* in combat stays dark (first Seal of Light, then Seal of
Wisdom). Out of combat it works. That is the remembered-cast path, not the aura read.

Cause: `NoteCast` only remembered a cast when `durations[spellID]` was already known.
A seal is never readable in combat, so a seal that was never up out of combat has no
known duration -> the cast was dropped; worse, the previous seal had already been
removed, so every seal button went dark until combat ended.

Fix in `core/AuraTools.lua`:

- `SEAL_IDS` (all ranks incl. custom 1311649/1311656) + `IsSeal(id, name)`; a spell
  counts as a seal by name (`^Seal of `) or by known id, so a secret/nil name cannot
  hide it.
- `NoteCast` falls back to **30 s** for a seal whose duration was never measured (the
  buff bar shows 29 s right after a cast, so 30 s is right).
- The old seals are only cleared once the new seal is actually remembered. Order:
  resolve duration -> clear old seals -> store the new remembered aura.
- Remembered player buffs now keep their `name`, so the rules' name matching works
  for them too; `ProcessAura`'s 30 s seal fallback prefers the aura name over
  `GetSpellName(id)`.
- `/abaforever auras` prints `remembered id=... name=... left=...`.

Files: `core/AuraTools.lua`, `Forever.lua` (probe). Parse OK, CRLF, no BOM.

## Session 2026-11-16 22:55 - buffs from another paladin

The self-buff rules only scanned the `HELPFUL PLAYER` cache, i.e. auras the player
applied. A Blessing of Wisdom cast by the other paladin is not in that cache, so the
button stayed neutral even though the buff was on the player.

`BuildSelfBuffHandler` now checks two caches in order:

1. `IteratePlayerBuffs(unit)` - own auras (also where a seal cast in combat is
   remembered, so this must stay first);
2. `IterateBuffs(unit)` - every helpful aura on the player, whatever its caster.

Both passes share `CheckSelfBuffs` and the same id/name matching, so a greater
blessing or another rank also matches by name ("Blessing of Wisdom"). Seals, auras
and Righteous Fury are self-only in this client, so the wider pass cannot light
those from someone else; only buffs actually on the player light a button, so no
false positives.

Player auras stay readable in combat (only other units are restricted), so this
works during fights as well.

File: `rules/Forever.lua` only. Parse OK, CRLF, no BOM.

## Session 2026-11-16 23:30 - old seal stayed lit after a swap (Fury -> Light)

Report: after switching Seal of Fury -> Seal of Light in combat, *both* stayed lit
(Fury never went dark). The remembered-cast path was fine; the aura cache re-added
the old seal.

Chain:

1. `NoteCast` remembered the new seal and removed every stored seal (Fury dark).
2. `UNIT_AURA` fired; in combat the client kept *reporting the old seal*.
3. The restricted branch merges (`fresh` is added, nothing is removed), so Fury
   came back into the cache and its button lit again until its 30 s ran out.

Fix in `core/AuraTools.lua` - seal identity, not just spell ids:

- `SEAL_IDS` is now id -> seal family (`seal of fury`, `seal of light`, ...), built
  from one list per seal; `NormalizeSealName` + `SealFamily(id, name)` resolve both
  ids and display names, so a different rank or a custom 1.3M-range id of the same
  seal is still the same seal.
- `lastSeal` (id, name, family, expires) is set by `NoteSealCast` from `NoteCast`
  for every successful seal cast (30 s fallback).
- `IsStaleSeal(aura)`: while `lastSeal` is unexpired, a readable aura of a *known,
  different* seal family is stale and is skipped while building `fresh`. Unknown
  ids are never treated as stale (no false negatives); seeing the new seal itself
  refreshes `lastSeal.expires` from the client.
- `DropReplacedSeals(self)` removes cached seals of a replaced family at the start
  of `FullUpdate` for the player, *before* any early return, so a frozen/failed
  read can no longer keep the old seal lit either (the merge only adds).
- `/abaforever auras` prints `last seal cast: id= name= family= left=`.

Files: `core/AuraTools.lua`, `Forever.lua` (probe). Parse OK, CRLF, no BOM.
