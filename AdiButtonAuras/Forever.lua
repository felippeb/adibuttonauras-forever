--[[
AdiButtonAuras - "WoW: Forever" compatibility layer
Client: _forever_ flavor (product flavor "wowf"), Interface 16001.

Loaded first from AdiButtonAuras.toc, before the embedded libraries, so that
every file can resolve spell and aura API by feature detection instead of
assuming the retail call exists.

Two rules enforced here:
  * a missing call returns nil ("unknown") instead of raising an error;
  * a restricted (secret) answer is reported as "unknown", never as "missing",
    so combat cannot produce false highlights.
--]]

local _G = _G
local pcall = _G.pcall
local rawget = _G.rawget
local select = _G.select
local table = _G.table
local format = _G.string.format
local tonumber = _G.tonumber
local tostring = _G.tostring
local type = _G.type

local addonName, addon = ...

local C = {}
_G.ABACompat = C

local C_Spell = _G.C_Spell
local C_UnitAuras = _G.C_UnitAuras
local C_Secrets = _G.C_Secrets

C.addonName = addonName
C.isForever = true
C.interface = select(4, _G.GetBuildInfo())
C.clientBuild = select(2, _G.GetBuildInfo())

------------------------------------------------------------------------------
-- Secret values
------------------------------------------------------------------------------

local issecret = _G.issecretvalue
if type(issecret) ~= "function" then
	issecret = nil
end

--- True if the client marks this value as unreadable (secret) for addons.
function C.IsSecret(value)
	if issecret == nil or value == nil then return false end
	local ok, secret = pcall(issecret, value)
	return ok and secret and true or false
end

--- Read one field of an aura (or any) table without ever raising.
-- Returns `default` when the field is missing, restricted or unreadable.
function C.Field(data, key, default)
	if type(data) ~= "table" then return default end
	local ok, value = pcall(rawget, data, key)
	if not ok or value == nil then return default end
	if C.IsSecret(value) then return default end
	return value
end

--- True while the client hides aura data from addons.
function C.Restricted()
	local ok, inCombat = pcall(_G.InCombatLockdown)
	if ok and inCombat then return true end
	if C_Secrets and type(C_Secrets.ShouldAurasBeSecret) == "function" then
		local ok2, secret = pcall(C_Secrets.ShouldAurasBeSecret)
		if ok2 and not C.IsSecret(secret) and secret then return true end
	end
	return false
end

------------------------------------------------------------------------------
-- Spells
------------------------------------------------------------------------------

local function ValidSpell(spell)
	local t = type(spell)
	if t == "number" then return spell > 0 end
	if t == "string" then return spell ~= "" end
	return false
end
C.ValidSpell = ValidSpell

--- Modern spell table (C_Spell.GetSpellInfo shape), or nil.
function C.GetSpellInfoTable(spell)
	if not ValidSpell(spell) then return end
	if C_Spell and type(C_Spell.GetSpellInfo) == "function" then
		local ok, info = pcall(C_Spell.GetSpellInfo, spell)
		if ok and type(info) == "table" then
			return info
		end
	end
	local legacy = _G.GetSpellInfo
	if type(legacy) == "function" then
		local ok, name, rank, icon, castTime, minRange, maxRange, spellID, originalIcon = pcall(legacy, spell)
		if ok and name then
			return {
				name = name,
				rank = rank,
				iconID = icon,
				castTime = castTime,
				minRange = minRange,
				maxRange = maxRange,
				spellID = spellID or spell,
				originalIconID = originalIcon,
			}
		end
	end
end

--- Legacy shape: name, rank, icon, castTime, minRange, maxRange, spellID, originalIcon
function C.GetSpellInfo(spell)
	local info = C.GetSpellInfoTable(spell)
	if info then
		return info.name, info.rank, info.iconID, info.castTime,
			info.minRange, info.maxRange, info.spellID, info.originalIconID
	end
end

function C.GetSpellName(spell)
	local info = C.GetSpellInfoTable(spell)
	return info and info.name
end

function C.GetSpellTexture(spell)
	local info = C.GetSpellInfoTable(spell)
	return info and info.iconID
end

