--[[
AdiButtonAuras - Display auras on action buttons.
Copyright 2013-2023 Adirelle (adirelle@gmail.com)
All rights reserved.

This file is part of AdiButtonAuras.

AdiButtonAuras is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

AdiButtonAuras is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with AdiButtonAuras. If not, see <http://www.gnu.org/licenses/>.
--]]

local addonName, addon = ...

local _G = _G
-- Forever: every aura read goes through the compat layer, which turns a
-- restricted (secret) answer into nil instead of raising an error.
local Compat = _G.ABACompat
local Field = Compat.Field
local GetAuraSlots = Compat.GetAuraSlots
local GetAuraDataBySlot = Compat.GetAuraDataBySlot
local IsAuraFilteredOut = Compat.IsAuraFilteredOut
local C_Timer = _G.C_Timer
local GetTime = _G.GetTime
local next = _G.next
local pcall = _G.pcall
local rawget = _G.rawget
local setmetatable = _G.setmetatable
local type = _G.type
local UnitExists = _G.UnitExists
local UnitGUID = _G.UnitGUID

local Debug = function(...) addon.Debug('AuraTools', ...) end

-- Forever diagnostics: how often the cache rebuild ran, how often it had to
-- freeze because the client restricted the read, and how often it retried.
local stats = {
	events = { UNIT_AURA = 0, PLAYER_REGEN_ENABLED = 0 },
	full = 0,
	frozen = 0,
	retries = 0,
	lastFrozen = nil,
}

------------------------------------------------------------------------------
-- Table recycling
------------------------------------------------------------------------------

local new, del
do
	local heap = setmetatable({}, { __mode = 'k' })

	function new()
		local t = next(heap)
		if not t then return {} end
		heap[t] = nil
		return t
	end

	function del(t)
		if t then
			heap[t] = true
		end
	end
end

------------------------------------------------------------------------------
-- Prototypes
------------------------------------------------------------------------------

-- Forever: aura fields can be secret in combat. A field that cannot be read is
-- reported as nil (or as the previously known value), never as "expired".
--
-- The duration of every readable aura is remembered here, so a seal or
-- Righteous Fury cast while the client hides auras in combat can still be
-- counted down (see NoteCast).
local durations = {}
local C_UnitAuras = _G.C_UnitAuras

-- Known seal ids, grouped by the seal they belong to: seals replace each other
-- and all last 30 s on this client. Ids alone are not enough (custom 1.3M-range
-- ids exist, and a rank can differ from the aura the client puts on the
-- player), so names are matched too.
local SEAL_IDS = {}
do
	local families = {
		{ 'seal of righteousness', 21084, 20287, 20288, 20289, 20290, 20291, 20292, 20293 },
		{ 'seal of the crusader', 21082, 20162, 20305, 20306, 20307, 20308 },
		{ 'seal of justice', 20164 },
		{ 'seal of light', 20165, 20347, 20348, 20349 },
		{ 'seal of wisdom', 20166, 20356, 20357 },
		{ 'seal of command', 20375, 20915, 20918, 20919, 20920 },
		{ 'seal of fury', 20163, 20419, 1311649, 1311656 },
	}
	for _, family in ipairs(families) do
		for i = 2, #family do
			SEAL_IDS[family[i]] = family[1]
		end
	end
end

local function NormalizeSealName(name)
	if type(name) ~= 'string' then return nil end
	local trimmed = name:gsub('^%s+', ''):gsub('%s+$', '')
	if not trimmed:find('^[Ss]eal of ') then return nil end
	return trimmed:lower()
end

--- The seal a spell/aura belongs to ('seal of fury', ...), or nil if unknown.
local function SealFamily(id, name)
	local fromName = NormalizeSealName(name)
	if fromName then return fromName end
	return id ~= nil and SEAL_IDS[id] or nil
end

local function IsSeal(id, name)
	return SealFamily(id, name) ~= nil
end

-- The last seal we cast: on this client only one seal can be up, but a
-- restricted (combat) read can keep returning the previous one, which used to
-- re-light it after a swap. While the last seal has not expired, any *other*
-- seal read is stale and is ignored.
local lastSeal = nil

