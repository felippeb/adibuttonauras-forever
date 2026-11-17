--[[
AdiButtonAuras - Display auras on action buttons.
Forever paladin rules.

The bundled LibPlayerSpells data describes a retail paladin (Holy Power,
Crusader Strike, ...), while this client runs a Wrath-era paladin. These rules
cover what this spellbook actually has: seals, blessings, auras, Righteous
Fury and Judgement.

Display policy: a button is lit only while the aura is actually on the player
(green border + remaining time). Buttons of inactive buffs stay neutral.
Missing-buff reminders are left to the addon's own per-spell "missing" setting,
which is off by default; no rule reports an aura as missing on its own, so a
restricted (combat) read can never produce a false negative.
--]]

local _, addon = ...

if not addon.isClass('PALADIN') then return end

AdiButtonAuras:RegisterRules(function()
	Debug('Rules', 'Adding Forever paladin rules')

	----------------------------------------------------------------------
	-- Spell groups
	----------------------------------------------------------------------
	-- One group per  spell type, across all of its ranks: the client applies a
	-- buff whose id is one of the ranks, so any of them means "this is up".
	local sealRighteousness = { 21084, 20287, 20288, 20289, 20290, 20291, 20292, 20293 }
	local sealCrusader      = { 21082, 20162, 20305, 20306, 20307, 20308 }
	local sealJustice       = { 20164 }
	local sealLight         = { 20165, 20347, 20348, 20349 }
	local sealWisdom        = { 20166, 20356, 20357 }
	local sealCommand       = { 20375, 20915, 20918, 20919, 20920 }
	local sealFury          = { 20163, 20419, 1311649, 1311656 }

	local auraDevotion      = { 465, 643, 1032, 10290, 10291, 10292, 10293, 10294, 10295, 10296 }
	local auraRetribution   = { 7294, 10298, 10299, 10300, 10301, 10302 }
	local auraConcentration = { 19746 }
	local auraShadow        = { 19876, 19895, 19896 }
	local auraFrost         = { 19888, 19897, 19898 }
	local auraFire          = { 19891, 19899, 19900 }

	local blessingMight      = { 19740, 19834, 19835, 19836, 19837, 19838, 25291 }
	local blessingWisdom     = { 19742, 19850, 19852, 19853, 19854, 25290 }
	local blessingKings      = { 20217 }
	local blessingProtection = { 1022, 5599, 10278 }
	local blessingFreedom    = { 1044 }

	local function ToSet(list)
		local set = {}
		for _, id in ipairs(list) do
			set[id] = true
		end
		return set
	end

	-- Forever: custom spells use 1.3M-range ids and the aura the client puts
	-- on the player does not always use the spellbook id. Every rule group
	-- therefore also matches the aura's *name* (as shown by the default UI).
	local function NormalizeName(name)
		if type(name) ~= 'string' then return nil end
		return (name:gsub('^%s+', ''):gsub('%s+$', ''):lower())
	end

	local function ToNameSet(list)
		local names = {}
		for _, id in ipairs(list) do
			local ok, name = pcall(GetSpellName, id)
			if ok and NormalizeName(name) then
				names[NormalizeName(name)] = true
			end
		end
		return names
	end

	----------------------------------------------------------------------
	-- Handler: lit while the buff is up, with its remaining time.
	----------------------------------------------------------------------
	local function CheckSelfBuffs(unit, model, tracked, names, now, iterate)
		for _, spell, stacks, expiration, _, auraName in iterate(unit) do
			local match = tracked[spell]
			if not match and auraName then
				-- A secret name must never raise here: treat it as no match.
				local ok, found = pcall(function()
					local key = NormalizeName(auraName)
					return key and names[key]
				end)
				match = ok and found
			end
			if match then
				-- Only an active aura lights the button. A frozen cache entry
				-- keeps its last known absolute expiration, so an aura that
				-- ran out mid-combat stops lighting up on time.
				local remaining = (expiration and expiration > 0) and (expiration - now) or nil
				if not remaining or remaining > 0 then
					model.highlight = "good"
					if stacks and stacks > 1 then
						model.count = stacks
					end
					if expiration and expiration > 0 then
						model.expiration = expiration
					end
					return true
				end
			end
		end
	end

	local function BuildSelfBuffHandler(spells)
		local tracked = ToSet(spells)
		local names = ToNameSet(spells)

		return function(units, model)
			local unit = units.player
			if not unit or unit == "" then return end

			local now = GetTime()

			-- First the auras we applied ourselves: this is also where a seal
			-- cast in combat is remembered.
			if CheckSelfBuffs(unit, model, tracked, names, now, IteratePlayerBuffs) then
				return true
			end

			-- Then every helpful aura on the player, caster aside: another
			-- paladin's Blessing of Wisdom lights our Blessing of Wisdom button
			-- too, which is what the default UI shows.
			return CheckSelfBuffs(unit, model, tracked, names, now, IterateBuffs)
		end
	end

	local function SelfBuffRule(key, desc, spells)
		-- The sandboxed Configure takes a single table argument.
		return Configure { key, desc, spells, "player", "UNIT_AURA",
			BuildSelfBuffHandler(spells) }
	end

	local rules = {
		------------------------------------------------------------------
		-- Seals
		------------------------------------------------------------------
		SelfBuffRule("ForeverSealRighteousness",
			L["Show Seal of Righteousness's remaining duration while it is active."],
			sealRighteousness),
		SelfBuffRule("ForeverSealCrusader",
			L["Show Seal of the Crusader's remaining duration while it is active."],
			sealCrusader),
		SelfBuffRule("ForeverSealJustice",
			L["Show Seal of Justice's remaining duration while it is active."],
			sealJustice),
		SelfBuffRule("ForeverSealCommand",
			L["Show Seal of Command's remaining duration while it is active."],
			sealCommand),
		SelfBuffRule("ForeverSealLight",
			L["Show Seal of Light's remaining duration while it is active."],
			sealLight),
		SelfBuffRule("ForeverSealWisdom",
			L["Show Seal of Wisdom's remaining duration while it is active."],
			sealWisdom),
		SelfBuffRule("ForeverSealFury",
			L["Show Seal of Fury's remaining duration while it is active."],
			sealFury),

		------------------------------------------------------------------
		-- Blessings
		------------------------------------------------------------------
		SelfBuffRule("ForeverBlessingMight",
			L["Show the remaining duration of Blessing of Might while it is active."],
			blessingMight),
		SelfBuffRule("ForeverBlessingWisdom",
			L["Show the remaining duration of Blessing of Wisdom while it is active."],
			blessingWisdom),
		SelfBuffRule("ForeverBlessingKings",
			L["Show the remaining duration of Blessing of Kings while it is active."],
			blessingKings),
		SelfBuffRule("ForeverBlessingProtection",
			L["Show the remaining duration of Blessing of Protection while it is active."],
			blessingProtection),
		SelfBuffRule("ForeverBlessingFreedom",
			L["Show the remaining duration of Blessing of Freedom while it is active."],
			blessingFreedom),

		------------------------------------------------------------------
		-- Auras (all on the same bar slot family: only the active one shows)
		------------------------------------------------------------------
		SelfBuffRule("ForeverAuraDevotion",
			L["Show Devotion Aura's remaining duration while it is active."],
			auraDevotion),
		SelfBuffRule("ForeverAuraRetribution",
			L["Show Retribution Aura's remaining duration while it is active."],
			auraRetribution),
		SelfBuffRule("ForeverAuraConcentration",
			L["Show Concentration Aura's remaining duration while it is active."],
			auraConcentration),
		SelfBuffRule("ForeverAuraShadowResistance",
			L["Show the remaining duration of Shadow Resistance Aura while it is active."],
			auraShadow),
		SelfBuffRule("ForeverAuraFrostResistance",
			L["Show the remaining duration of Frost Resistance Aura while it is active."],
			auraFrost),
		SelfBuffRule("ForeverAuraFireResistance",
			L["Show the remaining duration of Fire Resistance Aura while it is active."],
			auraFire),

		------------------------------------------------------------------
		-- Self buffs
		------------------------------------------------------------------
		SelfBuffRule("ForeverRighteousFury",
			L["Show when Righteous Fury is active."],
			{ 25780 }),
	}

	------------------------------------------------------------------
	-- Target debuffs (Judgement, Consecration): intentionally NOT tracked.
	--
	-- On this client enemy auras are unreadable by addons while in combat:
	-- C_UnitAuras.GetAuraSlots() returns nothing and GetAuraDataByIndex()
	-- returns nothing for every non-player unit (verified: "enumeration
	-- blocked" for both HELPFUL and HARMFUL). The default UI still shows the
	-- debuffs because it is privileged.
	--
	-- The only way left would be to remember our own casts, but the result
	-- cannot be trusted: a Judgement debuff depends on the active seal, the
	-- countdown is a guess, switching targets or another paladin judging would
	-- make it wrong, and Consecration cannot be remembered at all because the
	-- target can walk out of the area. Showing nothing is better than lighting
	-- a button on stale or false information, so no target-debuff rules are
	-- registered. Self-buff auras above are read live and stay accurate.
	------------------------------------------------------------------

	return rules
end)