function C.GetSpellLink(spell)
	if not ValidSpell(spell) then return end
	if C_Spell and type(C_Spell.GetSpellLink) == "function" then
		local ok, link = pcall(C_Spell.GetSpellLink, spell)
		if ok and link then return link end
	end
	local legacy = _G.GetSpellLink
	if type(legacy) == "function" then
		local ok, link = pcall(legacy, spell)
		if ok then return link end
	end
end

------------------------------------------------------------------------------
-- Items
--
-- This client dropped the legacy item globals; the same calls live in C_Item.
-- Re-expose them under the old names so libraries keep working.
------------------------------------------------------------------------------

local function Resolve(namespace, name)
	local direct = _G[name]
	if type(direct) == "function" then return direct end
	local ns = _G[namespace]
	if ns and type(ns[name]) == "function" then
		return function(...) return ns[name](...) end
	end
end

local function ItemFunc(name)
	local func = Resolve("C_Item", name)
	if func and _G[name] == nil then
		_G[name] = func
	end
	return func
end

C.GetItemInfo = ItemFunc("GetItemInfo")
C.GetItemSpell = ItemFunc("GetItemSpell")
C.GetItemCount = ItemFunc("GetItemCount")
C.GetItemIcon = ItemFunc("GetItemIcon")
C.GetItemQualityColor = ItemFunc("GetItemQualityColor")

------------------------------------------------------------------------------
-- Item use classification
--
-- Blizzard's IsHarmfulItem/IsHelpfulItem are Lua helpers that this client does
-- not have. They only decide whether an item rule targets "player" or "ally",
-- so the safe defaults are "helpful".
------------------------------------------------------------------------------

function C.IsHarmfulItem(item)
	local func = _G.IsHarmfulItem
	if type(func) == "function" then
		local ok, value = pcall(func, item)
		if ok then return value and true or false end
	end
	return false
end

function C.IsHelpfulItem(item)
	local func = _G.IsHelpfulItem
	if type(func) == "function" then
		local ok, value = pcall(func, item)
		if ok then return value and true or false end
	end
	return true
end

------------------------------------------------------------------------------
-- Auras
--
-- Preferred: the slot API (GetAuraSlots/GetAuraDataBySlot). This client has it,
-- but the index API is used as a fallback so the addon still works if a build
-- only exposes GetAuraDataByIndex.
------------------------------------------------------------------------------

local auraFilterByUnit = {}
local auraMethodByUnit = {}

--- Enumerate by legacy index. This is the path the default UI and PallyPower
-- use on this client, and it is proven for other units (party/raid/target).
local function ScanByIndex(unit, filter)
	if not (C_UnitAuras and type(C_UnitAuras.GetAuraDataByIndex) == "function") then return end
	auraFilterByUnit[unit] = filter
	auraMethodByUnit[unit] = "index"
	local slots = { 0 } -- index 1 is the continuation token in the slot API
	for index = 1, 64 do
		local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, filter)
		if not ok then return end
		if not data then break end
		slots[#slots + 1] = index
	end
	return slots
end

--- Raw aura enumeration (slot list). Returns nil when restricted or missing.
function C.GetAuraSlots(unit, filter)
	-- Forever: the slot API only proved reliable for the player. For every other
	-- unit the index API is what the default UI uses, so prefer it there.
	if unit ~= "player" then
		local slots = ScanByIndex(unit, filter)
		if slots then return slots end
	end

	if C_UnitAuras and type(C_UnitAuras.GetAuraSlots) == "function" then
		local ok, slots = pcall(function() return { C_UnitAuras.GetAuraSlots(unit, filter) } end)
		if ok then
			auraFilterByUnit[unit] = filter
			auraMethodByUnit[unit] = "slots"
			return slots
		end
		return -- restricted: the caller keeps its last known state
	end

	return ScanByIndex(unit, filter)
end

function C.GetAuraDataBySlot(unit, slot)
	if auraMethodByUnit[unit] ~= "index"
		and C_UnitAuras and type(C_UnitAuras.GetAuraDataBySlot) == "function" then
		local ok, data = pcall(C_UnitAuras.GetAuraDataBySlot, unit, slot)
		if ok then return data end
		return
	end
	if C_UnitAuras and type(C_UnitAuras.GetAuraDataByIndex) == "function" then
		local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, slot, auraFilterByUnit[unit])
		if ok then return data end
	end
