--[[
NewStatusAuras
  - PowerAuras 风格的 TGA 光环
  - 通过暴雪冷却管理器追踪增益，并替换为自定义光环

命令：
  /nsa              打开设置
  /nsa import       从冷却管理器导入
  /nsa cdm          打开暴雪冷却管理器
  /nsa profiles     打开配置文件
  /nsa test         测试光环
  /nsa add 51271    添加指定法术
]]
local ADDON_NAME = ...

NewStatusAurasDB = NewStatusAurasDB or {}
local db
local rootDB
local GetSpellInfoSafe
local currentCharacterKey
local currentClassKey

local function SelectProfileDatabase()
	rootDB = NewStatusAurasDB
	rootDB.profileKeys = rootDB.profileKeys or {}
	rootDB.profiles = rootDB.profiles or {}

	local character = UnitName("player") or "Player"
	local realm = GetRealmName and GetRealmName() or "Realm"
	local characterKey = character .. "-" .. realm
	currentCharacterKey = characterKey
	local classKey = select(2, UnitClass("player")) or "DEFAULT"
	currentClassKey = classKey

	-- Migrate the previous flat database without discarding any saved aura data.
	if rootDB.auras then
		rootDB.profiles["默认"] = rootDB.profiles["默认"] or {
			auras = rootDB.auras,
			settings = rootDB.settings,
		}
		rootDB.auras = nil
		rootDB.settings = nil
		rootDB.profileKeys[characterKey] = "默认"
	end

	local profileName = rootDB.profileKeys[characterKey] or classKey
	rootDB.profileKeys[characterKey] = profileName
	if not rootDB.profiles[profileName] then
		rootDB.profiles[profileName] = {
			profileType = (profileName == classKey) and "职业" or "自定义",
			class = classKey,
			character = characterKey,
		}
	end
	db = rootDB.profiles[profileName]
end

local function CreateDefaultAura(spellID, fallbackName)
	local info = GetSpellInfoSafe(spellID)
	return {
		name = (info and info.name) or fallbackName or ((spellID and "Spell " .. spellID) or "New Aura"),
		spellID = spellID or 0,
		texture = "Aura1.tga",
		size = 160,
		x = 0,
		y = 0,
		opacity = 1,
		showTimer = true,
		timerSize = 44,
		timerX = 0,
		timerY = 0,
		enabled = true,
		animation = "none",
		animationDuration = 2.4,
		animationScale = 1.25,
		color = { 1, 1, 1, 1 },
	}
end

local ADDON_ROOT = "Interface\\AddOns\\NewStatusAuras\\"
local TEXTURE_DIR = ADDON_ROOT .. "Media\\Auras\\"
local MAX_TEXTURES = 145
local UPDATE_INTERVAL = 0.08

local DEFAULT_SETTINGS = {
}

local ANIMATION_NAMES = {
	none = "无动画",
	rotate = "旋转",
	fade = "渐隐渐现",
	pulse = "对称脉冲",
	stretch = "变形",
	spinFade = "旋转渐隐",
}

local ANIMATION_ORDER = { "none", "rotate", "fade", "pulse", "stretch", "spinFade" }

local function Print(...)
	print("|cffccaa33[NSA]|r", ...)
end

local function CopyTable(source)
	local result = {}
	for key, value in pairs(source or {}) do
		if type(value) == "table" then
			result[key] = CopyTable(value)
		else
			result[key] = value
		end
	end
	return result
end

local function EnsureDatabase()
	db.auras = db.auras or {}
	db.settings = db.settings or {}
	for key, value in pairs(DEFAULT_SETTINGS) do
		if db.settings[key] == nil then
			db.settings[key] = value
		end
	end

	for index, aura in ipairs(db.auras) do
		aura.name = (aura.name and aura.name ~= "") and aura.name or ("光环" .. index)
		aura.texture = aura.texture or "Aura1.tga"
		aura.size = aura.size or 128
		aura.x = aura.x or 0
		aura.y = aura.y or 0
		aura.opacity = aura.opacity or 1
		aura.timerSize = aura.timerSize or 44
		aura.timerX = aura.timerX or 0
		aura.timerY = aura.timerY or 0
		if aura.showTimer == nil then aura.showTimer = true end
		if aura.enabled == nil then aura.enabled = true end
		aura.color = aura.color or { 1, 1, 1, 1 }
		aura.animation = aura.animation or "none"
		aura.animationDuration = aura.animationDuration or 2.4
		aura.animationScale = aura.animationScale or 1.25
		if aura.mirrorX == nil then aura.mirrorX = false end
		if aura.mirrorY == nil then aura.mirrorY = false end
	end
end

local function NormalizeTexture(value)
	local path = tostring(value or ""):gsub("/", "\\")
	path = path:gsub("^%s+", ""):gsub("%s+$", "")
	if path == "" then
		return "Aura1.tga"
	end
	if path:sub(1, 1) == "\\" then
		path = path:sub(2)
	end
	return path
end

local function GetTexturePath(value)
	local path = NormalizeTexture(value)
	if path:match("^Interface\\") then
		return path
	end
	if path:match("^Media\\") or path:match("^media\\") then
		return ADDON_ROOT .. path
	end
	if path:match("^Auras\\") or path:match("^auras\\") then
		return ADDON_ROOT .. "Media\\" .. path
	end
	if not path:find("\\") and not path:find("/") and not path:match("^Aura%d+%.tga$") then
		return ADDON_ROOT .. "Media\\" .. path
	end
	return TEXTURE_DIR .. path
end

local function FormatTime(seconds)
	if type(seconds) ~= "number" then
		return ""
	end
	local ok, result = pcall(function()
		seconds = math.max(0, seconds)
		if seconds >= 60 then
			return string.format("%d:%.2d", math.floor(seconds / 60), math.floor(seconds % 60))
		end
		return string.format("%.1f", seconds)
	end)
	if ok then
		return result
	end
	return "..."
end

GetSpellInfoSafe = function(spellID)
	if not spellID or spellID <= 0 then
		return nil
	end
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
		if ok and info then
			return info
		end
	end
	if GetSpellInfo then
		local ok, name, _, icon = pcall(GetSpellInfo, spellID)
		if ok and name then
			return { name = name, iconID = icon }
		end
	end
end

-- 12.x 首选 GetPlayerAuraBySpellID，旧版本和部分客户端使用 GetUnitAuraBySpellID。
local function GetPlayerAura(spellID)
	if not spellID or spellID <= 0 or not C_UnitAuras then
		return nil
	end

	if C_UnitAuras.GetPlayerAuraBySpellID then
		local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
		if ok and aura then
			return aura
		end
	end

	if C_UnitAuras.GetUnitAuraBySpellID then
		local ok, aura = pcall(C_UnitAuras.GetUnitAuraBySpellID, "player", spellID)
		if ok and aura then
			return aura
		end
	end

	if C_UnitAuras.GetUnitAuras then
		local ok, auras = pcall(C_UnitAuras.GetUnitAuras, "player", "HELPFUL")
		if ok and auras then
			for _, aura in ipairs(auras) do
				local auraSpellID = aura.spellId or aura.spellID
				if auraSpellID == spellID then
					return aura
				end
			end
		end
	end

	if C_UnitAuras.GetAuraDataByIndex then
		for index = 1, 40 do
			local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, "HELPFUL")
			if not ok or not aura then
				break
			end
			local auraSpellID = aura.spellId or aura.spellID
			if auraSpellID == spellID then
				return aura
			end
		end
	end
end

-- Cooldown Manager is the combat-safe source for tracked buffs.  In combat the
-- aura payload can contain secret values, but CDM keeps the item frame and its
-- auraInstanceID available.  We only compare auraInstanceID with nil here.
local cdmKeysByID = {}
local cdmViewers = {
	"BuffBarCooldownViewer",
	"BuffIconCooldownViewer",
}

local function AddCDMKey(keys, id)
	if type(id) == "number" and id > 0 then
		keys[id] = true
	end
end

local function GetCDMKeys(cooldownID)
	if not cooldownID or not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCooldownInfo then
		return nil
	end
	if cdmKeysByID[cooldownID] ~= nil then
		return cdmKeysByID[cooldownID] or nil
	end

	local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
	if not ok or not info then
		cdmKeysByID[cooldownID] = false
		return nil
	end

	local keys = {}
	AddCDMKey(keys, info.spellID)
	AddCDMKey(keys, info.spellId)
	AddCDMKey(keys, info.overrideSpellID)
	AddCDMKey(keys, info.overrideSpellId)
	AddCDMKey(keys, info.overrideTooltipSpellID)
	if type(info.linkedSpellIDs) == "table" then
		for _, linkedSpellID in ipairs(info.linkedSpellIDs) do
			AddCDMKey(keys, linkedSpellID)
		end
	end

	if not next(keys) then
		cdmKeysByID[cooldownID] = false
		return nil
	end
	cdmKeysByID[cooldownID] = keys
	return keys
end

local function GetCDMDuration(frame)
	if not frame then
		return nil
	end
	if frame.nsaDurationObject then
		return frame.nsaDurationObject
	end
	if frame.cdmDurationObj then
		return frame.cdmDurationObj
	end
	-- 12.1 exposes the combat-safe DurationObject even when aura fields are
	-- secret. Do not gate this call on ShouldAurasBeSecret; Cooldown frames are
	-- specifically designed to render this object without Lua arithmetic.
	if frame.auraInstanceID ~= nil and C_UnitAuras and C_UnitAuras.GetAuraDuration then
		local ok, durationObject = pcall(C_UnitAuras.GetAuraDuration, "player", frame.auraInstanceID)
		if ok and durationObject then
			return durationObject
		end
	end
	return nil
