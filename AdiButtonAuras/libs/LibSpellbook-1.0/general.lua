local _, ns = ...
ns = ns['__LibSpellbook-1.0']

local lib = ns.lib
if not lib then return end

-- Forever: the spellbook API shape varies between builds. Resolve everything
-- through feature detection and fall back to the numeric enum values, so that
-- a missing Enum or a different signature cannot abort the scan silently.
local _G = _G
local pcall = _G.pcall
local type = _G.type
local tonumber = _G.tonumber

local Enum = _G.Enum or {}
local BookItemType = Enum.SpellBookItemType or {}
local BOOK_SPELL = BookItemType.Spell or 1
local BOOK_FLYOUT = BookItemType.Flyout or 2
local BOOK_PET_ACTION = BookItemType.PetAction or 4
local BookSpellBank = Enum.SpellBookSpellBank or {}
local BANK_PLAYER = BookSpellBank.Player or 0
local BANK_PET = BookSpellBank.Pet or 1

local FoundSpell = ns.FoundSpell
local CleanUp    = ns.CleanUp

local supportedBookTypes = {
	pet      = true,
	pvp      = true,
	spell    = true,
	talent   = true,
}

--- Spell name from the id, never raising (Forever has no C_Spell.GetSpellName
-- on every build).
local function SpellName(id)
	local getter = (_G.ABACompat and _G.ABACompat.GetSpellName)
		or (_G.C_Spell and _G.C_Spell.GetSpellName)
	if type(getter) ~= 'function' or not id then return nil end
	local ok, name = pcall(getter, id)
	return ok and name or nil
end

local function ScanFlyout(flyoutId, bookType)
	local getFlyoutInfo = _G.GetFlyoutInfo
	local getFlyoutSlotInfo = _G.GetFlyoutSlotInfo

	if type(getFlyoutInfo) ~= 'function' or type(getFlyoutSlotInfo) ~= 'function' then
		return false
	end

	local ok, _, _, numSlots, isKnown = pcall(getFlyoutInfo, flyoutId)

	if not ok or not isKnown or not numSlots or numSlots < 1 then return false end

	local changed = false
	for i = 1, numSlots do
		local ok2, _, id, slotKnown, name = pcall(getFlyoutSlotInfo, flyoutId, i)

		if ok2 and slotKnown and id then
			changed = FoundSpell(id, name or SpellName(id), bookType) or changed
		end
	end

	return changed
end

local function ScanPvpTalents()
	local changed = false

	local getTalentInfo = _G.GetPvpTalentInfoByID
	local C_PvP = _G.C_PvP
	local C_SpecializationInfo = _G.C_SpecializationInfo

	if type(getTalentInfo) ~= 'function' then return changed end
	if not (C_PvP and type(C_PvP.IsWarModeDesired) == 'function') then return changed end

	local ok, warMode = pcall(C_PvP.IsWarModeDesired)
	if not ok or not warMode then return changed end

	if not (C_SpecializationInfo and type(C_SpecializationInfo.GetAllSelectedPvpTalentIDs) == 'function') then
		return changed
	end

	local ok2, selectedPvpTalents = pcall(C_SpecializationInfo.GetAllSelectedPvpTalentIDs)
	if not ok2 or type(selectedPvpTalents) ~= 'table' then return changed end

	for _, talentId in next, selectedPvpTalents do
		local ok3, _, name, _, _, _, spellId = pcall(getTalentInfo, talentId)
		if ok3 and spellId then
			changed = FoundSpell(spellId, name, 'pvp') or changed
		end
	end

	return changed
end