end

function C.GetAuraDataByInstanceID(unit, instanceID)
	if not (C_UnitAuras and type(C_UnitAuras.GetAuraDataByAuraInstanceID) == "function") then return end
	local ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, instanceID)
	if ok then return data end
end

--- true / false, or nil when the answer itself is hidden.
function C.IsAuraFilteredOut(unit, instanceID, filter)
	if instanceID == nil then return false end
	if not (C_UnitAuras and type(C_UnitAuras.IsAuraFilteredOutByInstanceID) == "function") then return false end
	local ok, filtered = pcall(C_UnitAuras.IsAuraFilteredOutByInstanceID, unit, instanceID, filter)
	if not ok or C.IsSecret(filtered) then return nil end
	return filtered and true or false
end

------------------------------------------------------------------------------
-- Action buttons
------------------------------------------------------------------------------

--- GetActionCooldown returns start, duration on legacy builds and a table on
-- newer ones. Normalize to the legacy shape.
function C.NormalizeCooldown(a, b)
	if type(a) == "table" then
		return C.Field(a, "startTime"), C.Field(a, "duration")
	end
	if C.IsSecret(a) or C.IsSecret(b) then return end
	return a, b
end

------------------------------------------------------------------------------
-- /abaforever: print what this client actually exposes
------------------------------------------------------------------------------