end

local function IsReadableNumber(value)
	return type(value) == "number" and not (issecretvalue and issecretvalue(value))
end

local function GetCDMRemaining(state, now)
	if not state then return nil, nil end
	local startTime = state.startTime
	local duration = state.duration
	local modRate = state.modRate or 1
	if not (IsReadableNumber(startTime) and IsReadableNumber(duration) and IsReadableNumber(modRate)) then
		return nil, nil
	end
	if duration <= 0 or modRate <= 0 then
		return nil, duration
	end
	local remaining = startTime + duration / modRate - now
	if remaining < 0 then remaining = 0 end
	return remaining, duration / modRate
end

local function GetCDMCooldownValues(frame)
	if not frame then return nil, nil, nil end
	for _, fieldName in ipairs({ "Cooldown", "cooldown" }) do
		local cooldown = frame[fieldName]
		if cooldown and cooldown.GetCooldownTimes then
			local ok, startTime, duration, modRate = pcall(cooldown.GetCooldownTimes, cooldown)
			if ok and startTime and duration then
				return startTime, duration, modRate
			end
		end
	end
	return nil, nil, nil
end

-- Returns the first matching CDM item.  This deliberately does not read spell
-- IDs from the aura payload, so it remains usable while the player is in combat.
local function GetCDMTrackedAura(spellID)
	if not spellID or not C_CooldownViewer then
		return nil
	end
	for _, viewerName in ipairs(cdmViewers) do
		local viewer = _G[viewerName]
		local pool = viewer and viewer.itemFramePool
		if pool and pool.EnumerateActive then
			for frame in pool:EnumerateActive() do
				local keys = frame.cooldownID and GetCDMKeys(frame.cooldownID)
				if keys and keys[spellID] then
					local active = frame.auraInstanceID ~= nil
					local okInfo, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, frame.cooldownID)
					local startTime, duration, modRate = GetCDMCooldownValues(frame)
					return {
						active = active,
						frame = frame,
						info = okInfo and info or nil,
						durationObject = active and GetCDMDuration(frame) or nil,
						startTime = active and (frame.nsaCooldownStart or startTime) or nil,
						duration = active and (frame.nsaCooldownDuration or duration) or nil,
						modRate = active and (frame.nsaCooldownModRate or modRate) or nil,
					}
				end
			end
		end
	end
end

local function GetCDMCountdownText(frame)
	if not frame then return nil end
	for _, regionName in ipairs({ "Duration", "Time", "CooldownText", "Cooldown" }) do
		local region = frame[regionName]
		if region and region.GetText then
			local ok, text = pcall(region.GetText, region)
			if ok and type(text) == "string" and text ~= "" then
				return text
			end
		end
	end
	return nil
end

local function ResetCDMKeyCache()
	wipe(cdmKeysByID)
end

-- 将可能受到秘密值限制的字段放在 pcall 内，避免造成整段插件报错。
local function GetAuraTiming(aura)
	if not aura then
		return nil, nil
	end
	local ok, expirationTime, duration = pcall(function()
		return aura.expirationTime, aura.duration
	end)
	if not ok then
		return nil, nil
	end
	return expirationTime, duration
end

local function GetRemaining(aura, now)
	local expirationTime, duration = GetAuraTiming(aura)
	if expirationTime == nil then
		return nil, duration
	end
	local ok, remaining = pcall(function()
		return expirationTime - now
	end)
	if not ok or type(remaining) ~= "number" then
		return nil, duration
	end
	return remaining, duration
end

local function SafeGreater(left, right)
	local ok, result = pcall(function()
		return left > right
	end)
	if not ok or (issecretvalue and issecretvalue(result)) then
		return false
	end
	return result == true
end

local function SafeLessEqual(left, right)
	local ok, result = pcall(function()
		return left <= right
	end)
	if not ok or (issecretvalue and issecretvalue(result)) then
		return false
	end
	return result == true
end