--- Read one spellbook slot. Returns itemType, actionId, spellId, name.
-- Handles both the modern struct shape (C_SpellBook.GetSpellBookItemInfo
-- returning a table) and the legacy multi-value shape
-- (GetSpellBookItemInfo returning itemType, actionId).
local function ReadSpellbookItem(index, bookType)
	local C_SpellBook = _G.C_SpellBook
	local getInfo = C_SpellBook and C_SpellBook.GetSpellBookItemInfo

	if type(getInfo) == 'function' then
		local ok, info = pcall(getInfo, index, bookType)
		if ok and type(info) == 'table' then
			return info.itemType, info.actionID, info.spellID, info.name
		end
	end

	local legacy = _G.GetSpellBookItemInfo
	if type(legacy) == 'function' then
		local ok, itemType, actionID = pcall(legacy, index, bookType)
		if ok and itemType then
			return itemType, actionID, actionID
		end
	end
end

local function ScanSpellbook(bookType, numSpells, offset)
	if not numSpells then return false end

	local changed = false
	offset = offset or 0

	for i = offset + 1, offset + numSpells do
		local itemType, actionID, spellID, name = ReadSpellbookItem(i, bookType)
		if not itemType then break end

		if itemType == BOOK_SPELL or itemType == 'SPELL' then
			local id = spellID or actionID
			if id then
				changed = FoundSpell(id, name or SpellName(id), bookType) or changed

				if (spellID and actionID and spellID ~= actionID) then
					changed = FoundSpell(spellID, SpellName(spellID), bookType) or changed
				end
			end
		elseif itemType == BOOK_FLYOUT or itemType == 'FLYOUT' then
			changed = ScanFlyout(actionID, bookType) or changed
		elseif itemType == BOOK_PET_ACTION or itemType == 'PETACTION' then
			local id = spellID or actionID
			if id then
				changed = FoundSpell(id, name or SpellName(id), bookType) or changed
			end
		else
			break
		end
	end

	return changed
end

local function ScanSpells(event)
	local changed = false
	ns.generation = ns.generation + 1

	local C_SpellBook = _G.C_SpellBook
	local getNumSkillLines = C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines
	local getSkillLineInfo = C_SpellBook and C_SpellBook.GetSpellBookSkillLineInfo

	if type(getNumSkillLines) == 'function' and type(getSkillLineInfo) == 'function' then
		local ok, numSkillLines = pcall(getNumSkillLines)
		numSkillLines = ok and tonumber(numSkillLines) or 0

		for skillLine = 1, numSkillLines do
			local ok2, skillLineInfo = pcall(getSkillLineInfo, skillLine)

			if ok2 and type(skillLineInfo) == 'table' and not skillLineInfo.offspecID then
				changed = ScanSpellbook(BANK_PLAYER, skillLineInfo.numSpellBookItems, skillLineInfo.itemIndexOffset) or changed
			end
		end
	end

	local hasPetSpells = C_SpellBook and C_SpellBook.HasPetSpells
	if type(hasPetSpells) == 'function' then
		local ok3, numPetSpells = pcall(hasPetSpells)
		if ok3 and numPetSpells then
			changed = ScanSpellbook(BANK_PET, numPetSpells) or changed
		end
	end

	local inCombat = _G.InCombatLockdown and _G.InCombatLockdown()

	changed = ScanPvpTalents() or changed

	local current = ns.generation
	for id, generation in next, ns.spells.lastSeen do
		if generation < current then
			local bookType = ns.spells.book[id]
			if supportedBookTypes[bookType] and (not inCombat or bookType ~= 'talent') then
				CleanUp(id)
				changed = true
			end
		end
	end

	-- Forever: when the spellbook cannot be read at all, still tell the addon
	-- that "something changed", otherwise no rule is ever registered and the
	-- addon fails silently. LibSpellbook:IsKnown has its own fallback.
	if not changed and not next(ns.spells.byId) then
		changed = true
	end

	if changed then
		lib.callbacks:Fire('LibSpellbook_Spells_Changed')
	end

	if event == 'PLAYER_ENTERING_WORLD' then
		lib:UnregisterEvent(event, ScanSpells)
	end
end

lib:RegisterEvent('PLAYER_ENTERING_WORLD', ScanSpells)
lib:RegisterEvent('PVP_TIMER_UPDATE', ScanSpells, true)
lib:RegisterEvent('SPELLS_CHANGED', ScanSpells)