local function NoteSealCast(id, name, duration)
	lastSeal = {
		id = id,
		name = name,
		family = SealFamily(id, name),
		expires = GetTime() + (duration or 30),
	}
end

local function IsStaleSeal(aura)
	if not lastSeal or GetTime() >= lastSeal.expires then return false end
	local family = SealFamily(aura.id, aura.name)
	if not family then return false end
	if family == lastSeal.family then
		-- The replacement seal is readable: trust the client's expiration.
		if aura.id == lastSeal.id and aura.expiration and aura.expiration > GetTime() then
			lastSeal.expires = aura.expiration
		end
		return false
	end
	-- Only a known, different seal can be stale. An unrecognised id must never
	-- hide a real aura.
	return lastSeal.family ~= nil
end

--- Remove cached seals that the last cast replaced. The restricted (combat)
--- read can keep reporting them, and the merge below only adds auras, so the
--- old seal would stay lit until its own expiration ran out.
local function DropReplacedSeals(self)
	if not lastSeal or not lastSeal.family or GetTime() >= lastSeal.expires then
		return
	end
	for k, v in next, self do
		if type(k) == 'number' and type(v) == 'table' and not v.__remembered then
			local family = SealFamily(v.id, v.name)
			if family and family ~= lastSeal.family then
				del(v)
				self[k] = nil
			end
		end
	end
end

local function ProcessAura(data, aura, unit)
	local id = Field(data, 'spellId')
	if not id then
		-- The aura exists but cannot be identified: the client is restricting
		-- this read. Do not cache it, and let the caller freeze the cache.
		return
	end

	aura.count = Field(data, 'applications') or 1

	local dispel = Field(data, 'dispelName')
	aura.dispel = (dispel == nil or dispel == '') and 'Enrage' or dispel

	aura.expiration = Field(data, 'expirationTime', aura.expiration) or 0
	aura.id = id
	-- Keep the name too: custom Forever ids resolve fine through GetSpellInfo,
	-- but the name is what the default UI shows, so rules can match on it.
	aura.name = Field(data, 'name')

	local duration = Field(data, 'duration')
	if not duration and C_UnitAuras and type(C_UnitAuras.GetAuraDuration) == 'function' then
		local ok, value = pcall(C_UnitAuras.GetAuraDuration, unit, id)
		if ok and not Compat.IsSecret(value) and type(value) == 'number' then
			duration = value
		end
	end
	if duration and duration > 0 then
		durations[id] = duration
	elseif not durations[id] then
		-- Forever: seals last 30 seconds and the duration field is not always
		-- available, so fall back to the known seal duration before guessing.
		local name = aura.name
		if name == nil then
			name = Compat.GetSpellName and Compat.GetSpellName(id)
		end
		if name and Compat.IsSecret(name) then name = nil end
		if IsSeal(id, name) then
			durations[id] = 30
		elseif aura.expiration > GetTime() + 30 then
			durations[id] = aura.expiration - GetTime()
		end
	end

	return aura
end

-- Forever: remembered casts (auras the client hides in combat) live under a key
-- range that cannot collide with aura instance IDs.
local REMEMBERED_BASE = -100000

local function RememberedKey(id)
	return REMEMBERED_BASE - id
end