-- ---------------------------------------------------------------------------
-- 导入 / 导出
-- ---------------------------------------------------------------------------
local function SerializeValue(value)
	if type(value) == "table" then
		local parts = { "{ " }
		local first = true
		for key, item in pairs(value) do
			if not first then
				parts[#parts + 1] = ", "
			end
			first = false
			local serializedKey
			if type(key) == "string" then
				serializedKey = "[\"" .. key:gsub("\\", "\\\\"):gsub("\"", "\\\"") .. "\"]"
			else
				serializedKey = "[" .. tostring(key) .. "]"
			end
			parts[#parts + 1] = serializedKey .. "=" .. SerializeValue(item)
		end
		parts[#parts + 1] = " }"
		return table.concat(parts)
	elseif type(value) == "string" then
		return "\"" .. value:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n") .. "\""
	elseif type(value) == "boolean" or type(value) == "number" then
		return tostring(value)
	end
	return "nil"
end

local function ExportString(selectedOnly)
	if not selectedOnly then
		return "NSA1:" .. SerializeValue(db.auras)
	end
	local selected = {}
	for _, aura in ipairs(db.auras) do
		if aura.selected then
			table.insert(selected, CopyTable(aura))
		end
	end
	return "NSA1:" .. SerializeValue(selected)
end

local function ImportString(value)
	if not value then
		return false, "空字符串"
	end
	value = value:gsub("^%s+", ""):gsub("%s+$", "")
	if value:sub(1, 5) ~= "NSA1:" then
		return false, "不是 NewStatusAuras 字符串"
	end

	local code = value:sub(6)
	if not code:find("^return") then
		code = "return " .. code
	end
	local loader = loadstring or load
	local fn, errorMessage = loader(code)
	if not fn then
		return false, "解析失败: " .. tostring(errorMessage)
	end
	local ok, data = pcall(fn)
	if not ok or type(data) ~= "table" then
		return false, "数据格式不对"
	end
	db.auras = data
	EnsureDatabase()
	return true, "导入成功，共 " .. #db.auras .. " 个特效"
end

-- ---------------------------------------------------------------------------
-- 运行时显示
-- ---------------------------------------------------------------------------
local auraFrames = {}
local nativeAuraContainers = {}
local nativeAuraContainerMode = false
local nativeAuraRebuildPending = false
local nativeAuraSignature
local updateElapsed = 0
local testMode = false

local function CanUseNativeAuraContainers()
	return type(CreateFrame) == "function"
		and type(AuraContainerSortMethod) == "table"
		and type(AuraContainerSortDirection) == "table"
		and (not DoesTemplateExist or DoesTemplateExist("CustomAuraContainerTemplate"))
end

local function HideLegacyAuraFrames()
	for _, frame in pairs(auraFrames) do
		frame:Hide()
		if frame.cooldown then frame.cooldown:Hide() end
		if frame.timer then frame.timer:Hide() end
	end
end

local function ClearNativeAuraContainers()
	for _, container in pairs(nativeAuraContainers) do
		pcall(container.SetUnit, container, "none")
		pcall(container.Hide, container)
	end
	wipe(nativeAuraContainers)
	nativeAuraContainerMode = false
end

local function GetNativeAuraSignature()
	local parts = {}
	for index, aura in ipairs(db and db.auras or {}) do
		parts[#parts + 1] = table.concat({
			index, aura.spellID or 0, aura.texture or "", aura.size or 0,
			aura.x or 0, aura.y or 0, aura.opacity or 1,
			aura.timerSize or 44, aura.timerX or 0, aura.timerY or 0,
			aura.showTimer == false and 0 or 1, aura.enabled == false and 0 or 1,
			aura.animation or "none", aura.animationDuration or 2.4,
			(aura.color and table.concat(aura.color, ",")) or "",
			aura.mirrorX and 1 or 0, aura.mirrorY and 1 or 0,
		}, ":")
	end
	return table.concat(parts, "|")
end

local function BuildNativeAuraContainer(index, aura)
	local spellID = tonumber(aura.spellID)
	if aura.enabled == false or not spellID or spellID <= 0 then
		return
	end

	local ok, container = pcall(CreateFrame, "AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
	if not ok or not container then
		return false
	end
	container:SetSize(aura.size or 128, aura.size or 128)
	container:SetFrameStrata("MEDIUM")
	container:SetPoint("CENTER", UIParent, "CENTER", aura.x or 0, aura.y or 0)
	container:SetClipsChildren(false)
	local auraConfig = CopyTable(aura)

	local groupOptions = {
		maxFrameCount = 1,
		candidateFilters = { includeSpellIDs = { [spellID] = true } },
		initializeFrame = function(button)
			button:SetSize(auraConfig.size or 128, auraConfig.size or 128)
			button:SetMouseClickEnabled(false)
			button:SetMouseMotionEnabled(false)

			-- Keep Blizzard's icon region as the AuraContainer source, then place
			-- the user TGA above it so Blizzard can refresh its own region freely.
			local nativeIcon = button:CreateTexture(nil, "ARTWORK")
			nativeIcon:SetAllPoints(button)
			button:SetIcon(nativeIcon)
			-- The native icon is only used as AuraContainer's data source.  Keep
			-- Blizzard's duration engine, but do not draw its duplicate icon.
			nativeIcon:SetAlpha(0)
			local icon = button:CreateTexture(nil, "OVERLAY")
			icon:SetAllPoints(button)
			icon:SetBlendMode("ADD")
			icon:SetTexture(GetTexturePath(auraConfig.texture))
			icon:SetAlpha(auraConfig.opacity or 1)
			local color = auraConfig.color or { 1, 1, 1, 1 }
			icon:SetVertexColor(color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1)
			icon:SetTexCoord(
				auraConfig.mirrorX and 1 or 0, auraConfig.mirrorX and 0 or 1,
				auraConfig.mirrorY and 1 or 0, auraConfig.mirrorY and 0 or 1
			)
			local cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
			cooldown:SetAllPoints(button)
			cooldown:SetDrawSwipe(false)
			cooldown:SetDrawBling(false)
			cooldown:SetDrawEdge(false)
			cooldown:SetHideCountdownNumbers(auraConfig.showTimer == false)
			if cooldown.SetUseAuraDisplayTime then
				cooldown:SetUseAuraDisplayTime(true)
			end
			if cooldown.SetCountdownMillisecondsThreshold then
				cooldown:SetCountdownMillisecondsThreshold(10)
			end
			local countdown = cooldown.GetCountdownFontString and cooldown:GetCountdownFontString()
			if countdown then
				countdown:ClearAllPoints()
				countdown:SetPoint("CENTER", button, "CENTER", auraConfig.timerX or 0, auraConfig.timerY or 0)
				countdown:SetFont(STANDARD_TEXT_FONT, auraConfig.timerSize or 44, "OUTLINE")
			end
			button:SetDurationCooldown(cooldown)

			if auraConfig.animation and auraConfig.animation ~= "none" then
				local animation = icon:CreateAnimationGroup()
				local duration = math.max(0.2, tonumber(auraConfig.animationDuration) or 2.4)
				if auraConfig.animation == "rotate" or auraConfig.animation == "spinFade" then
					local rotation = animation:CreateAnimation("Rotation")
					rotation:SetDegrees(360)
					rotation:SetDuration(duration)
				end
				if auraConfig.animation == "fade" or auraConfig.animation == "spinFade" then
					local alpha = animation:CreateAnimation("Alpha")
					alpha:SetFromAlpha(0.2)
					alpha:SetToAlpha(1)
					alpha:SetDuration(duration / 2)
					alpha:SetOrder(1)
					local alphaBack = animation:CreateAnimation("Alpha")
					alphaBack:SetFromAlpha(1)
					alphaBack:SetToAlpha(0.2)
					alphaBack:SetDuration(duration / 2)
					alphaBack:SetOrder(2)
				end
				animation:SetLooping("REPEAT")
				animation:Play()
			end
		end,
	}

	local added = pcall(container.AddAuraGroup, container, "NSA" .. index, "HELPFUL|PLAYER", groupOptions)
	if not added then
		pcall(container.Hide, container)
		return false
	end
	local unitSet = pcall(container.SetUnit, container, "player")
	if not unitSet then
		pcall(container.Hide, container)
		return false
	end
	pcall(container.UpdateAllAuras, container)
	container:Show()
	nativeAuraContainers[index] = container
	return true
end

local function RebuildNativeAuraContainers()
	if not db or not CanUseNativeAuraContainers() then
		return false
	end
	if InCombatLockdown and InCombatLockdown() then
		nativeAuraRebuildPending = true
		return false
	end
	ClearNativeAuraContainers()
	local built = false
	for index, aura in ipairs(db.auras) do
		if BuildNativeAuraContainer(index, aura) then
			built = true
		end
	end
	if built then
		nativeAuraContainerMode = true
		HideLegacyAuraFrames()
	end
	nativeAuraRebuildPending = false
	nativeAuraSignature = GetNativeAuraSignature()
	return built
end

local function CreateAuraFrame(aura)
	local frame = CreateFrame("Frame", nil, UIParent)
	frame:SetSize(aura.size or 128, aura.size or 128)
	frame:SetFrameStrata("MEDIUM")
	frame:EnableMouse(false)
	frame:Hide()

	frame.texture = frame:CreateTexture(nil, "ARTWORK")
	frame.texture:SetAllPoints(frame)
	frame.texture:SetBlendMode("ADD")

	frame.timer = frame:CreateFontString(nil, "OVERLAY", "NumberFont_Outline_Huge")
	frame.timer:SetPoint("CENTER", frame, "CENTER", 0, 0)
	frame.timer:Hide()
	frame.cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
	frame.cooldown:SetAllPoints(frame)
	frame.cooldown:SetDrawEdge(false)
	frame.cooldown:SetDrawSwipe(false)
	frame.cooldown:SetHideCountdownNumbers(false)
	if frame.cooldown.SetUseAuraDisplayTime then
		frame.cooldown:SetUseAuraDisplayTime(true)
	end
	frame.cooldownText = frame.cooldown.GetCountdownFontString and frame.cooldown:GetCountdownFontString() or nil
	frame.cooldown:Hide()

	frame.animation = frame:CreateAnimationGroup()
	return frame
end

local function ConfigureAuraAnimation(frame, aura)
	local color = aura.color or { 1, 1, 1, 1 }
	local signature = table.concat({
			aura.animation or "none", aura.animationDuration or 2.4,
		(aura.color and table.concat(aura.color, ",")) or "",
		aura.animationScale or 1.25, aura.mirrorX and 1 or 0,
		aura.mirrorY and 1 or 0, color[1] or 1, color[2] or 1,
		color[3] or 1, color[4] or 1,
	}, ":")
	if frame.animationKey == signature then
		return
	end
	frame.animationKey = signature
	if frame.animation:IsPlaying() then frame.animation:Stop() end
	frame.animation:RemoveAnimations()
	frame.texture:SetVertexColor(
		color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1
	)
	local scaleX = aura.mirrorX and -1 or 1
	local scaleY = aura.mirrorY and -1 or 1
	frame.texture:SetTexCoord(scaleX > 0 and 0 or 1, scaleX > 0 and 1 or 0, scaleY > 0 and 0 or 1, scaleY > 0 and 1 or 0)

	local kind = aura.animation or "none"
	local duration = math.max(0.2, tonumber(aura.animationDuration) or 2.4)
	local group = frame.animation
	if kind == "rotate" or kind == "spinFade" then
		local rotation = group:CreateAnimation("Rotation")
		rotation:SetDegrees(360)
		rotation:SetDuration(duration)
	end
	if kind == "fade" or kind == "spinFade" then
		local alpha = group:CreateAnimation("Alpha")
		alpha:SetFromAlpha(0.2)
		alpha:SetToAlpha(1)
		alpha:SetDuration(duration / 2)
		alpha:SetOrder(1)
		alpha:SetSmoothing("IN_OUT")
		local alphaBack = group:CreateAnimation("Alpha")
		alphaBack:SetFromAlpha(1)
		alphaBack:SetToAlpha(0.2)
		alphaBack:SetDuration(duration / 2)
		alphaBack:SetOrder(2)
		alphaBack:SetSmoothing("IN_OUT")
	elseif kind == "pulse" then
		local scale = group:CreateAnimation("Scale")
		scale:SetScale(tonumber(aura.animationScale) or 1.25, tonumber(aura.animationScale) or 1.25)
		scale:SetDuration(duration / 2)
		scale:SetOrder(1)
		local scaleBack = group:CreateAnimation("Scale")
		scaleBack:SetScale(1 / (tonumber(aura.animationScale) or 1.25), 1 / (tonumber(aura.animationScale) or 1.25))
		scaleBack:SetDuration(duration / 2)
		scaleBack:SetOrder(2)
	elseif kind == "stretch" then
		local scale = group:CreateAnimation("Scale")
		scale:SetScale(tonumber(aura.animationScale) or 1.25, 1)
		scale:SetDuration(duration / 2)
		scale:SetOrder(1)
		local scaleBack = group:CreateAnimation("Scale")
		scaleBack:SetScale(1 / (tonumber(aura.animationScale) or 1.25), 1)
		scaleBack:SetDuration(duration / 2)
		scaleBack:SetOrder(2)
	end
	if kind ~= "none" then
		group:SetLooping("REPEAT")
		group:Play()
	end
end

local function HideBlizzardTrackedBars()
	local names = { "BuffBarCooldownViewer" }
	for _, name in ipairs(names) do
		local viewer = _G[name]
		if viewer then
			pcall(viewer.Show, viewer)
			-- Keep CDM alive and updating; only make its original tracked bar invisible.
			pcall(viewer.SetAlpha, viewer, 0)
			if not viewer.nsaHooked then
				viewer.nsaHooked = true
				viewer:HookScript("OnShow", function(self)
					pcall(self.SetAlpha, self, 0)
				end)
			end
		end
	end
end

local function OpenCooldownManager()
	if not CooldownViewerSettings and UIParentLoadAddOn then
		UIParentLoadAddOn("Blizzard_CooldownViewer")
	end
	if CooldownViewerSettings and CooldownViewerSettings.TogglePanel then
		CooldownViewerSettings:TogglePanel()
		return true
	end
	Print("冷却管理器尚未加载，请先进入游戏后再试。")
	return false
end

local function RefreshPreview(frame)
	if not frame or not frame.previewHost or not frame.draft then return end
	frame.previewHost.texture:SetTexture(GetTexturePath(frame.draft.texture))
	frame.previewHost:SetSize(frame.draft.size or 150, frame.draft.size or 150)
	frame.previewHost:ClearAllPoints()
	frame.previewHost:SetPoint("CENTER", frame.previewArea or frame, "CENTER", frame.draft.x or 0, frame.draft.y or 0)
	frame.previewHost:SetAlpha(frame.draft.opacity or 1)
	if frame.previewTimer then
		frame.previewTimer:ClearAllPoints()
		frame.previewTimer:SetPoint("CENTER", frame.previewHost, "CENTER", frame.draft.timerX or 0, frame.draft.timerY or 0)
		frame.previewTimer:SetFont(STANDARD_TEXT_FONT, frame.draft.timerSize or 44, "OUTLINE")
		frame.previewTimer:SetText("8.8")
		frame.previewTimer:SetTextColor(1, 1, 1)
		frame.previewTimer:SetShown(frame.draft.showTimer ~= false)
	end
	ConfigureAuraAnimation(frame.previewHost, frame.draft)
	if frame.draft.animation == "none" then
		frame.previewHost.animation:Stop()
	end
	frame.previewHost:Show()
end

local function UpdateOneAura(key, aura)
	local frame = auraFrames[key]
	if not frame then
		frame = CreateAuraFrame(aura)
		auraFrames[key] = frame
	end

	local info = GetSpellInfoSafe(tonumber(aura.spellID))
	local auraData = nil
	local remaining, duration
	local spellID = tonumber(aura.spellID)
	local cdmState
	local durationObject
	local cdmText
	local cdmRemaining
	local cdmDuration

	if aura.enabled ~= false and spellID and spellID > 0 then
		if not testMode then
			cdmState = GetCDMTrackedAura(spellID)
			if cdmState then
				if cdmState.active then
					durationObject = cdmState.durationObject
					auraData = cdmState.frame
					cdmText = GetCDMCountdownText(cdmState.frame)
					cdmRemaining, cdmDuration = GetCDMRemaining(cdmState, GetTime())
					if cdmRemaining ~= nil then
						remaining, duration = cdmRemaining, cdmDuration
					end
					-- Use the regular aura lookup only for readable timing/name data.
					-- CDM remains the sole source of the combat-safe active boolean.
					local readableAura = GetPlayerAura(spellID)
					local readableRemaining, readableDuration = GetRemaining(readableAura, GetTime())
					if readableAura and IsReadableNumber(readableRemaining) then
						auraData = readableAura
						remaining, duration = readableRemaining, readableDuration
					end
				end
			else
				auraData = GetPlayerAura(spellID)
				remaining, duration = GetRemaining(auraData, GetTime())
			end
		else
			auraData = { name = aura.name or "测试增益", icon = 134400 }
			remaining, duration = 8.8, 10
		end
	end

	local active = testMode or (cdmState and cdmState.active) or (not cdmState and auraData ~= nil)
	if remaining ~= nil and SafeLessEqual(remaining, 0) then
		active = false
	end

	if active then
		frame:SetSize(aura.size or 128, aura.size or 128)
		frame:ClearAllPoints()
		frame:SetPoint("CENTER", UIParent, "CENTER", aura.x or 0, aura.y or 0)
		frame.timer:ClearAllPoints()
		frame.timer:SetPoint("CENTER", frame, "CENTER", aura.timerX or 0, aura.timerY or 0)
		frame.texture:SetTexture(GetTexturePath(aura.texture))
		frame.texture:SetAlpha(aura.opacity or 1)
		if frame.cooldownText then
			pcall(function()
				frame.cooldownText:ClearAllPoints()
				frame.cooldownText:SetPoint("CENTER", frame, "CENTER", aura.timerX or 0, aura.timerY or 0)
				frame.cooldownText:SetFont(STANDARD_TEXT_FONT, aura.timerSize or 44, "OUTLINE")
			end)
		end
		frame:Show()
		ConfigureAuraAnimation(frame, aura)
		if durationObject and frame.cooldown and frame.cooldown.SetCooldownFromDurationObject then
			frame.cooldown:ClearAllPoints()
			frame.cooldown:SetAllPoints(frame)
			frame.cooldown:SetHideCountdownNumbers(aura.showTimer == false or IsReadableNumber(remaining) or cdmText ~= nil)
			local ok = pcall(frame.cooldown.SetCooldownFromDurationObject, frame.cooldown, durationObject)
			if ok then
				frame.cooldown:Show()
			end
		elseif cdmState and cdmState.startTime ~= nil and frame.cooldown and frame.cooldown.SetCooldown then
			pcall(frame.cooldown.SetCooldown, frame.cooldown, cdmState.startTime, cdmState.duration or 0, cdmState.modRate or 1)
			frame.cooldown:SetHideCountdownNumbers(aura.showTimer == false)
			frame.cooldown:Show()
		else
			frame.cooldown:Hide()
		end
		if aura.showTimer ~= false and IsReadableNumber(remaining) then
			frame.timer:SetFont(STANDARD_TEXT_FONT, aura.timerSize or 44, "OUTLINE")
			frame.timer:SetText(FormatTime(remaining))
			if SafeLessEqual(remaining, 5) then
				frame.timer:SetTextColor(1, 0.2, 0.15)
			else
				frame.timer:SetTextColor(1, 1, 1)
			end
			frame.timer:Show()
		elseif aura.showTimer ~= false and cdmText then
			frame.timer:SetFont(STANDARD_TEXT_FONT, aura.timerSize or 44, "OUTLINE")
			frame.timer:SetText(cdmText)
			frame.timer:SetTextColor(1, 1, 1)
			frame.timer:Show()
		else
			frame.timer:Hide()
		end
		if frame.cooldown then
			frame.cooldown:SetHideCountdownNumbers(aura.showTimer == false or IsReadableNumber(remaining) or cdmText ~= nil)
			if aura.showTimer == false then frame.cooldown:Hide() end
		end
	else
		frame.animation:Stop()
		frame.animationKey = nil
		frame.cooldown:Hide()
		frame.timer:Hide()
		frame:Hide()
	end

	return active
end

local function UpdateDisplay()
	if not db then
		return
	end
	HideBlizzardTrackedBars()
	if CanUseNativeAuraContainers() then
		local signature = GetNativeAuraSignature()
		if not nativeAuraContainerMode or nativeAuraSignature ~= signature then
			RebuildNativeAuraContainers()
		end
		if nativeAuraContainerMode then
			if testMode then
				for key, aura in ipairs(db.auras) do
					UpdateOneAura(key, aura)
				end
			else
				HideLegacyAuraFrames()
			end
			return
		end
	end
	for key, aura in ipairs(db.auras) do
		UpdateOneAura(key, aura)
	end
end

-- ---------------------------------------------------------------------------
-- 设置面板
-- ---------------------------------------------------------------------------
local optionsFrame
local editFrame
local selectedKey
local editKey
local slotButtons = {}

local function AddBackdrop(frame)
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true,
		tileSize = 32,
		edgeSize = 32,
		insets = { left = 8, right = 8, top = 8, bottom = 8 },
	})
	frame:SetBackdropColor(0.05, 0.05, 0.08, 1)
end

local function MakeButton(parent, text, width)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width or 100, 22)
	button:SetText(text)
	return button