local function Record(line)
	-- Mirror into SavedVariables so the log can be read from disk after a
	-- /reload (no chat copy/paste needed).
	local probe = _G.ABAForeverProbe
	if type(probe) ~= "table" then
		probe = {}
		_G.ABAForeverProbe = probe
	end
	if #probe >= 4000 then
		table.remove(probe, 1)
	end
	probe[#probe + 1] = line
end

local function Out(...)
	local parts = {}
	for i = 1, select("#", ...) do
		local ok, value = pcall(tostring, (select(i, ...)))
		parts[#parts + 1] = ok and value or "<secret>"
	end
	local line = table.concat(parts, " ")
	print("|cff33ff99ABA-Forever|r", line)
	Record(line)
end

local function OutQuiet(...)
	local parts = {}
	for i = 1, select("#", ...) do
		local ok, value = pcall(tostring, (select(i, ...)))
		parts[#parts + 1] = ok and value or "<secret>"
	end
	Record(table.concat(parts, " "))
end

local function JoinSet(set)
	if not set then return "?" end
	local list = {}
	for value in pairs(set) do
		list[#list + 1] = tostring(value)
	end
	table.sort(list)
	return table.concat(list, ",")
end

local function Presence(namespace, names)
	local ns = _G[namespace]
	local have, missing = {}, {}
	for _, name in ipairs(names) do
		if ns and type(ns[name]) == "function" then
			have[#have + 1] = name
		else
			missing[#missing + 1] = name
		end
	end
	Out(namespace .. ":", #have .. "/" .. #names .. " present")
	if #missing > 0 then Out("  missing:", table.concat(missing, ", ")) end
end

------------------------------------------------------------------------------
-- Lua error capture
--
-- The release bundle ships BugGrabber, which replaces the Lua error handler: it
-- prints one red chat line per error and keeps the stack out of the client log.
-- That hides exactly what is needed while porting, so:
--   * the toc no longer loads it (restart to take effect);
--   * if it is still loaded, the pre-BugGrabber handler is restored at
--     PLAYER_LOGIN, so errors show and are logged again;
--   * whatever handler ends up active is wrapped so each error is also copied
--     into ABAForeverProbe, which reaches the disk on /reload.
------------------------------------------------------------------------------

local earlyErrorHandler = _G.geterrorhandler and _G.geterrorhandler() or nil

local function RecordError(message)
	local ok, text = pcall(tostring, message)
	Record("ERROR: " .. (ok and text or "<unprintable error>"))
end

local function InstallErrorCapture()
	if type(_G.seterrorhandler) ~= "function" then return end

	if _G.date then
		pcall(RecordError, "=== capture installed @ " .. tostring(_G.date("%Y-%m-%d %H:%M:%S")))
	end

	local current = _G.geterrorhandler and _G.geterrorhandler() or nil
	local base = earlyErrorHandler or current
	local hadBugGrabber = (_G.BugGrabber or (addon and addon.BugGrabber)) and true or false

	pcall(_G.seterrorhandler, function(message)
		pcall(RecordError, message)
		if base then pcall(base, message) end
	end)

	if hadBugGrabber then
		Out("BugGrabber handler replaced; Lua errors now show and are logged again")
	end
end

if _G.CreateFrame then
	local errorFrame = _G.CreateFrame("Frame")
	errorFrame:RegisterEvent("PLAYER_LOGIN")
	errorFrame:SetScript("OnEvent", function(self)
		self:UnregisterEvent("PLAYER_LOGIN")
		InstallErrorCapture()
	end)
end

-- Also install right now, so errors raised by later addons during ADDON_LOADED
-- are recorded too (BugGrabber, when present, overrides this a moment later and
-- the PLAYER_LOGIN pass above takes the handler back).
InstallErrorCapture()

_G.SLASH_ABAFOREVER1 = "/abaforever"
_G.SlashCmdList["ABAFOREVER"] = function(msg)
	msg = type(msg) == "string" and msg:lower() or ""

	local clock = _G.date and _G.date("%H:%M:%S") or "?"
	local inCombat = _G.InCombatLockdown and _G.InCombatLockdown()
	Out("=== /abaforever " .. (msg ~= "" and msg or "probe") .. " @ " .. tostring(clock)
		.. " inCombat=" .. tostring(inCombat))

	if msg:find("button") then
		local slots = tonumber(msg:match("(%d+)")) or 120
		local getActionInfo = _G.GetActionInfo
		if type(getActionInfo) ~= "function" then
			Out("GetActionInfo missing")
			return
		end

		Out("=== action buttons 1.." .. slots,
			"NUM_ACTIONBAR_BUTTONS =", tostring(_G.NUM_ACTIONBAR_BUTTONS))

		local found = 0
		for slot = 1, slots do
			local ok, actionType, id = pcall(getActionInfo, slot)
			if ok and actionType and actionType ~= "empty" then
				found = found + 1
				local key = actionType .. ":" .. tostring(id)
				local rule = addon.rules and addon.rules[key]
				local enabled = addon.db and addon.db.profile.enabled[key]
				local button = _G["ActionButton" .. slot]
				local overlay = button and addon.GetOverlay and addon:GetOverlay(button)
				local name = ""
				if actionType == "spell" then
					name = C.GetSpellName(id) or ""
				elseif actionType == "item" then
					local itemName = C.GetItemInfo and C.GetItemInfo(id)
					name = itemName or ""
				end
				local herrs = 0
				if overlay and overlay.__handlerErrors then
					for _ in pairs(overlay.__handlerErrors) do herrs = herrs + 1 end
				end
				OutQuiet(format("slot %3d %-7s %-6s %-24s rule=%-3s enabled=%-5s ov=%-3s spellId=%-6s shown=%-5s handlers=%-3s hl=%-5s hlShown=%-5s flash=%-5s hint=%-5s herrs=%-2s exp=%s",
					slot, tostring(actionType), tostring(id), tostring(name):sub(1, 24),
					rule and "yes" or "-", tostring(enabled), overlay and "yes" or "-",
					tostring(overlay and overlay.spellId),
					tostring(overlay and overlay.IsShown and overlay:IsShown()),
					tostring(overlay and overlay.handlers and #overlay.handlers),
					tostring(overlay and overlay.highlight),
					tostring(overlay and overlay.Highlight and overlay.Highlight.IsShown and overlay.Highlight:IsShown()),
					tostring(overlay and overlay.flash),
					tostring(overlay and overlay.hint),
					tostring(herrs),
					tostring(overlay and overlay.expiration)))
			end
		end
		Out(found, "non-empty action slots; details saved, /reload to flush")
		return
	end

	if msg:find("rule") then
		local keys = {}
		for key in pairs(addon.rules or {}) do
			if type(key) == "string" then keys[#keys + 1] = key end
		end
		table.sort(keys)

		Out("=== registered rules:", #keys)
		for _, key in ipairs(keys) do
			local rule = addon.rules[key]
			OutQuiet(format("%-26s | %-34s | units=%s | events=%s",
				key,
				tostring(addon.descriptions and addon.descriptions[key] or ""):sub(1, 34),
				JoinSet(rule and rule.units),
				JoinSet(rule and rule.events)))
		end
		Out("rule details saved, /reload to flush")
		return
	end

	if msg:find("^auras") then
		-- Live slot dump plus the addon's own cache state. Run out of combat,
		-- then in combat, then after switching seals a few times.
		local unit = msg:match("^auras%s+(%a+)") or "player"
		local now = _G.GetTime and _G.GetTime() or 0
		Out("=== live auras for", unit, "GetTime()=" .. tostring(now),
			"restricted=" .. tostring(C.Restricted()))

		for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
			local slots = C.GetAuraSlots(unit, filter)
			if not slots then
				Out(filter, "enumeration blocked (nil)")
			else
				Out(filter, "slots:", #slots)
				for i = 2, #slots do
					local data = C.GetAuraDataBySlot(unit, slots[i])
					if not data then
						Out("  slot", tostring(slots[i]), "no data")
					else
						local spellId = C.Field(data, "spellId")
						local name = C.Field(data, "name")
						local expiration = C.Field(data, "expirationTime")
						local duration = C.Field(data, "duration")
						local inst = C.Field(data, "auraInstanceID")
						OutQuiet(format("  slot %-4s id=%-6s %-28s left=%-8s dur=%-6s inst=%-12s filtered=%s",
							tostring(slots[i]), tostring(spellId),
							tostring(name):sub(1, 28),
							tostring(expiration and (expiration - now)),
							tostring(duration), tostring(inst),
							tostring(C.IsAuraFilteredOut(unit, inst, filter))))
					end
				end
			end
		end

		local state = addon.AuraTools and addon.AuraTools.DebugState and addon.AuraTools.DebugState(unit)
		if state then
			Out("=== cache state for", unit, "exists=" .. tostring(state.exists))
			local seal = state.lastSeal
			if seal then
				OutQuiet(format("  last seal cast: id=%s name=%s family=%s left=%s",
					tostring(seal.id), tostring(seal.name), tostring(seal.family),
					tostring(seal.left)))
			end
			for _, cacheState in ipairs(state.caches) do
				local last = cacheState.last
				OutQuiet(format("  %-12s count=%-3d retries=%-4s last=%s (%s ago) slots=%s",
					cacheState.key, cacheState.count, tostring(cacheState.retries),
					tostring(last and last.reason), tostring(last and (now - last.t)),
					tostring(last and last.slots)))
				for _, r in ipairs(cacheState.remembered or {}) do
					OutQuiet(format("    remembered id=%-6s name=%-20s left=%s", tostring(r.id),
						tostring(r.name), tostring(r.left)))
				end
			end
		end
		local s = addon.AuraTools and addon.AuraTools.DebugStats and addon.AuraTools.DebugStats()
		if s then
			local last = s.lastFrozen
			Out("=== event stats: UNIT_AURA=" .. tostring(s.events.UNIT_AURA),
				"REGEN=" .. tostring(s.events.PLAYER_REGEN_ENABLED),
				"full=" .. tostring(s.full),
				"frozen=" .. tostring(s.frozen),
				"retries=" .. tostring(s.retries),
				"lastFrozen=" .. tostring(last and last.reason),
				"lastFrozenAgo=" .. tostring(last and (now - last.t)))
		end
		Out("live aura dump saved, /reload to flush")
		return
	end

	if msg:find("^aura") then
		local id = tonumber(msg:match("(%d+)"))
		if not id then
			Out("usage: /abaforever aura <spellId>")
			return
		end
		local found, count, expiration = addon.AuraTools.GetPlayerBuff("player", id)
		Out("GetPlayerBuff", id, C.GetSpellName(id) or "?",
			"found=" .. tostring(found),
			"count=" .. tostring(count),
			"exp=" .. tostring(expiration),
			"left=" .. tostring(expiration and expiration - (_G.GetTime and _G.GetTime() or 0)))
		return
	end

	if msg:find("^target") then
		local now = _G.GetTime and _G.GetTime() or 0
		Out("GetTime()", tostring(now),
			"target:", tostring(_G.UnitExists("target")), _G.UnitName("target") or "?",
			"harm:", tostring(_G.UnitCanAttack("player", "target")))

		local count = 0
		for instanceId, spellId, stacks, expiration, _, auraName in addon.AuraTools.IterateDebuffs("target") do
			count = count + 1
			local name = C.GetSpellName(spellId)
			Out("  debuff", spellId, name or "?",
				"cachedName", tostring(auraName),
				"secretId", tostring(C.IsSecret(spellId)),
				"secretName", tostring(name ~= nil and C.IsSecret(name)),
				"x" .. tostring(stacks),
				"left", tostring(expiration and expiration - now),
				"inst", tostring(instanceId))
		end
		Out("target debuffs seen:", count)

		local rule = addon.rules and addon.rules["spell:20271"]
		if rule then
			Out("judgement rule: handlers=" .. tostring(rule.handlers and #rule.handlers),
				"keys=" .. tostring(rule.keys and #rule.keys),
				"units=" .. JoinSet(rule.units),
				"events=" .. JoinSet(rule.events))
		else
			Out("judgement rule: NOT REGISTERED")
		end
		return
	end

	if msg:find("^judge") then
		-- Run the registered Judgement handler directly, bypassing the action
		-- bar, to tell a rule bug apart from an overlay/button bug.
		local rule = addon.rules and addon.rules["spell:20271"]
		if not rule or not rule.handlers then
			Out("judgement rule: NOT REGISTERED")
			return
		end
		local enemy = (_G.UnitExists("target") and _G.UnitCanAttack("player", "target")) and "target" or ""
		local units = { enemy = enemy, target = enemy, player = "player" }
		Out("judge: enemy unit =", tostring(enemy), "handlers =", tostring(#rule.handlers))
		for i, handler in ipairs(rule.handlers) do
			local model = {}
			local ok, result = pcall(handler, units, model)
			Out("  handler", i, "ok=" .. tostring(ok),
				"result=" .. tostring(result),
				"highlight=" .. tostring(model.highlight),
				"expiration=" .. tostring(model.expiration),
				"count=" .. tostring(model.count))
		end
		return
	end

	if msg:find("spell") then
		-- Dump every spell the client found in the spellbook: id and name.
		local lib = addon and addon.GetLib and addon.GetLib("LibSpellbook-1.0", true)
		if not lib or not lib:HasSpells() then
			Out("spellbook not scanned yet, try again in a few seconds")
			return
		end
		local count = 0
		for id, name in lib:IterateSpells() do
			count = count + 1
			Out(format("%6d", id), name)
		end
		Out(count, "spells in the spellbook")
		return
	end

	Out("client", C.clientBuild, "interface", C.interface,
		"WOW_PROJECT_ID", tostring(_G.WOW_PROJECT_ID),
		"restricted", tostring(C.Restricted()))
	Out("GetTime()", tostring(_G.GetTime and _G.GetTime()),
		"maxCountdown", tostring(addon.db and addon.db.profile.maxCountdown))
	Presence("C_Spell", { "GetSpellInfo", "GetSpellName", "GetSpellLink", "GetSpellTexture",
		"GetSpellCooldown", "GetSpellCharges", "IsSpellInRange", "IsSpellUsable" })
	Presence("C_UnitAuras", { "GetAuraSlots", "GetAuraDataBySlot", "GetAuraDataByAuraInstanceID",
		"IsAuraFilteredOutByInstanceID", "GetAuraDataByIndex", "GetUnitAuraBySpellID", "GetAuraDuration" })
	Presence("C_Secrets", { "ShouldAurasBeSecret" })
	Out("TooltipDataProcessor:", tostring(_G.TooltipDataProcessor ~= nil),
		"Settings:", tostring(_G.Settings ~= nil),
		"issecretvalue:", tostring(issecret ~= nil))

	-- Auras as the client exposes them right now (run this in combat too).
	for _, unit in ipairs({ "player", "target" }) do
		local slots = C.GetAuraSlots(unit, "HELPFUL")
		if not slots then
			Out(unit, "aura enumeration blocked (nil)")
		else
			local total, readable, hidden = 0, 0, 0
			for i = 2, #slots do
				local data = C.GetAuraDataBySlot(unit, slots[i])
				if data then
					total = total + 1
					if C.Field(data, "spellId") then readable = readable + 1 else hidden = hidden + 1 end
				else
					hidden = hidden + 1
				end
			end
			Out(unit, "auras", total, "readable spell ids", readable, "hidden", hidden)
		end
	end

	-- Spellbook scan diagnostics. Silent failure here means zero rules, so make
	-- the shape visible instead of guessing.
	local LibSpellbook = addon and addon.GetLib and addon.GetLib("LibSpellbook-1.0", true)
	if LibSpellbook then
		local count = 0
		for _ in LibSpellbook:IterateSpells() do count = count + 1 end
		Out("LibSpellbook:", count, "spells", "scanned:", tostring(LibSpellbook:HasSpells()))
	end
	local C_SpellBook = _G.C_SpellBook
	if not C_SpellBook then
		Out("C_SpellBook: absent")
	else
		local ok, lines = pcall(C_SpellBook.GetNumSpellBookSkillLines)
		Out("C_SpellBook skill lines:", ok and tostring(lines) or "error")
		local ok2, line = pcall(C_SpellBook.GetSpellBookSkillLineInfo, 1)
		if ok2 and type(line) == "table" then
			Out("  line 1 items:", tostring(line.numSpellBookItems),
				"offset:", tostring(line.itemIndexOffset),
				"offspec:", tostring(line.offspecID))
			local index = (line.itemIndexOffset or 0) + 1
			local ok3, item = pcall(C_SpellBook.GetSpellBookItemInfo, index, 0)
			if ok3 and type(item) == "table" then
				Out("  item shape: table itemType=" .. tostring(item.itemType)
					.. " actionID=" .. tostring(item.actionID)
					.. " spellID=" .. tostring(item.spellID)
					.. " name=" .. tostring(item.name))
			else
				Out("  item shape:", ok3 and type(item) or "error", tostring(item))
			end
		else
			Out("  skill line 1:", ok2 and type(line) or "error")
		end
	end
	Out("Enum.SpellBookItemType:", tostring(_G.Enum ~= nil and _G.Enum.SpellBookItemType ~= nil),
		"Enum.SpellBookSpellBank:", tostring(_G.Enum ~= nil and _G.Enum.SpellBookSpellBank ~= nil))

	-- How many rules survived the spellbook filter. Zero here means the addon is
	-- running but will never highlight anything.
	if addon and addon.rules then
		local count, forever = 0, 0
		for _, rule in pairs(addon.rules) do
			count = count + 1
			if type(rule) == "table" and rule.keys then
				for _, ruleKey in ipairs(rule.keys) do
					if tostring(ruleKey):find(":Forever", 1, true) then
						forever = forever + 1
						break
					end
				end
			end
		end
		Out("rules registered:", count, "spells with Forever rules:", forever)
	end

	-- What the addon cache currently holds.
	if addon and addon.AuraTools and addon.AuraTools.IteratePlayerBuffs then
		local count = 0
		local ok = pcall(function()
			for instanceId, spellId, count_, expiration, _, cachedName in addon.AuraTools.IteratePlayerBuffs("player") do
				count = count + 1
				if count <= 25 then
					local now = _G.GetTime and _G.GetTime() or 0
					Out("  cache buff", spellId,
						C.GetSpellName(spellId) or "?",
						"cachedName", tostring(cachedName),
						"x" .. tostring(count_),
						"exp", tostring(expiration),
						"left", tostring(expiration and expiration - now),
						"inst", tostring(instanceId))
				end
			end
		end)
		Out("cached player buffs:", count, ok and "" or "(iteration failed)")
	end
end