local aurasMetatable = {
	__index = {
		CheckGUID = function (self)
			if self.__guid ~= UnitGUID(self.__unit) then
				self:Update()
			end

			return self
		end,
		Update = function (self, info, isRetry)
			self.__guid = UnitGUID(self.__unit)

			if not self.__guid then
				for k, v in next, self do
					if type(k) == 'number' then
						del(v)
						self[k] = nil
					end
				end

				return
			end

			self:FullUpdate(self.__unit, self.__filter, isRetry)
		end,
		-- Forever: always rebuild from the slot enumeration. Incremental updates
		-- rely on aura instance IDs, which can be unreadable in combat.
		FullUpdate = function (self, unit, filter, isRetry)
			local restricted = Compat.Restricted and Compat.Restricted() or false

			-- The seal we last cast replaced every other seal on the player.
			-- Drop those even if the read below fails, otherwise the old seal
			-- stays lit until its own expiration (the merge only adds auras).
			if unit == 'player' then
				DropReplacedSeals(self)
			end

			local slots = GetAuraSlots(unit, filter)

			if not slots then
				-- Enumeration is blocked right now: keep the last known state so
				-- tracked auras are not reported as missing.
				self.__last = { t = GetTime(), reason = "no slots", count = 0 }
				stats.frozen = stats.frozen + 1
				stats.lastFrozen = self.__last
				return
			end

			-- Forever: in combat the client can return an empty slot list even
			-- though buffs are up. An empty answer while reads are restricted
			-- means "unknown", not "no auras". Wiping here darkened every
			-- tracked buff after a few seal switches.
			if restricted and #slots <= 1 then
				self.__last = { t = GetTime(), reason = "empty while restricted", count = 0, slots = #slots }
				stats.frozen = stats.frozen + 1
				stats.lastFrozen = self.__last
				return
			end

			local fresh = {}
			local complete = true
			local reason

			for i = 2, #slots do
				local data = GetAuraDataBySlot(unit, slots[i])

				if not data then
					reason = "no data at slot "..tostring(slots[i])
					complete = false
					break
				end

				local instanceID = Field(data, 'auraInstanceID')
				local filtered = IsAuraFilteredOut(unit, instanceID, filter)

				if filtered == nil then
					reason = "filtered unknown at slot "..tostring(slots[i])
					complete = false
					break
				end

				if not filtered then
					local aura = ProcessAura(data, new(), unit)

					if not aura then
						reason = "unreadable spell id at slot "..tostring(slots[i])
						complete = false
						break
					end

					if IsStaleSeal(aura) then
						-- The client still reports the seal this cast replaced:
						-- skip it instead of re-adding it to the cache.
						del(aura)
					else
						fresh[#fresh + 1] = { key = instanceID, aura = aura }
					end
				end
			end

			if not complete then
				-- Restricted answer: drop what was read and keep the old cache.
				for _, entry in next, fresh do
					del(entry.aura)
				end

				self.__last = { t = GetTime(), reason = reason or "incomplete", count = 0, slots = #slots }
				stats.frozen = stats.frozen + 1
				stats.lastFrozen = self.__last

				-- An aura refreshed between the slot list and the data fetch makes
				-- the read incomplete. That used to freeze the cache until the
				-- next event; retry a few times out of combat instead.
				if not restricted and C_Timer then
					if not isRetry then
						self.__retries = 0
					end
					self.__retries = (self.__retries or 0) + 1
					stats.retries = stats.retries + 1
					if self.__retries <= 3 then
						C_Timer.After(0.25, function() self:Update(nil, true) end)
					end
				end

				return
			end

			self.__retries = nil
			stats.full = stats.full + 1

			if restricted then
				-- Merge instead of replacing: the client may hide the active seal
				-- (or Righteous Fury) while still reporting the other buffs.
				-- Absent auras keep their last known expiration, and once that
				-- expires the display goes dark on its own.
				for _, entry in next, fresh do
					local key = entry.key
					if type(key) ~= 'number' then key = -entry.aura.id end
					-- Once the real aura is readable, a remembered cast is stale.
					self[RememberedKey(entry.aura.id)] = nil
					local old = self[key]
					if old and old ~= entry.aura then del(old) end
					self[key] = entry.aura
				end
				self.__last = { t = GetTime(), reason = "ok (merge)", count = #fresh, slots = #slots }
			else
				-- Out of combat the client is authoritative: replace everything,
				-- which also drops remembered casts.
				self.__last = { t = GetTime(), reason = "ok", count = #fresh, slots = #slots }
				for k, v in next, self do
					if type(k) == 'number' then
						del(v)
						self[k] = nil
					end
				end

				for _, entry in next, fresh do
					local key = entry.key
					if type(key) ~= 'number' then key = -entry.aura.id end
					self[key] = entry.aura
				end
			end
		end,
		GetById = function (self, id)
			for k, v in next, self do
				if type(k) == 'number' and v.id == id then
					return v
				end
			end
		end,
	}
}

local function UpdateUnit(self, info)
	-- print('Called UpdateUnit for', self.__unit, nil ~= info, info.isFullUpdate)
	for _, auras in next, self do
		if type(auras) == 'table' then
			auras:Update(info)
		end
	end
end

local mts = {
	PlayerBuff = {
		filter = 'HELPFUL PLAYER',
		metatable = aurasMetatable
	},
	PlayerDebuff = {
		filter = 'HARMFUL PLAYER',
		metatable = aurasMetatable
	},
	Buff = {
		filter = 'HELPFUL',
		metatable = aurasMetatable
	},
	Debuff = {
		filter = 'HARMFUL',
		metatable = aurasMetatable
	},
}

local unitMetatable = {
	__index = function(self, key)
		if key == 'Update' then
			return UpdateUnit
		elseif key and mts[key] then
			Debug('Spawning', key, 'cache for', self.__unit)
			local auras = setmetatable(
				{
					__unit = self.__unit,
					__filter = mts[key].filter,
				},
				mts[key].metatable
			)
			auras:Update()
			self[key] = auras
			return auras
		end
	end
}

------------------------------------------------------------------------------
-- The cache and its updater
------------------------------------------------------------------------------

local cache = setmetatable({}, {
	__index = function(self, unit)
		Debug('Spawning cache for', unit)
		local unitAuras = setmetatable({__unit = unit}, unitMetatable)
		self[unit] = unitAuras
		return unitAuras
	end
})

local eventFrame = _G.CreateFrame('Frame')

-- Forever: seals and Righteous Fury are hidden from addons while in combat, so a
-- seal cast during a fight cannot be read back. When our own cast of a tracked
-- aura succeeds, restart its countdown using the duration last measured for
-- that spell (see ProcessAura).
local function NoteCast(unit, spellID)
	if not unit or not spellID then return end
	local unitAuras = rawget(cache, unit)
	local playerBuff = unitAuras and rawget(unitAuras, 'PlayerBuff')
	if not playerBuff then return end

	local name = Compat.GetSpellName and Compat.GetSpellName(spellID)
	if name and Compat.IsSecret(name) then name = nil end
	local isSeal = IsSeal(spellID, name)

	-- Seals last 30 seconds on this client and the duration field is not always
	-- available. Never drop a seal cast just because its duration was never
	-- measured (it usually is not: a seal swapped in combat is never readable).
	local duration = durations[spellID]
	if (not duration or duration <= 0) and isSeal then
		duration = 30
		durations[spellID] = duration
	end

	-- Remember which seal is now the only possible one. While it has not
	-- expired, a restricted read that still reports the previous seal is stale
	-- and must not re-light that button (see IsStaleSeal/DropReplacedSeals).
	if isSeal then
		NoteSealCast(spellID, name, duration or 30)
	end

	-- NOTE: on this client judging does *not* consume the seal (unlike retail
	-- Wrath), so a Judgement cast must not clear any seal state.

	-- Seals replace each other. In combat a restricted read may keep listing the
	-- old seal, so drop every stored seal as soon as a new one is cast. Only do
	-- this once the new seal can actually be remembered, otherwise a swap would
	-- leave all seal buttons dark until combat ends.
	if duration and duration > 0 and isSeal then
		for k, v in next, playerBuff do
			if type(k) == 'number' and type(v) == 'table' then
				local vname = v.name
				if vname == nil then
					vname = Compat.GetSpellName and Compat.GetSpellName(v.id)
					if vname and Compat.IsSecret(vname) then vname = nil end
				end
				if IsSeal(v.id, vname) then
					del(v)
					playerBuff[k] = nil
				end
			end
		end
	end

	if not duration or duration <= 0 then return end

	-- The cast is fresher than anything cached: drop existing copies of it.
	for k, v in next, playerBuff do
		if type(k) == 'number' and type(v) == 'table' and v.id == spellID then
			del(v)
			playerBuff[k] = nil
		end
	end

	playerBuff[RememberedKey(spellID)] = {
		id = spellID,
		name = name,
		count = 1,
		expiration = GetTime() + duration,
		dispel = 'Magic',
		__remembered = true,
	}
	Debug('remembered cast of', spellID, name or '?', 'for', duration, 'seconds')
end

eventFrame:SetScript('OnEvent', function(self, event, unit, info, extra)
	stats.events[event] = (stats.events[event] or 0) + 1
	if event == 'UNIT_AURA' then
		if rawget(cache, unit) then
			cache[unit]:Update(info)
		end
	elseif event == 'PLAYER_REGEN_ENABLED' then
		-- Forever: aura data is readable again. Refresh instead of dropping the
		-- cache, so buttons do not flash "missing" right after combat.
		for _, unitAuras in next, cache do
			if type(unitAuras) == 'table' then
				unitAuras:Update()
			end
		end
	elseif event == 'UNIT_SPELLCAST_SUCCEEDED' then
		-- args: unitTarget, castGUID, spellID
		if unit == 'player' then
			NoteCast('player', extra)
		end
	end
end)
eventFrame:RegisterEvent('UNIT_AURA')
eventFrame:RegisterEvent('PLAYER_REGEN_ENABLED')
eventFrame:RegisterEvent('UNIT_SPELLCAST_SUCCEEDED')

------------------------------------------------------------------------------
-- Accessors
------------------------------------------------------------------------------

local function auraIterator(auras, index)
	local nextIndex, aura = index
	repeat
		nextIndex, aura = next(auras, nextIndex)
		if type(nextIndex) == "number" then
			return nextIndex, aura.id, aura.count, aura.expiration, aura.dispel, aura.name
		end
	until not nextIndex
end
local function NOP() end

local getters = {}
local iterators = {}

for key in next, mts do
	getters[key] = function(unit, id)
		if unit and UnitExists(unit) then
			local aura = cache[unit][key]:CheckGUID():GetById(id)
			if aura then
				return id, aura.count, aura.expiration, aura.dispel
			end
		end
	end
	iterators[key] = function(unit)
		if not unit or not UnitExists(unit) then return NOP end
		return auraIterator, cache[unit][key]:CheckGUID()
	end
end

------------------------------------------------------------------------------
-- Filter parser, memoized
------------------------------------------------------------------------------

local parsedFilter = addon.Memoize(function(filter)
	return (filter:match('PLAYER') and 'Player' or '') ..
		(filter:match('HARMFUL') and 'Debuff' or 'Buff')
end)

------------------------------------------------------------------------------
-- Functions for the rule environment
------------------------------------------------------------------------------

addon.AuraTools = {
	GetAura = function(unit, id, filter)
		return getters[parsedFilter[filter]](unit, id)
	end,
	IterateAuras = function(unit, filter)
		return iterators[parsedFilter[filter]](unit)
	end
}

-- Forever diagnostics, used by /abaforever auras.
function addon.AuraTools.DebugState(unit)
	local state = { unit = unit, exists = UnitExists(unit), caches = {} }
	local now = GetTime()
	if lastSeal then
		state.lastSeal = {
			id = lastSeal.id,
			name = lastSeal.name,
			family = lastSeal.family,
			left = lastSeal.expires - now,
		}
	end
	local unitAuras = rawget(cache, unit)
	if not unitAuras then return state end
	for key in next, mts do
		local cacheFor = rawget(unitAuras, key)
		if cacheFor then
			local n, remembered = 0, {}
			for k, v in next, cacheFor do
				if type(k) == 'number' and type(v) == 'table' then
					n = n + 1
					if v.__remembered then
						remembered[#remembered + 1] = { id = v.id, name = v.name, left = v.expiration - now }
					end
				end
			end
			state.caches[#state.caches + 1] = {
				key = key,
				count = n,
				last = cacheFor.__last,
				retries = cacheFor.__retries,
				remembered = remembered,
			}
		end
	end
	return state
end

function addon.AuraTools.DebugStats()
	return stats
end

addon.AuraTools.NoteCast = NoteCast
for suffix, getter in next, getters do
	addon.AuraTools["Get"..suffix] = getter
end
for suffix, iterator in next, iterators do
	addon.AuraTools["Iterate"..suffix.."s"] = iterator
end

------------------------------------------------------------------------------
-- Helpers to build rules
------------------------------------------------------------------------------

function addon.GetAuraGetter(filter)
	return getters[parsedFilter[filter]]
end

function addon.GetAuraIterator(filter)
	return iterators[parsedFilter[filter]]
end