end

local function RefreshGrid()
	if not optionsFrame then return end
	for _, button in pairs(slotButtons) do
		button:Hide()
	end

	for index, aura in ipairs(db.auras) do
		local button = slotButtons[index]
		if not button then
			button = CreateFrame("Button", nil, optionsFrame.gridParent, "BackdropTemplate")
			button:SetSize(72, 64)
			button:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
			button:SetBackdropColor(0.04, 0.04, 0.06, 0.85)
			button.texture = button:CreateTexture(nil, "ARTWORK")
			button.texture:SetAllPoints(button)
			button.texture:SetTexCoord(0.05, 0.95, 0.05, 0.95)
			button.check = CreateFrame("CheckButton", nil, button, "UICheckButtonTemplate")
			button.check:SetSize(20, 20)
			button.check:SetPoint("TOPLEFT", button, "TOPLEFT", -4, 4)
			button.check:SetScript("OnClick", function(self)
				local aura = db.auras[self:GetParent().auraKey]
				if aura then aura.selected = self:GetChecked() and true or false end
			end)
			button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			button.label:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 2, 2)
			button.label:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
			button.label:SetJustifyH("CENTER")
			button.label:SetWordWrap(false)
			button:SetScript("OnClick", function(self)
				selectedKey = self.auraKey
				RefreshGrid()
			end)
			button:SetScript("OnDoubleClick", function(self)
				if self.auraKey and optionsFrame.openEdit then
					optionsFrame.openEdit(self.auraKey)
				end
			end)
			slotButtons[index] = button
		end

		button.auraKey = index
		button.check:SetChecked(aura.selected == true)
		button.texture:SetTexture(GetTexturePath(aura.texture))
		button.texture:SetBlendMode("BLEND")
		button.label:SetText(aura.name or ("光环" .. index))
		local row = math.floor((index - 1) / 7)
		local column = (index - 1) % 7
		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", optionsFrame.gridParent, "TOPLEFT", 4 + column * 80, -4 - row * 72)
		if index == selectedKey then
			button:SetBackdropBorderColor(1, 0.82, 0.15, 1)
		else
			button:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
		end
		button:Show()
	end
end

local function CloseEdit()
	if editFrame then
		editFrame:Hide()
	end
end

local function OpenEdit(key)
	local aura = db.auras[key]
	if not aura then return end
	editKey = key

	if not editFrame then
		local frame = CreateFrame("Frame", "NSAEditFrame", UIParent, "BackdropTemplate")
		frame:SetSize(540, 640)
		frame:SetPoint("CENTER")
		frame:SetFrameStrata("DIALOG")
		frame:SetMovable(true)
		frame:EnableMouse(true)
		frame:RegisterForDrag("LeftButton")
		frame:SetScript("OnDragStart", frame.StartMoving)
		frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
		AddBackdrop(frame)
		tinsert(UISpecialFrames, "NSAEditFrame")
		editFrame = frame

		local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		title:SetPoint("TOP", frame, "TOP", 0, -14)
		title:SetText("特效编辑器")

		local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
		close:SetScript("OnClick", CloseEdit)

		frame.previewHost = CreateFrame("Frame", nil, frame)
		frame.previewHost:SetSize(150, 150)
		frame.previewArea = CreateFrame("Frame", nil, frame)
		frame.previewArea:SetSize(190, 190)
		frame.previewArea:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -42)
		frame.previewHost:SetPoint("CENTER", frame.previewArea, "CENTER")
		frame.previewHost.animation = frame.previewHost:CreateAnimationGroup()
		frame.preview = frame.previewHost:CreateTexture(nil, "ARTWORK")
		frame.preview:SetAllPoints(frame.previewHost)
		frame.preview:SetBlendMode("ADD")
		frame.previewHost.texture = frame.preview
		frame.previewTimer = frame.previewHost:CreateFontString(nil, "OVERLAY", "NumberFont_Outline_Huge")
		frame.previewTimer:SetPoint("CENTER", frame.previewHost, "CENTER")
		frame.previewTimer:SetText("8.8")

		frame.prevTexture = MakeButton(frame, "<", 30)
		frame.prevTexture:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -190)
		frame.nextTexture = MakeButton(frame, ">", 30)
		frame.nextTexture:SetPoint("LEFT", frame.prevTexture, "RIGHT", 4, 0)
		frame.textureName = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		frame.textureName:SetPoint("LEFT", frame.nextTexture, "RIGHT", 8, 0)
		frame.textureName:SetWidth(180)
		frame.textureName:SetJustifyH("LEFT")

		local function AddLabel(y, text, x)
			local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			label:SetPoint("TOPLEFT", frame, "TOPLEFT", x or 190, y)
			label:SetText(text)
			return label
		end

		local function AddEdit(y, width, x)
			local edit = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
			edit:SetSize(width or 70, 22)
			edit:SetAutoFocus(false)
			edit:SetMaxLetters(180)
			edit:SetPoint("TOPLEFT", frame, "TOPLEFT", x or 280, y)
			return edit
		end

		AddLabel(-26, "光环名称：")
		frame.name = AddEdit(-26, 190)
		AddLabel(-56, "法术 ID：")
		frame.spellID = AddEdit(-56, 90)
		AddLabel(-86, "位置 X：")
		frame.posX = AddEdit(-86, 60, 440)
		AddLabel(-116, "位置 Y：")
		frame.posY = AddEdit(-116, 60, 440)
		AddLabel(-146, "光环大小：")
		frame.size = AddEdit(-146, 60, 440)
		AddLabel(-176, "不透明度：")
		frame.opacity = AddEdit(-176, 60, 440)
		AddLabel(-206, "倒计时字号：")
		frame.timerSize = AddEdit(-206, 60, 440)
		AddLabel(-236, "倒计时 X：")
		frame.timerX = AddEdit(-236, 60, 440)
		AddLabel(-266, "倒计时 Y：")
		frame.timerY = AddEdit(-266, 60, 440)
		AddLabel(-296, "贴图路径：")
		frame.texturePath = AddEdit(-296, 190)

		local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		hint:SetPoint("TOPLEFT", frame, "TOPLEFT", 190, -324)
		hint:SetText("例如：Media\\MyAura.tga 或 Auras\\Aura1.tga")
		hint:SetTextColor(0.65, 0.65, 0.65)

		frame.timer = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
		frame.timer:SetPoint("TOPLEFT", frame, "TOPLEFT", 190, -352)
		frame.timer:SetText("显示倒计时")
		AddLabel(-416, "动画形式：")
		frame.animation = MakeButton(frame, ANIMATION_NAMES.none, 128)
		frame.animation:SetPoint("TOPLEFT", frame, "TOPLEFT", 280, -410)
		AddLabel(-446, "动画周期：")
		frame.animationDuration = AddEdit(-446, 65, 280)
		AddLabel(-446, "变形倍率：", 360)
		frame.animationScale = AddEdit(-446, 65, 440)

		AddLabel(-476, "光环颜色：")
		frame.colorButton = MakeButton(frame, "选择颜色", 90)
		frame.colorButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 280, -470)
		frame.colorSwatch = frame:CreateTexture(nil, "ARTWORK")
		frame.colorSwatch:SetSize(20, 20)
		frame.colorSwatch:SetPoint("LEFT", frame.colorButton, "RIGHT", 6, 0)
		frame.mirrorX = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
		frame.mirrorX:SetPoint("TOPLEFT", frame, "TOPLEFT", 190, -504)
		frame.mirrorX:SetText("水平翻转")
		frame.mirrorY = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
		frame.mirrorY:SetPoint("LEFT", frame.mirrorX, "RIGHT", 20, 0)
		frame.mirrorY:SetText("垂直翻转")

		frame.test = MakeButton(frame, "测试预览", 100)
		frame.test:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 22, 18)
		frame.save = MakeButton(frame, "保存", 80)
		frame.save:SetPoint("LEFT", frame.test, "RIGHT", 6, 0)
		frame.cancel = MakeButton(frame, "取消", 80)
		frame.cancel:SetPoint("LEFT", frame.save, "RIGHT", 6, 0)

		local function AddSlider(name, x, y, minValue, maxValue, step, key, editField)
			local slider = CreateFrame("Slider", name, frame, "OptionsSliderTemplate")
			slider:SetSize(140, 24)
			slider:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
			slider:SetMinMaxValues(minValue, maxValue)
			slider:SetValueStep(step)
			slider:SetObeyStepOnDrag(true)
			slider:SetScript("OnValueChanged", function(self, value)
				if not editFrame.draft then return end
				editFrame.draft[key] = value
				if editField then editField:SetText(tostring(value)) end
				RefreshPreview(editFrame)
			end)
			return slider
		end
		frame.xSlider = AddSlider("NSAXSlider", 280, -86, -1000, 1000, 1, "x", frame.posX)
		frame.ySlider = AddSlider("NSAYSlider", 280, -116, -1000, 1000, 1, "y", frame.posY)
		frame.sizeSlider = AddSlider("NSASizeSlider", 280, -146, 32, 512, 1, "size", frame.size)
		frame.opacitySlider = AddSlider("NSAOpacitySlider", 280, -176, 0.05, 1, 0.05, "opacity", frame.opacity)

		frame.prevTexture:SetScript("OnClick", function()
			local draft = editFrame.draft
			local number = tonumber((draft.texture or "Aura1.tga"):match("(%d+)")) or 1
			number = (number - 2 + MAX_TEXTURES) % MAX_TEXTURES + 1
			draft.texture = "Aura" .. number .. ".tga"
			editFrame.preview:SetTexture(GetTexturePath(draft.texture))
			editFrame.textureName:SetText(draft.texture)
			editFrame.texturePath:SetText(draft.texture)
		end)
		frame.nextTexture:SetScript("OnClick", function()
			local draft = editFrame.draft
			local number = tonumber((draft.texture or "Aura1.tga"):match("(%d+)")) or 1
			number = number % MAX_TEXTURES + 1
			draft.texture = "Aura" .. number .. ".tga"
			editFrame.textureName:SetText(draft.texture)
			editFrame.texturePath:SetText(draft.texture)
			RefreshPreview(editFrame)
		end)
		frame.animation:SetScript("OnClick", function()
			local draft = editFrame.draft
			local current = 1
			for i, value in ipairs(ANIMATION_ORDER) do
				if value == draft.animation then
					current = i
					break
				end
			end
			draft.animation = ANIMATION_ORDER[current % #ANIMATION_ORDER + 1]
			frame.animation:SetText(ANIMATION_NAMES[draft.animation])
			RefreshPreview(editFrame)
		end)
		frame.animationDuration:SetScript("OnTextChanged", function(self)
			if editFrame.draft and self:HasFocus() then
				editFrame.draft.animationDuration = tonumber(self:GetText()) or 2.4
				RefreshPreview(editFrame)
			end
		end)
		frame.animationScale:SetScript("OnTextChanged", function(self)
			if editFrame.draft and self:HasFocus() then
				editFrame.draft.animationScale = tonumber(self:GetText()) or 1.25
				RefreshPreview(editFrame)
			end
		end)
		local function BindDraftNumber(edit, key, fallback)
			edit:SetScript("OnTextChanged", function(self)
				if editFrame.draft and self:HasFocus() then
					editFrame.draft[key] = tonumber(self:GetText()) or fallback
					RefreshPreview(editFrame)
				end
			end)
		end
		BindDraftNumber(frame.posX, "x", 0)
		BindDraftNumber(frame.posY, "y", 0)
		BindDraftNumber(frame.size, "size", 128)
		BindDraftNumber(frame.opacity, "opacity", 1)
		BindDraftNumber(frame.timerSize, "timerSize", 44)
		BindDraftNumber(frame.timerX, "timerX", 0)
		BindDraftNumber(frame.timerY, "timerY", 0)
		frame.name:SetScript("OnTextChanged", function(self)
			if editFrame.draft and self:HasFocus() then
				editFrame.draft.name = self:GetText()
				RefreshPreview(editFrame)
			end
		end)
		frame.mirrorX:SetScript("OnClick", function(self)
			editFrame.draft.mirrorX = self:GetChecked() and true or false
			RefreshPreview(editFrame)
		end)
		frame.mirrorY:SetScript("OnClick", function(self)
			editFrame.draft.mirrorY = self:GetChecked() and true or false
			RefreshPreview(editFrame)
		end)
		frame.colorButton:SetScript("OnClick", function()
			local color = editFrame.draft.color or { 1, 1, 1, 1 }
			local info = {
				hasOpacity = true,
				r = color[1], g = color[2], b = color[3], opacity = color[4],
				swatchFunc = function()
					local r, g, b = ColorPickerFrame:GetColorRGB()
					local a = ColorPickerFrame.GetColorAlpha and ColorPickerFrame:GetColorAlpha() or color[4]
					editFrame.draft.color = { r, g, b, a }
					frame.colorSwatch:SetColorTexture(r, g, b, a)
					RefreshPreview(editFrame)
				end,
				cancelFunc = function(previous)
					if previous then
						editFrame.draft.color = { previous.r, previous.g, previous.b, previous.opacity or 1 }
						frame.colorSwatch:SetColorTexture(unpack(editFrame.draft.color))
						RefreshPreview(editFrame)
					end
				end,
			}
			if ColorPickerFrame.SetupColorPickerAndShow then
				ColorPickerFrame:SetupColorPickerAndShow(info)
			end
		end)
		frame.texturePath:SetScript("OnTextChanged", function(self)
			if editFrame and editFrame.draft and self:HasFocus() then
				editFrame.draft.texture = NormalizeTexture(self:GetText())
			editFrame.preview:SetTexture(GetTexturePath(editFrame.draft.texture))
			editFrame.textureName:SetText(editFrame.draft.texture)
			RefreshPreview(editFrame)
			end
		end)
		frame.test:SetScript("OnClick", function()
			testMode = true
			UpdateDisplay()
			C_Timer.After(3, function()
				testMode = false
				UpdateDisplay()
			end)
		end)
		frame.cancel:SetScript("OnClick", CloseEdit)
		frame.save:SetScript("OnClick", function()
			local draft = editFrame.draft
			if not draft then return end
			draft.spellID = tonumber(frame.spellID:GetText()) or draft.spellID
			draft.x = tonumber(frame.posX:GetText()) or draft.x or 0
			draft.y = tonumber(frame.posY:GetText()) or draft.y or 0
			draft.size = tonumber(frame.size:GetText()) or draft.size or 128
			draft.opacity = tonumber(frame.opacity:GetText()) or draft.opacity or 1
			draft.timerSize = tonumber(frame.timerSize:GetText()) or draft.timerSize or 44
			draft.timerX = tonumber(frame.timerX:GetText()) or draft.timerX or 0
			draft.timerY = tonumber(frame.timerY:GetText()) or draft.timerY or 0
			draft.name = frame.name:GetText() or draft.name
			draft.texture = NormalizeTexture(frame.texturePath:GetText())
			draft.animationDuration = math.max(0.2, tonumber(frame.animationDuration:GetText()) or draft.animationDuration or 2.4)
			draft.animationScale = math.max(1, math.min(3, tonumber(frame.animationScale:GetText()) or draft.animationScale or 1.25))
			draft.mirrorX = frame.mirrorX:GetChecked() and true or false
			draft.mirrorY = frame.mirrorY:GetChecked() and true or false
			draft.showTimer = frame.timer:GetChecked() and true or false
			db.auras[editKey] = draft
			RefreshGrid()
			UpdateDisplay()
			CloseEdit()
			Print("已保存特效：" .. (draft.name or ""))
		end)
	end

	editFrame.draft = CopyTable(aura)
	editFrame.preview:SetTexture(GetTexturePath(editFrame.draft.texture))
	editFrame.textureName:SetText(editFrame.draft.texture)
	editFrame.name:SetText(editFrame.draft.name or "")
	editFrame.spellID:SetText(tostring(editFrame.draft.spellID or ""))
	editFrame.posX:SetText(tostring(editFrame.draft.x or 0))
	editFrame.posY:SetText(tostring(editFrame.draft.y or 0))
	editFrame.size:SetText(tostring(editFrame.draft.size or 128))
	editFrame.opacity:SetText(tostring(editFrame.draft.opacity or 1))
	editFrame.timerSize:SetText(tostring(editFrame.draft.timerSize or 44))
	editFrame.timerX:SetText(tostring(editFrame.draft.timerX or 0))
	editFrame.timerY:SetText(tostring(editFrame.draft.timerY or 0))
	editFrame.texturePath:SetText(editFrame.draft.texture or "Aura1.tga")
	editFrame.animation:SetText(ANIMATION_NAMES[editFrame.draft.animation] or ANIMATION_NAMES.none)
	editFrame.animationDuration:SetText(tostring(editFrame.draft.animationDuration or 2.4))
	editFrame.animationScale:SetText(tostring(editFrame.draft.animationScale or 1.25))
	editFrame.colorSwatch:SetColorTexture(unpack(editFrame.draft.color or { 1, 1, 1, 1 }))
	editFrame.mirrorX:SetChecked(editFrame.draft.mirrorX and true or false)
	editFrame.mirrorY:SetChecked(editFrame.draft.mirrorY and true or false)
	editFrame.timer:SetChecked(editFrame.draft.showTimer ~= false)
	editFrame.sizeSlider:SetValue(editFrame.draft.size or 128)
	editFrame.opacitySlider:SetValue(editFrame.draft.opacity or 1)
	editFrame.xSlider:SetValue(editFrame.draft.x or 0)
	editFrame.ySlider:SetValue(editFrame.draft.y or 0)
	RefreshPreview(editFrame)
	editFrame:Show()
end

local function CreateTextEdit(parent, x, y, width, value)
	local edit = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	edit:SetSize(width, 22)
	edit:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(12)
	edit:SetText(tostring(value))
	return edit
end

local function ImportFromCooldownViewer()
	if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet) then
		Print("冷却管理器 API 不可用。请先进入游戏后再试。")
		return
	end

	local existing = {}
	for _, aura in ipairs(db.auras) do
		local spellID = tonumber(aura.spellID)
		if spellID then
			existing[spellID] = true
		end
	end

	local categories = {}
	if Enum and Enum.CooldownViewerCategory then
		categories = {
			Enum.CooldownViewerCategory.TrackedBar,
			Enum.CooldownViewerCategory.TrackedBuff,
		}
	else
		categories = { 3, 4 }
	end
	local count = 0
	for _, category in ipairs(categories) do
		local ok, cooldownIDs = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, category, true)
		if ok and cooldownIDs then
			for _, cooldownID in ipairs(cooldownIDs) do
				local okInfo, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
				if okInfo and info then
					local spellID = info.overrideTooltipSpellID or info.overrideSpellID or info.spellID or info.spellId
					if not spellID and info.overrideSpellId then spellID = info.overrideSpellId end
					if spellID and not existing[spellID] then
						existing[spellID] = true
						local newAura = CreateDefaultAura(spellID)
		table.insert(db.auras, newAura)
						count = count + 1
					end
				end
			end
		end
	end
	RefreshGrid()
	UpdateDisplay()
	Print("已导入 " .. count .. " 个技能。双击图标可编辑。")
end

local function AddSpell(spellID)
	spellID = tonumber(spellID)
	if not spellID or spellID <= 0 then
		Print("用法：/nsa add 法术ID，例如 /nsa add 51271")
		return
	end
	for _, aura in ipairs(db.auras) do
		if tonumber(aura.spellID) == spellID then
			Print("这个法术已经存在于列表中。")
			return
		end
	end
	local info = GetSpellInfoSafe(spellID)
	local newAura = CreateDefaultAura(spellID)
	table.insert(db.auras, newAura)
	RefreshGrid()
	UpdateDisplay()
	Print("已添加 " .. ((info and info.name) or spellID) .. "。")
end

local CreateOptionsFrame

local function GetCDMFrameSpellID(frame)
	if not frame or not frame.cooldownID or not C_CooldownViewer then
		return nil
	end
	local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, frame.cooldownID)
	if not ok or not info then
		return nil
	end
	return info.overrideTooltipSpellID or info.overrideSpellID or info.spellID or info.spellId or info.overrideSpellId
end

local function FindAuraBySpellID(spellID)
	for index, aura in ipairs(db.auras) do
		if tonumber(aura.spellID) == tonumber(spellID) then
			return index, aura
		end
	end
end

local function ShowCDMContextMenu(frame)
	local spellID = GetCDMFrameSpellID(frame)
	if not spellID or not MenuUtil or not MenuUtil.CreateContextMenu then
		return
	end
	MenuUtil.CreateContextMenu(frame, function(_, rootDescription)
		local index = FindAuraBySpellID(spellID)
		local info = GetSpellInfoSafe(spellID)
		local title = (info and info.name) or ("Spell " .. tostring(spellID))
		rootDescription:CreateTitle(title)
		if index then
			rootDescription:CreateButton("Remove from NewStatusAuras", function()
				table.remove(db.auras, index)
				selectedKey = nil
				RefreshGrid()
				UpdateDisplay()
			end)
			rootDescription:CreateButton("Edit in NewStatusAuras", function()
				selectedKey = index
				OpenEdit(index)
			end)
		else
			rootDescription:CreateButton("Assign to NewStatusAuras", function()
				AddSpell(spellID)
			end)
		end
		rootDescription:CreateButton("Open NewStatusAuras", function()
			CreateOptionsFrame()
			selectedKey = index or selectedKey
			RefreshGrid()
			optionsFrame:Show()
		end)
	end)
end

local function InstallCDMContextMenus()
	for _, viewerName in ipairs(cdmViewers) do
		local viewer = _G[viewerName]
		if viewer and viewer.itemFramePool then
			if not viewer.nsaDataHooked then
				viewer.nsaDataHooked = true
				if viewer.RefreshLayout then hooksecurefunc(viewer, "RefreshLayout", ResetCDMKeyCache) end
				if viewer.RefreshData then hooksecurefunc(viewer, "RefreshData", ResetCDMKeyCache) end
			end
			local function hookFrame(_, frame)
				if frame.nsaContextHooked then return end
				frame.nsaContextHooked = true
				local cooldown = frame.Cooldown or frame.cooldown
				if cooldown and cooldown.SetCooldownFromDurationObject then
					hooksecurefunc(cooldown, "SetCooldownFromDurationObject", function(_, durationObject)
						frame.nsaDurationObject = durationObject
					end)
					if cooldown.SetCooldown then
						hooksecurefunc(cooldown, "SetCooldown", function(_, startTime, duration, modRate)
							frame.nsaCooldownStart = startTime
							frame.nsaCooldownDuration = duration
							frame.nsaCooldownModRate = modRate
						end)
					end
					if cooldown.Clear then
						hooksecurefunc(cooldown, "Clear", function()
							frame.nsaDurationObject = nil
							frame.nsaCooldownStart = nil
							frame.nsaCooldownDuration = nil
						end)
					end
				end
				frame:HookScript("OnMouseUp", function(self, button)
					if button == "RightButton" and not (InCombatLockdown and InCombatLockdown()) then
						ShowCDMContextMenu(self)
					end
				end)
			end
			if viewer.OnAcquireItemFrame then
				hooksecurefunc(viewer, "OnAcquireItemFrame", hookFrame)
			end
			for frame in viewer.itemFramePool:EnumerateActive() do
				hookFrame(viewer, frame)
			end
		end
	end
end

local function CreateExportDialog(selectedOnly)
	local dialog = CreateFrame("Frame", "NSAExportDialog", UIParent, "BackdropTemplate")
	dialog:SetSize(560, 330)
	dialog:SetPoint("CENTER")
	dialog:SetFrameStrata("DIALOG")
	AddBackdrop(dialog)
	tinsert(UISpecialFrames, "NSAExportDialog")

	local title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", dialog, "TOP", 0, -12)
	title:SetText("复制以下字符串：")
	local edit = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
	edit:SetMultiLine(true)
	edit:SetSize(520, 250)
	edit:SetPoint("TOP", title, "BOTTOM", 0, -10)
	edit:SetFont(STANDARD_TEXT_FONT, 11, "")
	edit:SetText(ExportString(selectedOnly))
	edit:HighlightText()
	local close = CreateFrame("Button", nil, dialog, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() dialog:Hide() end)
end

local function CreateImportDialog()
	local dialog = CreateFrame("Frame", "NSAImportDialog", UIParent, "BackdropTemplate")
	dialog:SetSize(560, 330)
	dialog:SetPoint("CENTER")
	dialog:SetFrameStrata("DIALOG")
	AddBackdrop(dialog)
	tinsert(UISpecialFrames, "NSAImportDialog")

	local title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", dialog, "TOP", 0, -12)
	title:SetText("粘贴字符串后点导入：")
	local edit = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
	edit:SetMultiLine(true)
	edit:SetSize(520, 235)
	edit:SetPoint("TOP", title, "BOTTOM", 0, -10)
	edit:SetFont(STANDARD_TEXT_FONT, 11, "")
	local okButton = MakeButton(dialog, "导入", 80)
	okButton:SetPoint("BOTTOM", dialog, "BOTTOM", 0, 12)
	okButton:SetScript("OnClick", function()
		local ok, message = ImportString(edit:GetText())
		Print(message)
		if ok then
			RefreshGrid()
			UpdateDisplay()
			dialog:Hide()
		end
	end)
	local close = CreateFrame("Button", nil, dialog, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() dialog:Hide() end)
end

CreateOptionsFrame = function()
	if optionsFrame then return end

	local frame = CreateFrame("Frame", "NSAOptionsFrame", UIParent, "BackdropTemplate")
	frame:SetSize(620, 535)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	AddBackdrop(frame)
	tinsert(UISpecialFrames, "NSAOptionsFrame")
	optionsFrame = frame

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", frame, "TOP", 0, -14)
	title:SetText("NEW STATUS AURAS")
	local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	subtitle:SetPoint("TOP", title, "BOTTOM", 0, -2)
	subtitle:SetText("TGA 光环 · 暴雪追踪增益联动")
	local versionInfo = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	versionInfo:SetPoint("TOP", subtitle, "BOTTOM", 0, -4)
	versionInfo:SetWidth(580)
	versionInfo:SetJustifyH("CENTER")
	versionInfo:SetText("版本 1.4.2  |  游戏版本：正式服 12.1  |  插件：NewStatusAuras  |  作者：梅超風-白银之手")
	versionInfo:SetTextColor(0.72, 0.72, 0.72)

	local grid = CreateFrame("Frame", nil, frame)
	grid:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -70)
	grid:SetSize(570, 300)
	frame.gridParent = grid

	local newButton = MakeButton(frame, "新建", 80)
	newButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -365)
	newButton:SetScript("OnClick", function()
		local newAura = CreateDefaultAura()
		newAura.name = "光环" .. (#db.auras + 1)
		table.insert(db.auras, newAura)
		selectedKey = #db.auras
		RefreshGrid()
	end)

	local deleteButton = MakeButton(frame, "删除", 80)
	deleteButton:SetPoint("LEFT", newButton, "RIGHT", 6, 0)
	deleteButton:SetScript("OnClick", function()
		for index = #db.auras, 1, -1 do
			if db.auras[index].selected or index == selectedKey then
				table.remove(db.auras, index)
			end
		end
		selectedKey = nil
		RefreshGrid()
		UpdateDisplay()
	end)

	local editButton = MakeButton(frame, "编辑", 80)
	editButton:SetPoint("LEFT", deleteButton, "RIGHT", 6, 0)
	editButton:SetScript("OnClick", function()
		if selectedKey and db.auras[selectedKey] then
			OpenEdit(selectedKey)
		else
			Print("先选择一个特效。")
		end
	end)
	frame.openEdit = OpenEdit

	local importButton = MakeButton(frame, "打开冷却管理", 145)
	importButton:SetPoint("LEFT", editButton, "RIGHT", 6, 0)
	importButton:SetScript("OnClick", OpenCooldownManager)

	local selectAllButton = MakeButton(frame, "全选", 58)
	selectAllButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -397)
	selectAllButton:SetScript("OnClick", function()
		for _, aura in ipairs(db.auras) do aura.selected = true end
		RefreshGrid()
	end)
	local clearButton = MakeButton(frame, "清除选择", 75)
	clearButton:SetPoint("LEFT", selectAllButton, "RIGHT", 6, 0)
	clearButton:SetScript("OnClick", function()
		for _, aura in ipairs(db.auras) do aura.selected = false end
		RefreshGrid()
	end)
	local exportButton = MakeButton(frame, "导出所选", 80)
	exportButton:SetPoint("LEFT", clearButton, "RIGHT", 6, 0)
	exportButton:SetScript("OnClick", function() CreateExportDialog(true) end)
	local importStringButton = MakeButton(frame, "导入", 65)
	importStringButton:SetPoint("LEFT", exportButton, "RIGHT", 6, 0)
	importStringButton:SetScript("OnClick", CreateImportDialog)
	local testButton = MakeButton(frame, "测试光环", 80)
	testButton:SetPoint("LEFT", importStringButton, "RIGHT", 6, 0)
	testButton:SetScript("OnClick", function()
		testMode = true
		UpdateDisplay()
		C_Timer.After(3, function()
			testMode = false
			UpdateDisplay()
		end)
	end)

	local profileLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	profileLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -432)
	profileLabel:SetText("配置文件")
	frame.profileDropdown = CreateFrame("Frame", "NSAProfileDropdown", frame, "UIDropDownMenuTemplate")
	frame.profileDropdown:SetPoint("TOPLEFT", frame, "TOPLEFT", 72, -424)
	UIDropDownMenu_SetWidth(frame.profileDropdown, 145)
	frame.profileName = CreateTextEdit(frame, 235, -426, 115, "")
	frame.profileName:SetMaxLetters(32)
	local newProfile = MakeButton(frame, "新建配置", 82)
	newProfile:SetPoint("LEFT", frame.profileName, "RIGHT", 6, 0)
	newProfile:SetScript("OnClick", function()
		local name = strtrim(frame.profileName:GetText() or "")
		if name == "" then return end
		rootDB.profiles[name] = CopyTable(db)
		rootDB.profileKeys[currentCharacterKey] = name
		db = rootDB.profiles[name]
		EnsureDatabase()
		RefreshGrid()
		UpdateDisplay()
	end)
	UIDropDownMenu_Initialize(frame.profileDropdown, function()
		for profileName in pairs(rootDB.profiles) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = profileName
			info.checked = (rootDB.profileKeys[currentCharacterKey] == profileName)
			info.func = function()
				rootDB.profileKeys[currentCharacterKey] = profileName
				db = rootDB.profiles[profileName]
				EnsureDatabase()
				UIDropDownMenu_SetText(frame.profileDropdown, profileName)
				RefreshGrid()
				UpdateDisplay()
			end
			UIDropDownMenu_AddButton(info)
		end
	end)
	UIDropDownMenu_SetText(frame.profileDropdown, rootDB.profileKeys[currentCharacterKey] or "默认")
end

local profileFrame

local function RefreshProfileDropdown(dropdown)
	if not dropdown then return end
	UIDropDownMenu_Initialize(dropdown, function()
		for profileName in pairs(rootDB.profiles or {}) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = profileName
			info.checked = (rootDB.profileKeys[currentCharacterKey] == profileName)
			info.func = function()
				UIDropDownMenu_SetText(dropdown, profileName)
				dropdown.selectedProfile = profileName
			end
			UIDropDownMenu_AddButton(info)
		end
	end)
	UIDropDownMenu_SetText(dropdown, rootDB.profileKeys[currentCharacterKey] or currentClassKey or "默认")
end

local function ApplySelectedProfile(profileName)
	if not profileName or not rootDB.profiles[profileName] then return end
	rootDB.profileKeys[currentCharacterKey] = profileName
	db = rootDB.profiles[profileName]
	EnsureDatabase()
	if optionsFrame and optionsFrame.profileDropdown then
		UIDropDownMenu_SetText(optionsFrame.profileDropdown, profileName)
	end
	RefreshGrid()
	UpdateDisplay()
end

local function CreateProfileFrame()
	if profileFrame then
		RefreshProfileDropdown(profileFrame.dropdown)
		profileFrame:Show()
		return
	end
	local frame = CreateFrame("Frame", "NSAProfileFrame", UIParent, "BackdropTemplate")
	frame:SetSize(560, 340)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	AddBackdrop(frame)
	tinsert(UISpecialFrames, "NSAProfileFrame")
	profileFrame = frame

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", frame, "TOP", 0, -16)
	title:SetText("NewStatusAuras 配置文件")
	local description = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	description:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -56)
	description:SetText("配置文件可以按角色或职业独立保存。")
	local character = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	character:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -86)
	character:SetText("当前角色：" .. tostring(currentCharacterKey) .. "    职业：" .. tostring(currentClassKey))

	local profileLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	profileLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -126)
	profileLabel:SetText("当前配置：")
	frame.dropdown = CreateFrame("Frame", "NSAStandaloneProfileDropdown", frame, "UIDropDownMenuTemplate")
	frame.dropdown:SetPoint("TOPLEFT", frame, "TOPLEFT", 88, -118)
	UIDropDownMenu_SetWidth(frame.dropdown, 190)
	RefreshProfileDropdown(frame.dropdown)

	local name = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	name:SetSize(180, 22)
	name:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -178)
	name:SetAutoFocus(false)
	name:SetMaxLetters(32)
	frame.name = name

	local create = MakeButton(frame, "新建并复制当前", 125)
	create:SetPoint("LEFT", name, "RIGHT", 8, 0)
	create:SetScript("OnClick", function()
		local newName = strtrim(name:GetText() or "")
		if newName == "" then return end
		rootDB.profiles[newName] = CopyTable(db)
		ApplySelectedProfile(newName)
		RefreshProfileDropdown(frame.dropdown)
		name:SetText("")
	end)

	local classButton = MakeButton(frame, "使用当前职业配置", 125)
	classButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -220)
	classButton:SetScript("OnClick", function()
		rootDB.profiles[currentClassKey] = rootDB.profiles[currentClassKey] or CopyTable(db)
		rootDB.profiles[currentClassKey].profileType = "职业"
		rootDB.profiles[currentClassKey].class = currentClassKey
		ApplySelectedProfile(currentClassKey)
		RefreshProfileDropdown(frame.dropdown)
	end)

	local apply = MakeButton(frame, "应用选中配置", 110)
	apply:SetPoint("LEFT", classButton, "RIGHT", 8, 0)
	apply:SetScript("OnClick", function()
		ApplySelectedProfile(frame.dropdown.selectedProfile or rootDB.profileKeys[currentCharacterKey])
	end)

	local open = MakeButton(frame, "打开光环设置", 110)
	open:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -264)
	open:SetScript("OnClick", function()
		CreateOptionsFrame()
		RefreshGrid()
		optionsFrame:Show()
	end)

	local byline = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	byline:SetPoint("BOTTOM", frame, "BOTTOM", 0, 18)
	byline:SetText("(by：梅超風-白银之手)")
	byline:SetTextColor(0.7, 0.7, 0.7)
	frame:Show()
end

local function RegisterAddonSettings()
	if NewStatusAurasSettingsCategory then return end
	local panel = CreateFrame("Frame", "NewStatusAurasSettingsPanel")
	panel.name = "NewStatusAuras"
	panel:HookScript("OnShow", function(self)
		if self._built then return end
		self._built = true
		local title = self:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
		title:SetPoint("TOPLEFT", 24, -24)
		title:SetText("NEW STATUS AURAS")
		local meta = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		meta:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
		local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
		local version = getMeta and getMeta(ADDON_NAME, "Version") or "1.4.2"
		local interface = getMeta and getMeta(ADDON_NAME, "X-Interface") or "120105"
		local modified = getMeta and getMeta(ADDON_NAME, "X-Last-Modified") or "2026-09-29"
		meta:SetText("版本：" .. tostring(version) .. "    游戏版本：正式服 12.1（" .. tostring(interface) .. "）\n最后修改：" .. tostring(modified) .. "\n插件：NewStatusAuras\n作者：梅超風-白银之手")
		local note = self:CreateFontString(nil, "ARTWORK", "GameFontDisable")
		note:SetPoint("TOPLEFT", meta, "BOTTOMLEFT", 0, -18)
		note:SetText("TGA 光环显示与暴雪冷却管理器追踪增益联动")
		local open = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
		open:SetSize(150, 24)
		open:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -18)
		open:SetText("打开光环设置")
		open:SetScript("OnClick", function()
			CreateOptionsFrame()
			RefreshGrid()
			optionsFrame:Show()
		end)
		local profiles = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
		profiles:SetSize(150, 24)
		profiles:SetPoint("LEFT", open, "RIGHT", 8, 0)
		profiles:SetText("配置文件")
		profiles:SetScript("OnClick", CreateProfileFrame)
		local byline = self:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		byline:SetPoint("BOTTOMLEFT", 24, 24)
		byline:SetText("(by：梅超風-白银之手)")
	end)
	if Settings and Settings.RegisterCanvasLayoutCategory then
		local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
		Settings.RegisterAddOnCategory(category)
		NewStatusAurasSettingsCategory = category
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(panel)
		NewStatusAurasSettingsCategory = panel
	end
end

-- ---------------------------------------------------------------------------
-- 初始化与命令
-- ---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterUnitEvent("UNIT_AURA", "player")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
eventFrame:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
eventFrame:SetScript("OnEvent", function(self, event, ...)
	if event == "ADDON_LOADED" then
		local loadedName = select(1, ...)
		if loadedName == "Blizzard_CooldownViewer" then
			ResetCDMKeyCache()
			HideBlizzardTrackedBars()
			InstallCDMContextMenus()
		end
		return
	end
	if event == "PLAYER_LOGIN" then
		SelectProfileDatabase()
		EnsureDatabase()
		RegisterAddonSettings()
		InstallCDMContextMenus()
		Print("加载完成，共 " .. #db.auras .. " 个特效。输入 /nsa 打开设置。")
	end
	if event == "COOLDOWN_VIEWER_DATA_LOADED" or event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
		ResetCDMKeyCache()
		InstallCDMContextMenus()
	end
	if event == "PLAYER_REGEN_ENABLED" and nativeAuraRebuildPending then
		RebuildNativeAuraContainers()
	end
	UpdateDisplay()
end)

eventFrame:SetScript("OnUpdate", function(self, elapsed)
	updateElapsed = updateElapsed + elapsed
	if updateElapsed < UPDATE_INTERVAL then
		return
	end
	updateElapsed = 0
	UpdateDisplay()
end)

SLASH_NEWSTATUSAURAS1 = "/nsa"
SLASH_NEWSTATUSAURAS2 = "/newstatusauras"
SlashCmdList.NEWSTATUSAURAS = function(message)
	local command = strlower(strtrim(message or ""))
	if command == "import" then
		ImportFromCooldownViewer()
	elseif command == "cdm" then
		OpenCooldownManager()
	elseif command == "profiles" then
		CreateProfileFrame()
	elseif command:match("^add%s+") then
		AddSpell(command:match("^add%s+(.+)$"))
	elseif command == "test" then
		testMode = true
		UpdateDisplay()
		C_Timer.After(3, function()
			testMode = false
			UpdateDisplay()
		end)
	else
		CreateOptionsFrame()
		selectedKey = selectedKey or (#db.auras > 0 and 1 or nil)
		RefreshGrid()
		optionsFrame:Show()
	end
end
