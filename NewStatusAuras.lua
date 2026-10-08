local ADDON_NAME = ...
local ADDON_VERSION = "1.7.1"

NewStatusAurasDB = NewStatusAurasDB or {}
local rootDB
NewStatusAurasClassDB = NewStatusAurasClassDB or {}
local classRootDB = NewStatusAurasClassDB
-- 注入诊断：在 ADDON_LOADED（SavedVariables 注入完成后）记录注入的光环数据量
local LOAD_INJECT_PROFILES, LOAD_INJECT_AURAS, LOAD_INJECT_GLOBAL_AURAS = 0, 0, 0
local developerConfig = NewStatusAurasDeveloperConfig or {}
local fontOptions = developerConfig.fonts or { { key = "standard", name = "系统默认", path = STANDARD_TEXT_FONT } }
local db
local optionsFrame
local editFrame
local selectedKey
local editKey
local auraClipboard
local auraClipboardSource
local auraFrames = {}
local nativeContainers = {}
local nativeMode = false
local nativeSignature
local rebuildPending = false
local testMode = false
local previewing = false
local previewKey
local previewDraft
local RefreshGrid
local UpdateDisplay

local function NextAuraID()
	rootDB.nextAuraID = (tonumber(rootDB.nextAuraID) or 0) + 1
	return rootDB.nextAuraID
end

local function NormalizeColor(color)
	color = type(color) == "table" and color or {}
	return {
		math.max(0, math.min(1, tonumber(color[1]) or 1)),
		math.max(0, math.min(1, tonumber(color[2]) or 1)),
		math.max(0, math.min(1, tonumber(color[3]) or 1)),
		math.max(0, math.min(1, tonumber(color[4]) or 1)),
	}
end

local function GetFontPath(key)
	for _, entry in ipairs(fontOptions) do
		if entry.key == key then return entry.path or STANDARD_TEXT_FONT end
	end
	return STANDARD_TEXT_FONT
end

local function GetFontName(key)
	for _, entry in ipairs(fontOptions) do
		if entry.key == key then return entry.name or entry.key end
	end
	return "系统默认"
end

local ADDON_ROOT = "Interface\\AddOns\\NewStatusAuras\\"
local TEXTURE_DIR = ADDON_ROOT .. "Media\\Auras\\"
local MAX_TEXTURES = 145
local TEXTURE_GROUPS = {
	{
		name = "光环图库（Media\\Auras）",
		folder = "",
		files = function()
			local files = {}
			for number = 1, MAX_TEXTURES do files[#files + 1] = "Aura" .. number .. ".tga" end
			return files
		end,
	},
}

local ANIMATION_NAMES = {
	none = "无动画",
	rotate = "旋转",
	fade = "渐隐",
	pulse = "脉冲",
	stretch = "拉伸",
	spinFade = "旋转 + 渐隐",
	wipeDown = "从上到下消失",
	wipeUp = "从下到上消失",
	fadeDown = "渐隐（上到下）",
	fadeUp = "渐隐（下到上）",
}
local ANIMATION_ORDER = { "none", "rotate", "fade", "pulse", "stretch", "spinFade", "wipeDown", "wipeUp", "fadeDown", "fadeUp" }

local function CopyTable(source)
	local result = {}
	for key, value in pairs(source or {}) do
		result[key] = type(value) == "table" and CopyTable(value) or value
	end
	return result
end

local function CountAuras(profile)
	local count = 0
	if type(profile) == "table" and type(profile.auras) == "table" then
		for _, aura in pairs(profile.auras) do
			if type(aura) == "table" then count = count + 1 end
		end
	end
	return count
end

local function Print(message)
	print("|cff66ccff[NSA]|r " .. tostring(message or ""))
end

local function GetSpellInfoSafe(spellID)
	spellID = tonumber(spellID)
	if not spellID or spellID <= 0 then return nil end
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
		if ok and info then return info end
	end
	if GetSpellInfo then
		local ok, name, _, icon = pcall(GetSpellInfo, spellID)
		if ok and name then return { name = name, iconID = icon } end
	end
end

local function NormalizeTexture(value)
	local path = tostring(value or ""):gsub("/", "\\")
	path = path:gsub("^%s+", ""):gsub("%s+$", "")
	return path ~= "" and path or "Aura1.tga"
end

local function GetTexturePath(value)
	local path = NormalizeTexture(value)
	if path:match("^Interface\\") then return path end
	if path:match("^Media\\") or path:match("^media\\") then return ADDON_ROOT .. path end
	if path:match("^Auras\\") or path:match("^auras\\") then return ADDON_ROOT .. "Media\\" .. path end
	return TEXTURE_DIR .. path
end

local function CreateDefaultAura(spellID)
	local info = GetSpellInfoSafe(spellID)
	return {
		id = NextAuraID(),
		name = (info and info.name) or "新光环",
		spellID = tonumber(spellID) or 0,
		texture = "Aura1.tga",
		size = 160, x = 0, y = 0, opacity = 1,
		showTimer = true, timerSize = 44, timerX = 0, timerY = 0,
		timerFont = "standard",
		timerColor = { 1, 1, 1, 1 }, color = { 1, 1, 1, 1 },
		enabled = true, animation = "none", animationDuration = 2.4,
		animationScale = 1.25, mirrorX = false, mirrorY = false,
	}
end

local function SelectProfileDatabase()
	if not rootDB then rootDB = NewStatusAurasDB or {} end
	rootDB.profiles = rootDB.profiles or {}
	local characterKey = (UnitName("player") or "Player") .. "-" .. (GetRealmName and GetRealmName() or "Realm")
	local classKey = select(2, UnitClass("player")) or "DEFAULT"
	local profile = rootDB.profiles[classKey]
	if type(profile) ~= "table" or CountAuras(profile) == 0 then
		-- 严格按职业隔离：只迁移"同职业"的旧版数据，绝不从 rootDB.auras 继承其他职业的光环
		local legacyProfile = rootDB.classProfiles and rootDB.classProfiles[classKey]
		local legacyClassProfile = classRootDB[classKey]
		if type(legacyProfile) == "table" and CountAuras(legacyProfile) > 0 then
			profile = CopyTable(legacyProfile)
		elseif type(legacyClassProfile) == "table" and CountAuras(legacyClassProfile) > 0 then
			profile = CopyTable(legacyClassProfile)
		else
			-- 旧版全局列表：仅当整个数据库从未迁移过、且当前职业确实没有配置时，一次性迁入
			if not rootDB.legacyMigrated then
				local hasAnyProfile = false
				for _, p in pairs(rootDB.profiles) do
					if type(p) == "table" and CountAuras(p) > 0 then hasAnyProfile = true break end
				end
				if not hasAnyProfile and type(rootDB.auras) == "table" and CountAuras({ auras = rootDB.auras }) > 0 then
					profile = { auras = CopyTable(rootDB.auras), settings = CopyTable(rootDB.settings or {}) }
				end
				rootDB.legacyMigrated = true
			end
			profile = profile or { auras = {}, settings = {} }
		end
	end
	profile.class, profile.profileType = classKey, "职业"
	rootDB.profiles[classKey] = profile
	db = profile
	db.characterKey, db.profileName = characterKey, classKey
end

local function EnsureDatabase()
	db.auras = db.auras or {}
	db.settings = db.settings or {}
	local usedIDs = {}
	for index, aura in ipairs(db.auras) do
		aura.name = aura.name and aura.name ~= "" and aura.name or ("光环 " .. index)
		aura.texture = NormalizeTexture(aura.texture)
		aura.size = tonumber(aura.size) or 160
		aura.x, aura.y = tonumber(aura.x) or 0, tonumber(aura.y) or 0
		aura.opacity = tonumber(aura.opacity) or 1
		if aura.showTimer == nil then aura.showTimer = true end
		if aura.enabled == nil then aura.enabled = true end
		aura.timerSize = tonumber(aura.timerSize) or 44
		aura.timerX, aura.timerY = tonumber(aura.timerX) or 0, tonumber(aura.timerY) or 0
		aura.timerFont = aura.timerFont or "standard"
		aura.color = NormalizeColor(aura.color)
		aura.timerColor = NormalizeColor(aura.timerColor)
		aura.id = tonumber(aura.id)
		if not aura.id or usedIDs[aura.id] then aura.id = NextAuraID() end
		usedIDs[aura.id] = true
		rootDB.nextAuraID = math.max(tonumber(rootDB.nextAuraID) or 0, aura.id)
		aura.animation = aura.animation or "none"
		aura.animationDuration = tonumber(aura.animationDuration) or 2.4
		aura.animationScale = tonumber(aura.animationScale) or 1.25
	end
end

local function RecoverNonEmptyProfile()
	return db and CountAuras(db) > 0
end

local function RefreshLoadedProfile()
	if not db or CountAuras(db) == 0 then
		SelectProfileDatabase()
		EnsureDatabase()
	end
	UpdateDisplay()
end

local function ReportLoadedProfile()
	local ok, message = pcall(RefreshLoadedProfile)
	if not ok then
		Print("读取配置时发生错误：" .. tostring(message))
		return
	end
	Print("已加载 " .. CountAuras(db) .. " 个光环（配置：" .. tostring(db.profileName or "默认") .. "）。输入 /nsa 打开设置。")
end

local function SaveCurrentDatabase()
	if not rootDB then rootDB = NewStatusAurasDB or {} end
	if not db then return end
	rootDB.profiles = rootDB.profiles or {}
	rootDB.profileKeys = rootDB.profileKeys or {}
	local profileName = db.class or db.profileName or "DEFAULT"
	if db.characterKey then rootDB.profileKeys[db.characterKey] = profileName end
	db.profileName, db.profileType = profileName, "职业"
	rootDB.profiles[profileName] = db
	rootDB.profiles[profileName].auras = db.auras
	rootDB.lastSavedProfile = profileName
	rootDB.lastSavedAuraCount = CountAuras(db)
	rootDB.lastSavedAt = date and date("%Y-%m-%d %H:%M:%S") or tostring(GetTime and GetTime() or 0)
	rootDB.nextAuraID = tonumber(rootDB.nextAuraID) or 0
end

local function FindAuraIndex(id)
	for index, aura in ipairs(db.auras) do if aura.id == id then return index end end
end

local function MakeUniqueAuraName(baseName)
	baseName = tostring(baseName or "光环")
	if baseName == "" then baseName = "光环" end
	local used = {}
	for _, aura in ipairs(db.auras) do used[aura.name or ""] = true end
	if not used[baseName] then return baseName end
	local suffix = 1
	while used[baseName .. suffix] do suffix = suffix + 1 end
	return baseName .. suffix
end

local function Serialize(value)
	if type(value) == "table" then
		local result, first = { "{" }, true
		for key, item in pairs(value) do
			if not first then result[#result + 1] = "," end
			first = false
			local serializedKey = type(key) == "string" and "[\"" .. key:gsub("\\", "\\\\"):gsub("\"", "\\\"") .. "\"]" or "[" .. tostring(key) .. "]"
			result[#result + 1] = serializedKey .. "=" .. Serialize(item)
		end
		result[#result + 1] = "}"
		return table.concat(result)
	elseif type(value) == "string" then
		return "\"" .. value:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n") .. "\""
	elseif type(value) == "number" or type(value) == "boolean" then
		return tostring(value)
	end
	return "nil"
end

local function ExportString(selectedOnly)
	local data = {}
	for _, aura in ipairs(db.auras) do
		if not selectedOnly or aura.selected then data[#data + 1] = CopyTable(aura) end
	end
	return "NSA1:" .. Serialize(data)
end

local function ImportString(value)
	value = strtrim(value or "")
	if value:sub(1, 5) ~= "NSA1:" then return false, "无效的 NSA 导入字符串。" end
	local code = value:sub(6)
	if not code:match("^return") then code = "return " .. code end
	local loader = loadstring or load
	local fn, errorMessage = loader(code)
	if not fn then return false, "解析失败：" .. tostring(errorMessage) end
	local ok, data = pcall(fn)
	if not ok or type(data) ~= "table" then return false, "导入的数据无效。" end
	local count = 0
	for _, sourceAura in ipairs(data) do
		if type(sourceAura) == "table" then
			local aura = CopyTable(sourceAura)
			aura.id = NextAuraID()
			aura.name = MakeUniqueAuraName(aura.name)
			aura.selected = false
			table.insert(db.auras, aura)
			count = count + 1
		end
	end
	EnsureDatabase()
	SaveCurrentDatabase()
	return true, "已导入 " .. count .. " 个光环，并追加到当前配置。"
end

local function GetPlayerAura(spellID)
	if not C_UnitAuras then return nil end
	if C_UnitAuras.GetPlayerAuraBySpellID then
		local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
		if ok and aura then return aura end
	end
	if C_UnitAuras.GetUnitAuraBySpellID then
		local ok, aura = pcall(C_UnitAuras.GetUnitAuraBySpellID, "player", spellID)
		if ok and aura then return aura end
	end
	if C_UnitAuras.GetAuraDataByIndex then
		for index = 1, 40 do
			local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, "HELPFUL")
			if not ok or not aura then break end
			if aura.spellId == spellID or aura.spellID == spellID then return aura end
		end
	end
end

local cdmViewers = { "BuffBarCooldownViewer", "BuffIconCooldownViewer" }
local cdmKeys = {}
local function ResetCDMCache() wipe(cdmKeys) end
local function GetCDMKeys(cooldownID)
	if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCooldownInfo then return nil end
	if cdmKeys[cooldownID] then return cdmKeys[cooldownID] end
	local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
	if not ok or not info then return nil end
	local keys = {}
	for _, field in ipairs({ "spellID", "spellId", "overrideSpellID", "overrideSpellId", "overrideTooltipSpellID" }) do
		if type(info[field]) == "number" then keys[info[field]] = true end
	end
	cdmKeys[cooldownID] = keys
	return keys
end

local function GetCDMTrackedAura(spellID)
	if not C_CooldownViewer then return nil end
	for _, viewerName in ipairs(cdmViewers) do
		local viewer = _G[viewerName]
		local pool = viewer and viewer.itemFramePool
		if pool and pool.EnumerateActive then
			for frame in pool:EnumerateActive() do
				local keys = frame.cooldownID and GetCDMKeys(frame.cooldownID)
				if keys and keys[spellID] then
					local cooldown = frame.Cooldown or frame.cooldown
					local startTime, duration, modRate
					if cooldown and cooldown.GetCooldownTimes then
						local ok, start, dur, rate = pcall(cooldown.GetCooldownTimes, cooldown)
						if ok then startTime, duration, modRate = start, dur, rate end
					end
					local durationObject = frame.nsaDurationObject
					if not durationObject and frame.auraInstanceID and C_UnitAuras.GetAuraDuration then
						local ok, object = pcall(C_UnitAuras.GetAuraDuration, "player", frame.auraInstanceID)
						if ok then durationObject = object end
					end
					return { active = frame.auraInstanceID ~= nil, frame = frame, durationObject = durationObject, startTime = startTime, duration = duration, modRate = modRate }
				end
			end
		end
	end
end

local function HideBlizzardBars()
	local viewer = _G.BuffBarCooldownViewer
	if viewer then
		viewer:SetAlpha(0)
		if not viewer.nsaHooked then
			viewer.nsaHooked = true
			viewer:HookScript("OnShow", function(self) self:SetAlpha(0) end)
		end
	end
end

local function CanUseNative()
	return type(CreateFrame) == "function" and type(AuraContainerSortMethod) == "table" and type(AuraContainerSortDirection) == "table" and (not DoesTemplateExist or DoesTemplateExist("CustomAuraContainerTemplate"))
end

local function ClearNative()
	for _, container in pairs(nativeContainers) do
		pcall(container.SetUnit, container, "none")
		pcall(container.Hide, container)
	end
	wipe(nativeContainers)
	nativeMode = false
end

local function GetAuraConfig(index, aura)
	if previewing and index == previewKey and previewDraft then return previewDraft end
	return aura
end

local function BuildNative(index, aura)
	if aura.enabled == false or not tonumber(aura.spellID) or tonumber(aura.spellID) <= 0 then return false end
	local ok, container = pcall(CreateFrame, "AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
	if not ok or not container then return false end
	local config = CopyTable(aura)
	container:SetSize(config.size, config.size)
	container:SetPoint("CENTER", UIParent, "CENTER", config.x, config.y)
	container:SetFrameStrata("MEDIUM")
	local spellID = tonumber(config.spellID)
	local groupOptions = {
		maxFrameCount = 1,
		candidateFilters = { includeSpellIDs = { [spellID] = true } },
		initializeFrame = function(button)
			button:SetSize(config.size, config.size)
			button:SetMouseClickEnabled(false)
			button:SetMouseMotionEnabled(false)
			local nativeIcon = button:CreateTexture(nil, "ARTWORK")
			nativeIcon:SetAllPoints(button)
			button:SetIcon(nativeIcon)
			nativeIcon:SetAlpha(0)
			local icon = button:CreateTexture(nil, "OVERLAY")
			icon:SetAllPoints(button)
			icon:SetTexture(GetTexturePath(config.texture))
			icon:SetAlpha(config.opacity)
			local color = config.color or { 1, 1, 1, 1 }
			icon:SetVertexColor(color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1)
			icon:SetTexCoord(config.mirrorX and 1 or 0, config.mirrorX and 0 or 1, config.mirrorY and 1 or 0, config.mirrorY and 0 or 1)
			local cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
			cooldown:SetAllPoints(button)
			cooldown:SetDrawSwipe(false)
			cooldown:SetDrawBling(false)
			cooldown:SetDrawEdge(false)
			cooldown:SetHideCountdownNumbers(config.showTimer == false)
			if cooldown.SetUseAuraDisplayTime then cooldown:SetUseAuraDisplayTime(true) end
			if cooldown.SetCountdownMillisecondsThreshold then cooldown:SetCountdownMillisecondsThreshold(10) end
			local countdown = cooldown.GetCountdownFontString and cooldown:GetCountdownFontString()
			if countdown then
				countdown:ClearAllPoints()
				countdown:SetPoint("CENTER", button, "CENTER", config.timerX, config.timerY)
				countdown:SetFont(GetFontPath(config.timerFont), config.timerSize, "OUTLINE")
				local timerColor = config.timerColor or { 1, 1, 1, 1 }
				pcall(countdown.SetTextColor, countdown, timerColor[1] or 1, timerColor[2] or 1, timerColor[3] or 1, timerColor[4] or 1)
			end
			button:SetDurationCooldown(cooldown)
			if config.animation ~= "none" then
				local group = icon:CreateAnimationGroup()
				local duration = math.max(0.2, config.animationDuration or 2.4)
				if config.animation == "rotate" or config.animation == "spinFade" then local anim = group:CreateAnimation("Rotation"); anim:SetDegrees(360); anim:SetDuration(duration) end
				if config.animation == "fade" or config.animation == "spinFade" then local anim = group:CreateAnimation("Alpha"); anim:SetFromAlpha(0.2); anim:SetToAlpha(1); anim:SetDuration(duration / 2); local back = group:CreateAnimation("Alpha"); back:SetFromAlpha(1); back:SetToAlpha(0.2); back:SetDuration(duration / 2); back:SetOrder(2) end
				if config.animation == "wipeDown" or config.animation == "wipeUp" then local scale = group:CreateAnimation("Scale"); scale:SetScale(1, 0.01); scale:SetOrigin(config.animation == "wipeDown" and "TOP" or "BOTTOM", 0, 0); scale:SetDuration(duration); local alpha = group:CreateAnimation("Alpha"); alpha:SetFromAlpha(1); alpha:SetToAlpha(0); alpha:SetDuration(duration) end
				group:SetLooping("REPEAT")
				group:Play()
			end
		end,
	}
	local added = pcall(container.AddAuraGroup, container, "NSA" .. tostring(config.id or index), "HELPFUL|PLAYER", groupOptions)
	if not added then return false end
	local set = pcall(container.SetUnit, container, "player")
	if not set then return false end
	pcall(container.UpdateAllAuras, container)
	container:Show()
	nativeContainers[index] = container
	return true
end

local function GetRemaining(aura)
	if not aura then return nil end
	local ok, value = pcall(function() return aura.expirationTime - GetTime() end)
	if ok and type(value) == "number" then return math.max(0, value) end
end

local function CreateAuraFrame(aura)
	local frame = CreateFrame("Frame", nil, UIParent)
	frame:SetFrameStrata("MEDIUM")
	frame:Hide()
	frame.visualLayer = CreateFrame("Frame", nil, frame)
	frame.visualLayer:SetAllPoints(frame)
	frame.visualLayer:SetFrameLevel(frame:GetFrameLevel() + 1)
	frame.texture = frame.visualLayer:CreateTexture(nil, "ARTWORK")
	frame.texture:SetAllPoints(frame)
	frame.texture:SetVertexColor(1, 1, 1, 1)
	frame.cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
	frame.cooldown:SetAllPoints(frame)
	frame.cooldown:SetDrawSwipe(false)
	frame.cooldown:SetDrawEdge(false)
	frame.cooldown:SetDrawBling(false)
	if frame.cooldown.SetHideCountdownNumbers then frame.cooldown:SetHideCountdownNumbers(true) end
	frame.cooldownText = frame.cooldown.GetCountdownFontString and frame.cooldown:GetCountdownFontString()
	frame.timerLayer = CreateFrame("Frame", nil, frame)
	frame.timerLayer:SetAllPoints(frame)
	frame.timerLayer:SetFrameLevel(frame:GetFrameLevel() + 10)
	frame.timer = frame.timerLayer:CreateFontString(nil, "OVERLAY", "NumberFont_Outline_Huge")
	frame.timer:SetIgnoreParentAlpha(true)
	frame.animation = frame.visualLayer:CreateAnimationGroup()
	return frame
end

local function ConfigureAnimation(frame, aura)
	local signature = table.concat({ aura.animation, aura.animationDuration, aura.animationScale, aura.mirrorX and 1 or 0, aura.mirrorY and 1 or 0 }, ":")
	if frame.animationSignature == signature then return end
	frame.animationSignature = signature
	frame.animation:Stop()
	frame.animation:RemoveAnimations()
	local scaleX, scaleY = aura.mirrorX and -1 or 1, aura.mirrorY and -1 or 1
	frame.texture:SetTexCoord(scaleX > 0 and 0 or 1, scaleX > 0 and 1 or 0, scaleY > 0 and 0 or 1, scaleY > 0 and 1 or 0)
	local duration = math.max(0.2, aura.animationDuration or 2.4)
	if aura.animation == "rotate" or aura.animation == "spinFade" then local anim = frame.animation:CreateAnimation("Rotation"); anim:SetDegrees(360); anim:SetDuration(duration) end
	if aura.animation == "fade" or aura.animation == "spinFade" then local anim = frame.animation:CreateAnimation("Alpha"); anim:SetFromAlpha(0.2); anim:SetToAlpha(1); anim:SetDuration(duration / 2); local back = frame.animation:CreateAnimation("Alpha"); back:SetFromAlpha(1); back:SetToAlpha(0.2); back:SetDuration(duration / 2); back:SetOrder(2) end
	if aura.animation == "pulse" then local anim = frame.animation:CreateAnimation("Scale"); anim:SetScale(aura.animationScale, aura.animationScale); anim:SetDuration(duration / 2); local back = frame.animation:CreateAnimation("Scale"); back:SetScale(1 / aura.animationScale, 1 / aura.animationScale); back:SetDuration(duration / 2); back:SetOrder(2) end
	if aura.animation == "stretch" then local anim = frame.animation:CreateAnimation("Scale"); anim:SetScale(aura.animationScale, 1); anim:SetDuration(duration / 2); local back = frame.animation:CreateAnimation("Scale"); back:SetScale(1 / aura.animationScale, 1); back:SetDuration(duration / 2); back:SetOrder(2) end
	if aura.animation == "wipeDown" or aura.animation == "wipeUp" then local scale = frame.animation:CreateAnimation("Scale"); scale:SetScale(1, 0.01); scale:SetOrigin(aura.animation == "wipeDown" and "TOP" or "BOTTOM", 0, 0); scale:SetDuration(duration); local alpha = frame.animation:CreateAnimation("Alpha"); alpha:SetFromAlpha(1); alpha:SetToAlpha(0); alpha:SetDuration(duration) end
	if aura.animation == "fadeDown" or aura.animation == "fadeUp" then local alpha = frame.animation:CreateAnimation("Alpha"); alpha:SetFromAlpha(1); alpha:SetToAlpha(0); alpha:SetDuration(duration); alpha:SetOrder(1); local move = frame.animation:CreateAnimation("Translation"); move:SetOffset(0, aura.animation == "fadeDown" and -aura.size or aura.size); move:SetDuration(duration); move:SetOrder(1) end
	if aura.animation ~= "none" then frame.animation:SetLooping("REPEAT"); frame.animation:Play() end
end

local function UpdateOneAura(index, sourceAura)
	if previewing and index ~= previewKey then
		if auraFrames[index] then auraFrames[index]:Hide() end
		return
	end
	local aura = GetAuraConfig(index, sourceAura)
	local frame = auraFrames[index]
	if not frame then frame = CreateAuraFrame(aura); auraFrames[index] = frame end
	if aura.enabled == false then frame:Hide(); return end
	local spellID = tonumber(aura.spellID)
	if (not spellID or spellID <= 0) and not testMode then frame:Hide(); return end
	local cdm = not testMode and GetCDMTrackedAura(spellID)
	local active, remaining, durationObject = false, nil, nil
	if testMode then active, remaining = true, 8.8
	elseif cdm then active, durationObject = cdm.active, cdm.durationObject
		if cdm.startTime and cdm.duration then remaining = cdm.startTime + cdm.duration / (cdm.modRate or 1) - GetTime() end
	else local auraData = GetPlayerAura(spellID); active, remaining = auraData ~= nil, GetRemaining(auraData) end
	if remaining and remaining <= 0 then active = false end
	if not active then frame:Hide(); return end
	frame:SetSize(aura.size, aura.size)
	frame:ClearAllPoints(); frame:SetPoint("CENTER", UIParent, "CENTER", aura.x, aura.y)
	frame.texture:SetTexture(GetTexturePath(aura.texture)); local auraColor = aura.color or { 1, 1, 1, 1 }; frame.texture:SetVertexColor(auraColor[1], auraColor[2], auraColor[3], auraColor[4]); frame.texture:SetAlpha(aura.opacity)
	frame.visualLayer:ClearAllPoints(); frame.visualLayer:SetAllPoints(frame); frame.visualLayer:SetFrameLevel(frame:GetFrameLevel() + 1)
	frame.timerLayer:ClearAllPoints(); frame.timerLayer:SetAllPoints(frame); frame.timerLayer:SetFrameLevel(frame:GetFrameLevel() + 10)
	frame.timer:ClearAllPoints(); frame.timer:SetPoint("CENTER", frame, "CENTER", aura.timerX, aura.timerY)
	frame.timer:SetFont(GetFontPath(aura.timerFont), aura.timerSize, "OUTLINE")
	local timerColor = aura.timerColor or { 1, 1, 1, 1 }
	frame.timer:SetTextColor(timerColor[1], timerColor[2], timerColor[3], timerColor[4])
	if frame.cooldownText then frame.cooldownText:SetFont(GetFontPath(aura.timerFont), aura.timerSize, "OUTLINE"); frame.cooldownText:ClearAllPoints(); frame.cooldownText:SetPoint("CENTER", frame, "CENTER", aura.timerX, aura.timerY); pcall(frame.cooldownText.SetTextColor, frame.cooldownText, timerColor[1], timerColor[2], timerColor[3], timerColor[4]) end
	if durationObject and frame.cooldown.SetCooldownFromDurationObject then pcall(frame.cooldown.SetCooldownFromDurationObject, frame.cooldown, durationObject); frame.cooldown:Show() else frame.cooldown:Hide() end
	if aura.showTimer and remaining then frame.timer:SetText(string.format("%.1f", math.max(0, remaining))); frame.timer:Show() else frame.timer:Hide() end
	ConfigureAnimation(frame, aura)
	frame:Show()
end

local function GetNativeSignature()
	local parts = {}
	for index, aura in ipairs(db.auras) do parts[#parts + 1] = table.concat({ index, aura.id, aura.spellID, aura.texture, aura.size, aura.x, aura.y, aura.opacity, aura.timerSize, aura.timerX, aura.timerY, aura.timerFont, aura.enabled and 1 or 0, aura.animation, aura.animationDuration, aura.animationScale, table.concat(aura.color or {}, ","), table.concat(aura.timerColor or {}, ",") }, ":") end
	return table.concat(parts, "|")
end

local function RebuildNative()
	if not CanUseNative() then return false end
	if InCombatLockdown and InCombatLockdown() then rebuildPending = true; return false end
	ClearNative()
	local built = false
	for index, aura in ipairs(db.auras) do if BuildNative(index, GetAuraConfig(index, aura)) then built = true end end
	nativeMode, nativeSignature, rebuildPending = built, GetNativeSignature(), false
	return built
end

UpdateDisplay = function()
	if not db then return end
	HideBlizzardBars()
	if testMode or previewing then
		if nativeMode then ClearNative() end
		for index, aura in ipairs(db.auras) do UpdateOneAura(index, aura) end
		return
	end
	if CanUseNative() then
		local signature = GetNativeSignature()
		if not nativeMode or nativeSignature ~= signature then RebuildNative() end
		if nativeMode then for _, frame in pairs(auraFrames) do frame:Hide() end; return end
	end
	for index, aura in ipairs(db.auras) do UpdateOneAura(index, aura) end
end

local function AddBackdrop(frame)
	frame:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32, insets = { left = 8, right = 8, top = 8, bottom = 8 } })
	frame:SetBackdropColor(0.05, 0.05, 0.08, 1)
end

local function MakeButton(parent, text, width)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width or 90, 22); button:SetText(text); return button
end

local function StopPreview()
	previewing, previewKey, previewDraft = false, nil, nil
	UpdateDisplay()
end

local function ShowAuraContextMenu(button)
	if not MenuUtil or not MenuUtil.CreateContextMenu then return end
	local key, aura = button.auraKey, db.auras[button.auraKey]
	if not aura then return end
	MenuUtil.CreateContextMenu(button, function(_, menu)
		menu:CreateTitle(aura.name or ("Aura " .. key))
		menu:CreateButton("复制", function() auraClipboard = CopyTable(aura); auraClipboardSource = key end)
		menu:CreateButton("粘贴副本", function()
			if not auraClipboard then return end
			local copy = CopyTable(auraClipboard); copy.id = NextAuraID(); copy.name = MakeUniqueAuraName(copy.name); copy.selected = false
			table.insert(db.auras, key + 1, copy); selectedKey = key + 1; EnsureDatabase(); SaveCurrentDatabase(); RefreshGrid(); UpdateDisplay()
		end)
		menu:CreateButton("移动到此处", function()
			if not auraClipboardSource or auraClipboardSource == key then return end
			local moving = table.remove(db.auras, auraClipboardSource); local target = key
			if auraClipboardSource < key then target = target - 1 end
			table.insert(db.auras, target, moving); selectedKey = target; auraClipboardSource = nil; SaveCurrentDatabase(); RefreshGrid(); UpdateDisplay()
		end)
		menu:CreateButton(aura.enabled == false and "启用" or "隐藏", function() aura.enabled = aura.enabled == false; SaveCurrentDatabase(); RefreshGrid(); UpdateDisplay() end)
	end)
end

RefreshGrid = function()
	if not optionsFrame then return end
	optionsFrame.buttons = optionsFrame.buttons or {}
	for _, button in pairs(optionsFrame.buttons) do button:Hide() end
	local ordered = {}
	for index, aura in ipairs(db.auras) do if aura.enabled ~= false then ordered[#ordered + 1] = { index = index, aura = aura } end end
	local enabledCount = #ordered
	for index, aura in ipairs(db.auras) do if aura.enabled == false then ordered[#ordered + 1] = { index = index, aura = aura } end end
	if not optionsFrame.enabledLabel then optionsFrame.enabledLabel = optionsFrame.grid:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); optionsFrame.enabledLabel:SetPoint("TOPLEFT", 4, -2); optionsFrame.hiddenLabel = optionsFrame.grid:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); optionsFrame.hiddenLabel:SetPoint("TOPLEFT", 4, -150) end
	optionsFrame.enabledLabel:SetText("已启用"); optionsFrame.hiddenLabel:SetText("已隐藏")
	for position, entry in ipairs(ordered) do
		local key, aura = entry.index, entry.aura
		local button = optionsFrame.buttons[key]
		if not button then
			button = CreateFrame("Button", nil, optionsFrame.grid, "BackdropTemplate"); button:SetSize(72, 64)
			button:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
			button.texture = button:CreateTexture(nil, "ARTWORK"); button.texture:SetAllPoints(button); button.texture:SetTexCoord(0.05, 0.95, 0.05, 0.95)
			button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); button.label:SetPoint("BOTTOMLEFT", 2, 2); button.label:SetPoint("BOTTOMRIGHT", -2, 2); button.label:SetJustifyH("CENTER"); button.label:SetWordWrap(false)
			button.check = CreateFrame("CheckButton", nil, button, "UICheckButtonTemplate"); button.check:SetSize(20, 20); button.check:SetPoint("TOPLEFT", -4, 4)
			button.check:SetScript("OnClick", function(self) local item = db.auras[self:GetParent().auraKey]; if item then item.selected = self:GetChecked() and true or false end end)
			button:SetScript("OnClick", function(self, mouseButton) if mouseButton ~= "RightButton" then selectedKey = self.auraKey; RefreshGrid() end end)
			button:SetScript("OnDoubleClick", function(self) if optionsFrame.openEdit then optionsFrame.openEdit(self.auraKey) end end)
			button:RegisterForClicks("LeftButtonUp", "RightButtonUp"); button:SetScript("OnMouseUp", function(self, mouseButton) if mouseButton == "RightButton" then ShowAuraContextMenu(self) end end)
			optionsFrame.buttons[key] = button
		end
		button.auraKey = key; button.check:SetChecked(aura.selected == true); button.texture:SetTexture(GetTexturePath(aura.texture)); button.label:SetText(aura.name)
		local localPosition = position > enabledCount and position - enabledCount or position
		local row, column = math.floor((localPosition - 1) / 7), (localPosition - 1) % 7
		button:ClearAllPoints(); button:SetPoint("TOPLEFT", optionsFrame.grid, 4 + column * 80, (position > enabledCount and -170 or -22) - row * 72)
		button:SetAlpha(aura.enabled == false and 0.45 or 1); button:SetBackdropBorderColor(key == selectedKey and 1 or 0.3, key == selectedKey and 0.82 or 0.3, key == selectedKey and 0.15 or 0.3, 1); button:Show()
	end
end

local function RefreshPreview(frame)
	if not frame or not frame.draft then return end
	local draft = frame.draft
	frame.previewHost:SetSize(draft.size, draft.size); frame.previewHost:ClearAllPoints(); frame.previewHost:SetPoint("CENTER", frame.previewArea, "CENTER", draft.x, draft.y)
	frame.previewVisual:SetAllPoints(frame.previewHost); frame.previewVisual:SetAlpha(draft.opacity); frame.previewHost.texture:SetTexture(GetTexturePath(draft.texture)); frame.previewHost.texture:SetVertexColor(unpack(draft.color or { 1, 1, 1, 1 }))
	frame.previewTimer:SetPoint("CENTER", frame.previewHost, "CENTER", draft.timerX, draft.timerY); frame.previewTimer:SetFont(GetFontPath(draft.timerFont), draft.timerSize, "OUTLINE"); frame.previewTimer:SetText("8.8"); frame.previewTimer:SetTextColor(unpack(draft.timerColor or { 1, 1, 1, 1 })); frame.previewTimer:SetShown(draft.showTimer ~= false)
	local signature = table.concat({ draft.animation, draft.animationDuration, draft.animationScale, draft.mirrorX and 1 or 0, draft.mirrorY and 1 or 0 }, ":")
	if frame.previewAnimationSignature ~= signature then
		frame.previewAnimationSignature = signature; frame.previewAnimation:Stop(); frame.previewAnimation:RemoveAnimations(); local duration = math.max(0.2, draft.animationDuration or 2.4)
		if draft.animation == "rotate" or draft.animation == "spinFade" then local anim = frame.previewAnimation:CreateAnimation("Rotation"); anim:SetDegrees(360); anim:SetDuration(duration) end
		if draft.animation == "fade" or draft.animation == "spinFade" then local anim = frame.previewAnimation:CreateAnimation("Alpha"); anim:SetFromAlpha(0.2); anim:SetToAlpha(1); anim:SetDuration(duration / 2); local back = frame.previewAnimation:CreateAnimation("Alpha"); back:SetFromAlpha(1); back:SetToAlpha(0.2); back:SetDuration(duration / 2); back:SetOrder(2) end
		if draft.animation == "pulse" then local anim = frame.previewAnimation:CreateAnimation("Scale"); anim:SetScale(draft.animationScale, draft.animationScale); anim:SetDuration(duration / 2); local back = frame.previewAnimation:CreateAnimation("Scale"); back:SetScale(1 / draft.animationScale, 1 / draft.animationScale); back:SetDuration(duration / 2); back:SetOrder(2) end
		if draft.animation == "stretch" then local anim = frame.previewAnimation:CreateAnimation("Scale"); anim:SetScale(draft.animationScale, 1); anim:SetDuration(duration / 2); local back = frame.previewAnimation:CreateAnimation("Scale"); back:SetScale(1 / draft.animationScale, 1); back:SetDuration(duration / 2); back:SetOrder(2) end
		if draft.animation ~= "none" then frame.previewAnimation:SetLooping("REPEAT"); frame.previewAnimation:Play() end
	end
	if frame.livePreview then previewDraft = CopyTable(draft); UpdateDisplay() end
end

local function CreateTextureGallery()
	if not editFrame then return end
	if editFrame.gallery then editFrame.gallery:SetShown(not editFrame.gallery:IsShown()); return end
	local gallery = CreateFrame("Frame", "NSATextureGallery", UIParent, "BackdropTemplate"); gallery:SetSize(520, 430); gallery:SetPoint("CENTER"); gallery:SetFrameStrata("TOOLTIP"); gallery:SetMovable(true); gallery:EnableMouse(true); gallery:RegisterForDrag("LeftButton"); gallery:SetScript("OnDragStart", gallery.StartMoving); gallery:SetScript("OnDragStop", gallery.StopMovingOrSizing); AddBackdrop(gallery)
	local title = gallery:CreateFontString(nil, "OVERLAY", "GameFontNormal"); title:SetPoint("TOP", 0, -12); title:SetText("TGA 图库")
	local close = CreateFrame("Button", nil, gallery, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -4, -4); close:SetScript("OnClick", function() gallery:Hide() end)
	local scroll = CreateFrame("ScrollFrame", nil, gallery, "UIPanelScrollFrameTemplate"); scroll:SetPoint("TOPLEFT", 16, -38); scroll:SetPoint("BOTTOMRIGHT", -34, 16)
	local child = CreateFrame("Frame", nil, scroll); child:SetSize(450, 0); scroll:SetScrollChild(child)
	gallery.textureGroups = {}
	local function LayoutTextureGroups()
		local cursorY = 0
		for _, entry in ipairs(gallery.textureGroups) do
			entry.label:SetText((entry.expanded and "[-] " or "[+] ") .. entry.name .. " (" .. entry.count .. ")")
			entry.section:ClearAllPoints(); entry.section:SetPoint("TOPLEFT", child, 0, -cursorY)
			entry.body:ClearAllPoints(); entry.body:SetPoint("TOPLEFT", child, 0, -(cursorY + 26)); entry.body:SetShown(entry.expanded)
			local height = entry.expanded and entry.body:GetHeight() or 0
			cursorY = cursorY + 26 + height + 8
		end
		child:SetHeight(math.max(1, cursorY))
	end
	for groupIndex, group in ipairs(TEXTURE_GROUPS) do
		local files = group.files()
		local section = CreateFrame("Button", nil, child, "BackdropTemplate"); section:SetSize(450, 24); section:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" }); section:SetBackdropColor(0.12, 0.12, 0.16, 1)
		local sectionLabel = section:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); sectionLabel:SetPoint("LEFT", 8, 0); sectionLabel:SetJustifyH("LEFT")
		local groupBody = CreateFrame("Frame", nil, child); groupBody:SetSize(450, math.max(1, math.ceil(#files / 6) * 76))
		local entry = { section = section, body = groupBody, label = sectionLabel, expanded = true, name = group.name, count = #files }
		gallery.textureGroups[groupIndex] = entry
		section:SetScript("OnClick", function() entry.expanded = not entry.expanded; LayoutTextureGroups() end)
		for number, fileName in ipairs(files) do
			local button = CreateFrame("Button", nil, groupBody, "BackdropTemplate"); button:SetSize(68, 68); button:SetPoint("TOPLEFT", ((number - 1) % 6) * 75, -math.floor((number - 1) / 6) * 76); button:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 }); button:SetBackdropColor(0.03, 0.03, 0.04, 0.9)
			local texture = button:CreateTexture(nil, "ARTWORK"); texture:SetAllPoints(button); texture:SetTexture(GetTexturePath(group.folder .. fileName)); texture:SetTexCoord(0.05, 0.95, 0.05, 0.95)
			local label = button:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); label:SetPoint("BOTTOM", 0, 1); label:SetText(fileName:gsub("%.tga$", ""))
			button:SetScript("OnClick", function() editFrame.draft.texture = group.folder .. fileName; editFrame.texturePath:SetText(editFrame.draft.texture); editFrame.textureName:SetText(editFrame.draft.texture); RefreshPreview(editFrame); gallery:Hide() end)
		end
	end
	LayoutTextureGroups()
	editFrame.gallery = gallery; gallery:Show()
end

local function CloseEdit()
	if editFrame then if previewing and previewKey == editKey then testMode = false; editFrame.livePreview = false; editFrame.test:SetText("测试预览"); StopPreview() end; editFrame:Hide() end
end

local function OpenEdit(key)
	local aura = db.auras[key]; if not aura then return end
	editKey = key
	if not editFrame then
		local frame = CreateFrame("Frame", "NSAEditFrame", UIParent, "BackdropTemplate"); frame:SetSize(540, 640); frame:SetPoint("CENTER"); frame:SetFrameStrata("DIALOG"); frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton"); frame:SetScript("OnDragStart", frame.StartMoving); frame:SetScript("OnDragStop", frame.StopMovingOrSizing); AddBackdrop(frame); tinsert(UISpecialFrames, "NSAEditFrame"); editFrame = frame
		local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"); title:SetPoint("TOP", 0, -14); title:SetText("光环编辑器")
		local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -4, -4); close:SetScript("OnClick", CloseEdit)
		frame.previewArea = CreateFrame("Frame", nil, frame); frame.previewArea:SetSize(190, 190); frame.previewArea:SetPoint("TOPLEFT", 2, -42)
		frame.previewHost = CreateFrame("Frame", nil, frame); frame.previewHost:SetSize(150, 150); frame.previewHost:SetPoint("CENTER", frame.previewArea, "CENTER"); frame.previewVisual = CreateFrame("Frame", nil, frame.previewHost); frame.previewVisual:SetAllPoints(frame.previewHost); frame.previewHost.texture = frame.previewVisual:CreateTexture(nil, "ARTWORK"); frame.previewHost.texture:SetAllPoints(frame.previewVisual); frame.previewHost.texture:SetBlendMode("ADD"); frame.previewTimerLayer = CreateFrame("Frame", nil, frame.previewHost); frame.previewTimerLayer:SetAllPoints(frame.previewHost); frame.previewTimerLayer:SetFrameLevel(frame.previewHost:GetFrameLevel() + 10); frame.previewTimer = frame.previewTimerLayer:CreateFontString(nil, "OVERLAY", "NumberFont_Outline_Huge"); frame.previewTimer:SetPoint("CENTER", frame.previewHost, "CENTER"); frame.previewAnimation = frame.previewVisual:CreateAnimationGroup()
		frame.prevTexture = MakeButton(frame, "<", 30); frame.prevTexture:SetPoint("TOPLEFT", 22, -190); frame.nextTexture = MakeButton(frame, ">", 30); frame.nextTexture:SetPoint("LEFT", frame.prevTexture, "RIGHT", 4, 0); frame.galleryButton = MakeButton(frame, "图库", 62); frame.galleryButton:SetPoint("LEFT", frame.nextTexture, "RIGHT", 6, 0); frame.galleryButton:SetScript("OnClick", CreateTextureGallery); frame.textureName = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); frame.textureName:SetPoint("LEFT", frame.galleryButton, "RIGHT", 8, 0); frame.textureName:SetWidth(150); frame.textureName:SetJustifyH("LEFT")
		local function Label(y, text, x) local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); label:SetPoint("TOPLEFT", x or 190, y); label:SetText(text) end
		local function Edit(y, width, x) local input = CreateFrame("EditBox", nil, frame, "InputBoxTemplate"); input:SetSize(width or 70, 22); input:SetAutoFocus(false); input:SetPoint("TOPLEFT", x or 280, y); return input end
		Label(-26, "光环名称"); frame.name = Edit(-26, 190); Label(-56, "法术 ID"); frame.spellID = Edit(-56, 90); Label(-86, "X 轴位置"); frame.posX = Edit(-86, 60, 440); Label(-116, "Y 轴位置"); frame.posY = Edit(-116, 60, 440); Label(-146, "光环大小"); frame.size = Edit(-146, 60, 440); Label(-176, "不透明度"); frame.opacity = Edit(-176, 60, 440); Label(-206, "倒计时字号"); frame.timerSize = Edit(-206, 60, 440); Label(-236, "倒计时 X"); frame.timerX = Edit(-236, 60, 440); Label(-266, "倒计时 Y"); frame.timerY = Edit(-266, 60, 440); Label(-296, "纹理路径"); frame.texturePath = Edit(-296, 190)
		frame.timer = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate"); frame.timer:SetPoint("TOPLEFT", 190, -352); frame.timer:SetText(""); Label(-356, "勾选后显示倒计时数字", 220); Label(-326, "倒计时字体"); frame.timerFont = CreateFrame("Frame", nil, frame, "UIDropDownMenuTemplate"); frame.timerFont:SetPoint("TOPLEFT", 260, -320); UIDropDownMenu_SetWidth(frame.timerFont, 150); UIDropDownMenu_Initialize(frame.timerFont, function(self) for _, entry in ipairs(fontOptions) do local info = UIDropDownMenu_CreateInfo(); info.text = entry.name or entry.key; info.checked = editFrame.draft and editFrame.draft.timerFont == entry.key; info.func = function() if editFrame.draft then editFrame.draft.timerFont = entry.key; UIDropDownMenu_SetText(self, entry.name or entry.key); RefreshPreview(editFrame) end end; UIDropDownMenu_AddButton(info) end end); Label(-416, "动画形式"); frame.animation = CreateFrame("Frame", nil, frame, "UIDropDownMenuTemplate"); frame.animation:SetPoint("TOPLEFT", 260, -400); UIDropDownMenu_SetWidth(frame.animation, 150); UIDropDownMenu_Initialize(frame.animation, function(self) for _, value in ipairs(ANIMATION_ORDER) do local info = UIDropDownMenu_CreateInfo(); info.text = ANIMATION_NAMES[value]; info.checked = editFrame.draft and editFrame.draft.animation == value; info.func = function() if editFrame.draft then editFrame.draft.animation = value; UIDropDownMenu_SetText(self, ANIMATION_NAMES[value]); RefreshPreview(editFrame) end end; UIDropDownMenu_AddButton(info) end end); Label(-446, "动画时长"); frame.animationDuration = Edit(-446, 65, 280); Label(-446, "动画缩放", 360); frame.animationScale = Edit(-446, 65, 440); Label(-476, "光环颜色"); frame.colorButton = MakeButton(frame, "选择颜色", 80); frame.colorButton:SetPoint("TOPLEFT", 280, -470); frame.colorSwatch = frame:CreateTexture(nil, "ARTWORK"); frame.colorSwatch:SetSize(20, 20); frame.colorSwatch:SetPoint("LEFT", frame.colorButton, "RIGHT", 6, 0); Label(-504, "倒计时颜色"); frame.timerColorButton = MakeButton(frame, "选择颜色", 80); frame.timerColorButton:SetPoint("TOPLEFT", 280, -498); frame.timerColorSwatch = frame:CreateTexture(nil, "ARTWORK"); frame.timerColorSwatch:SetSize(20, 20); frame.timerColorSwatch:SetPoint("LEFT", frame.timerColorButton, "RIGHT", 6, 0)
		frame.test = MakeButton(frame, "测试预览", 100); frame.test:SetPoint("BOTTOMLEFT", 22, 18); frame.save = MakeButton(frame, "保存", 80); frame.save:SetPoint("LEFT", frame.test, "RIGHT", 6, 0); frame.cancel = MakeButton(frame, "关闭", 80); frame.cancel:SetPoint("LEFT", frame.save, "RIGHT", 6, 0)
		local function Slider(name, y, minValue, maxValue, step, key, input) local slider = CreateFrame("Slider", name, frame, "OptionsSliderTemplate"); slider:SetSize(140, 24); slider:SetPoint("TOPLEFT", 280, y); slider:SetMinMaxValues(minValue, maxValue); slider:SetValueStep(step); slider:SetObeyStepOnDrag(true); slider:SetScript("OnValueChanged", function(self, value) if editFrame.draft then editFrame.draft[key] = value; input:SetText(tostring(value)); RefreshPreview(editFrame) end end); return slider end
		frame.xSlider = Slider("NSAXSlider", -86, -1000, 1000, 1, "x", frame.posX); frame.ySlider = Slider("NSAYSlider", -116, -1000, 1000, 1, "y", frame.posY); frame.sizeSlider = Slider("NSASizeSlider", -146, 32, 512, 1, "size", frame.size); frame.opacitySlider = Slider("NSAOpacitySlider", -176, 0.05, 1, 0.05, "opacity", frame.opacity); frame.timerSizeSlider = Slider("NSATimerSizeSlider", -206, 10, 96, 1, "timerSize", frame.timerSize); frame.timerXSlider = Slider("NSATimerXSlider", -236, -300, 300, 1, "timerX", frame.timerX); frame.timerYSlider = Slider("NSATimerYSlider", -266, -300, 300, 1, "timerY", frame.timerY)
		local function Bind(input, key, fallback, slider) input:SetScript("OnTextChanged", function(self) if editFrame.draft and self:HasFocus() then local value = tonumber(self:GetText()) or fallback; editFrame.draft[key] = value; if slider then slider:SetValue(value) end; RefreshPreview(editFrame) end end) end
		Bind(frame.posX, "x", 0, frame.xSlider); Bind(frame.posY, "y", 0, frame.ySlider); Bind(frame.size, "size", 160, frame.sizeSlider); Bind(frame.opacity, "opacity", 1, frame.opacitySlider); Bind(frame.timerSize, "timerSize", 44, frame.timerSizeSlider); Bind(frame.timerX, "timerX", 0, frame.timerXSlider); Bind(frame.timerY, "timerY", 0, frame.timerYSlider)
		frame.name:SetScript("OnTextChanged", function(self) if editFrame.draft and self:HasFocus() then editFrame.draft.name = self:GetText(); RefreshPreview(editFrame) end end)
		frame.texturePath:SetScript("OnTextChanged", function(self) if editFrame.draft and self:HasFocus() then editFrame.draft.texture = NormalizeTexture(self:GetText()); frame.textureName:SetText(editFrame.draft.texture); RefreshPreview(editFrame) end end)
		frame.prevTexture:SetScript("OnClick", function() local n = tonumber((editFrame.draft.texture or "Aura1.tga"):match("(%d+)")) or 1; n = (n - 2 + MAX_TEXTURES) % MAX_TEXTURES + 1; editFrame.draft.texture = "Aura" .. n .. ".tga"; frame.texturePath:SetText(editFrame.draft.texture); RefreshPreview(frame) end)
		frame.nextTexture:SetScript("OnClick", function() local n = tonumber((editFrame.draft.texture or "Aura1.tga"):match("(%d+)")) or 1; n = n % MAX_TEXTURES + 1; editFrame.draft.texture = "Aura" .. n .. ".tga"; frame.texturePath:SetText(editFrame.draft.texture); RefreshPreview(frame) end)
		frame.animationDuration:SetScript("OnTextChanged", function(self) if editFrame.draft and self:HasFocus() then editFrame.draft.animationDuration = tonumber(self:GetText()) or 2.4; RefreshPreview(frame) end end); frame.animationScale:SetScript("OnTextChanged", function(self) if editFrame.draft and self:HasFocus() then editFrame.draft.animationScale = tonumber(self:GetText()) or 1.25; RefreshPreview(frame) end end)
		local function ColorPicker(button, swatch, key) button:SetScript("OnClick", function() local color = editFrame.draft[key] or { 1, 1, 1, 1 }; local info = { hasOpacity = true, r = color[1], g = color[2], b = color[3], opacity = color[4], swatchFunc = function() local r, g, b = ColorPickerFrame:GetColorRGB(); local a = ColorPickerFrame.GetColorAlpha and ColorPickerFrame:GetColorAlpha() or color[4]; editFrame.draft[key] = { r, g, b, a }; swatch:SetColorTexture(r, g, b, a); RefreshPreview(frame) end }; if ColorPickerFrame.SetupColorPickerAndShow then ColorPickerFrame:SetupColorPickerAndShow(info) end end) end
		ColorPicker(frame.colorButton, frame.colorSwatch, "color"); ColorPicker(frame.timerColorButton, frame.timerColorSwatch, "timerColor")
		frame.test:SetScript("OnClick", function() if testMode then testMode = false; frame.livePreview = false; frame.test:SetText("测试预览"); StopPreview(); return end; frame.livePreview = true; previewing, previewKey, previewDraft, testMode = true, editKey, CopyTable(frame.draft), true; frame.test:SetText("停止预览"); UpdateDisplay() end)
		frame.timer:SetScript("OnClick", function(self) if editFrame.draft then editFrame.draft.showTimer = self:GetChecked() and true or false; RefreshPreview(editFrame) end end)
		frame.cancel:SetScript("OnClick", CloseEdit)
		frame.save:SetScript("OnClick", function() local draft = CopyTable(frame.draft); draft.spellID = tonumber(frame.spellID:GetText()) or draft.spellID; draft.texture = NormalizeTexture(frame.texturePath:GetText()); draft.name = frame.name:GetText() or draft.name; draft.animationDuration = math.max(0.2, tonumber(frame.animationDuration:GetText()) or draft.animationDuration); draft.animationScale = math.max(1, math.min(3, tonumber(frame.animationScale:GetText()) or draft.animationScale)); db.auras[editKey] = draft; frame.draft = CopyTable(draft); if previewing and previewKey == editKey then previewDraft = CopyTable(draft) end; EnsureDatabase(); SaveCurrentDatabase(); RefreshGrid(); UpdateDisplay(); Print("已保存：" .. draft.name) end)
	end
	editFrame.draft = CopyTable(aura); editFrame.name:SetText(editFrame.draft.name); editFrame.spellID:SetText(tostring(editFrame.draft.spellID)); editFrame.posX:SetText(tostring(editFrame.draft.x)); editFrame.posY:SetText(tostring(editFrame.draft.y)); editFrame.size:SetText(tostring(editFrame.draft.size)); editFrame.opacity:SetText(tostring(editFrame.draft.opacity)); editFrame.timerSize:SetText(tostring(editFrame.draft.timerSize)); editFrame.timerX:SetText(tostring(editFrame.draft.timerX)); editFrame.timerY:SetText(tostring(editFrame.draft.timerY)); editFrame.texturePath:SetText(editFrame.draft.texture); editFrame.textureName:SetText(editFrame.draft.texture); UIDropDownMenu_SetText(editFrame.timerFont, GetFontName(editFrame.draft.timerFont)); UIDropDownMenu_SetText(editFrame.animation, ANIMATION_NAMES[editFrame.draft.animation] or ANIMATION_NAMES.none); editFrame.animationDuration:SetText(tostring(editFrame.draft.animationDuration)); editFrame.animationScale:SetText(tostring(editFrame.draft.animationScale)); editFrame.colorSwatch:SetColorTexture(unpack(editFrame.draft.color)); editFrame.timerColorSwatch:SetColorTexture(unpack(editFrame.draft.timerColor)); editFrame.timer:SetChecked(editFrame.draft.showTimer ~= false); editFrame.xSlider:SetValue(editFrame.draft.x); editFrame.ySlider:SetValue(editFrame.draft.y); editFrame.sizeSlider:SetValue(editFrame.draft.size); editFrame.opacitySlider:SetValue(editFrame.draft.opacity); editFrame.timerSizeSlider:SetValue(editFrame.draft.timerSize); editFrame.timerXSlider:SetValue(editFrame.draft.timerX); editFrame.timerYSlider:SetValue(editFrame.draft.timerY); editFrame.test:SetText(testMode and "停止预览" or "测试预览"); RefreshPreview(editFrame); editFrame:Show()
end

local function CreateTextEdit(parent, x, y, width, value)
	local input = CreateFrame("EditBox", nil, parent, "InputBoxTemplate"); input:SetSize(width, 22); input:SetPoint("TOPLEFT", x, y); input:SetAutoFocus(false); input:SetMaxLetters(32); input:SetText(tostring(value or "")); return input
end

local function CreateExportDialog(selectedOnly)
	local dialog = CreateFrame("Frame", "NSAExportDialog", UIParent, "BackdropTemplate"); dialog:SetSize(560, 330); dialog:SetPoint("CENTER"); dialog:SetFrameStrata("DIALOG"); AddBackdrop(dialog); tinsert(UISpecialFrames, "NSAExportDialog")
	local edit = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate"); edit:SetMultiLine(true); edit:SetSize(520, 250); edit:SetPoint("TOP", 0, -30); edit:SetFont(STANDARD_TEXT_FONT, 11, ""); edit:SetText(ExportString(selectedOnly)); edit:HighlightText()
	local close = CreateFrame("Button", nil, dialog, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -4, -4); close:SetScript("OnClick", function() dialog:Hide() end)
end

local function CreateImportDialog()
	local dialog = CreateFrame("Frame", "NSAImportDialog", UIParent, "BackdropTemplate"); dialog:SetSize(560, 330); dialog:SetPoint("CENTER"); dialog:SetFrameStrata("DIALOG"); AddBackdrop(dialog); tinsert(UISpecialFrames, "NSAImportDialog")
	local edit = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate"); edit:SetMultiLine(true); edit:SetSize(520, 235); edit:SetPoint("TOP", 0, -30); edit:SetFont(STANDARD_TEXT_FONT, 11, "")
	local button = MakeButton(dialog, "导入", 80); button:SetPoint("BOTTOM", 0, 12); button:SetScript("OnClick", function() local ok, message = ImportString(edit:GetText()); Print(message); if ok then SaveCurrentDatabase(); RefreshGrid(); UpdateDisplay(); dialog:Hide() end end)
	local close = CreateFrame("Button", nil, dialog, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -4, -4); close:SetScript("OnClick", function() dialog:Hide() end)
end

local function AddSpell(spellID)
	spellID = tonumber(spellID); if not spellID or spellID <= 0 then Print("用法：/nsa add 法术ID"); return end
	for _, aura in ipairs(db.auras) do if tonumber(aura.spellID) == spellID then Print("这个法术已经在列表中。"); return end end
	table.insert(db.auras, CreateDefaultAura(spellID)); SaveCurrentDatabase(); RefreshGrid(); UpdateDisplay()
end

local function OpenCooldownManager()
	if not CooldownViewerSettings and UIParentLoadAddOn then UIParentLoadAddOn("Blizzard_CooldownViewer") end
	if CooldownViewerSettings and CooldownViewerSettings.TogglePanel then CooldownViewerSettings:TogglePanel(); return end
	Print("冷却管理器尚未加载。")
end

local function ImportFromCooldownViewer()
	if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCategorySet then Print("冷却管理器接口不可用。"); return end
	local categories = Enum and Enum.CooldownViewerCategory and { Enum.CooldownViewerCategory.TrackedBar, Enum.CooldownViewerCategory.TrackedBuff } or { 3, 4 }
	local existing, count = {}, 0
	for _, aura in ipairs(db.auras) do existing[tonumber(aura.spellID)] = true end
	for _, category in ipairs(categories) do local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, category, true); if ok and ids then for _, id in ipairs(ids) do local good, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, id); if good and info then local spellID = info.overrideTooltipSpellID or info.overrideSpellID or info.spellID or info.spellId or info.overrideSpellId; if spellID and not existing[spellID] then existing[spellID] = true; table.insert(db.auras, CreateDefaultAura(spellID)); count = count + 1 end end end end end
	SaveCurrentDatabase(); RefreshGrid(); UpdateDisplay(); Print("已从冷却管理器导入 " .. count .. " 个法术。")
end

local function InstallCDMContextMenus()
	for _, viewerName in ipairs({ "BuffBarCooldownViewer", "BuffIconCooldownViewer" }) do
		local viewer = _G[viewerName]
		if viewer and viewer.itemFramePool and viewer.itemFramePool.EnumerateActive then
			for frame in viewer.itemFramePool:EnumerateActive() do
				if not frame.nsaHooked then
					frame.nsaHooked = true
					local cooldown = frame.Cooldown or frame.cooldown
					if cooldown and cooldown.SetCooldownFromDurationObject then hooksecurefunc(cooldown, "SetCooldownFromDurationObject", function(_, object) frame.nsaDurationObject = object end) end
				end
			end
		end
	end
end

local function CreateProfileFrame()
	local frame = CreateFrame("Frame", "NSAProfileFrame", UIParent, "BackdropTemplate"); frame:SetSize(560, 300); frame:SetPoint("CENTER"); frame:SetFrameStrata("DIALOG"); frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton"); frame:SetScript("OnDragStart", frame.StartMoving); frame:SetScript("OnDragStop", frame.StopMovingOrSizing); AddBackdrop(frame); tinsert(UISpecialFrames, "NSAProfileFrame")
	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"); title:SetPoint("TOP", 0, -16); title:SetText("角色 / 职业配置")
	local dropdown = CreateFrame("Frame", "NSAProfileDropdown", frame, "UIDropDownMenuTemplate"); dropdown:SetPoint("TOPLEFT", 20, -60); UIDropDownMenu_SetWidth(dropdown, 190)
	local name = CreateTextEdit(frame, 24, -120, 180, "")
	local function Refresh() local profileName = db.class or select(2, UnitClass("player")) or "DEFAULT"; UIDropDownMenu_Initialize(dropdown, function() local info = UIDropDownMenu_CreateInfo(); info.text = profileName .. "（当前职业）"; info.checked = true; info.func = function() UIDropDownMenu_SetText(dropdown, profileName .. "（当前职业）") end; UIDropDownMenu_AddButton(info) end); UIDropDownMenu_SetText(dropdown, profileName .. "（当前职业）") end
	Refresh()
	local create = MakeButton(frame, "新建配置", 120); create:SetPoint("LEFT", name, "RIGHT", 8, 0); create:SetScript("OnClick", function() SaveCurrentDatabase(); Refresh(); RefreshGrid(); UpdateDisplay() end); name:Hide(); create:Hide()
	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -4, -4); close:SetScript("OnClick", function() frame:Hide() end)
	frame:Show()
end

local function CreateOptionsFrame()
	if optionsFrame then optionsFrame:Show(); RefreshGrid(); return end
	local frame = CreateFrame("Frame", "NSAOptionsFrame", UIParent, "BackdropTemplate"); frame:SetSize(620, 535); frame:SetPoint("CENTER"); frame:SetFrameStrata("DIALOG"); frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton"); frame:SetScript("OnDragStart", frame.StartMoving); frame:SetScript("OnDragStop", frame.StopMovingOrSizing); AddBackdrop(frame); tinsert(UISpecialFrames, "NSAOptionsFrame"); optionsFrame = frame
	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"); title:SetPoint("TOP", 0, -14); title:SetText("新状态光环")
	local info = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); info:SetPoint("TOP", title, "BOTTOM", 0, -4); info:SetText("版本 " .. ADDON_VERSION .. " | 魔兽世界 12.1 | 作者：梅超風-白银之手")
	local grid = CreateFrame("Frame", nil, frame); grid:SetPoint("TOPLEFT", 20, -62); grid:SetSize(570, 300); frame.grid = grid
	local newButton = MakeButton(frame, "新建", 70); newButton:SetPoint("TOPLEFT", 20, -365); newButton:SetScript("OnClick", function() local aura = CreateDefaultAura(); aura.name = MakeUniqueAuraName("光环"); table.insert(db.auras, aura); selectedKey = #db.auras; SaveCurrentDatabase(); RefreshGrid(); OpenEdit(selectedKey) end)
	local deleteButton = MakeButton(frame, "删除", 70); deleteButton:SetPoint("LEFT", newButton, "RIGHT", 6, 0); deleteButton:SetScript("OnClick", function() for index = #db.auras, 1, -1 do if db.auras[index].selected or index == selectedKey then table.remove(db.auras, index) end end; selectedKey = nil; SaveCurrentDatabase(); RefreshGrid(); UpdateDisplay() end)
	local editButton = MakeButton(frame, "编辑", 70); editButton:SetPoint("LEFT", deleteButton, "RIGHT", 6, 0); editButton:SetScript("OnClick", function() if selectedKey then OpenEdit(selectedKey) end end); frame.openEdit = OpenEdit
	local cdmButton = MakeButton(frame, "打开冷却管理", 150); cdmButton:SetPoint("LEFT", editButton, "RIGHT", 6, 0); cdmButton:SetScript("OnClick", OpenCooldownManager)
	local allButton = MakeButton(frame, "全选", 75); allButton:SetPoint("TOPLEFT", 20, -397); allButton:SetScript("OnClick", function() for _, aura in ipairs(db.auras) do aura.selected = true end; RefreshGrid() end)
	local clearButton = MakeButton(frame, "清除选择", 60); clearButton:SetPoint("LEFT", allButton, "RIGHT", 6, 0); clearButton:SetScript("OnClick", function() for _, aura in ipairs(db.auras) do aura.selected = false end; RefreshGrid() end)
	local exportButton = MakeButton(frame, "导出全部", 82); exportButton:SetPoint("LEFT", clearButton, "RIGHT", 6, 0); exportButton:SetScript("OnClick", function() CreateExportDialog(false) end)
	local importButton = MakeButton(frame, "导入", 70); importButton:SetPoint("LEFT", exportButton, "RIGHT", 6, 0); importButton:SetScript("OnClick", CreateImportDialog)
	local profileButton = MakeButton(frame, "配置", 80); profileButton:SetPoint("LEFT", importButton, "RIGHT", 6, 0); profileButton:SetScript("OnClick", CreateProfileFrame)
	local testButton = MakeButton(frame, "测试", 60); testButton:SetPoint("LEFT", profileButton, "RIGHT", 6, 0); testButton:SetScript("OnClick", function() testMode = true; previewing = false; UpdateDisplay(); C_Timer.After(3, function() testMode = false; UpdateDisplay() end) end)
	frame:Show(); RefreshGrid()
end

local function RegisterSettings()
	if NewStatusAurasSettingsCategory then return end
	local panel = CreateFrame("Frame", "NewStatusAurasSettingsPanel"); panel.name = "新状态光环"; panel:HookScript("OnShow", function(self) if self.built then return end; self.built = true; local title = self:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge"); title:SetPoint("TOPLEFT", 24, -24); title:SetText("新状态光环"); local meta = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight"); meta:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12); meta:SetText("版本 " .. ADDON_VERSION .. " | 游戏版本 12.1\n作者：梅超風-白银之手"); local open = CreateFrame("Button", nil, self, "UIPanelButtonTemplate"); open:SetSize(160, 24); open:SetPoint("TOPLEFT", meta, "BOTTOMLEFT", 0, -20); open:SetText("打开设置"); open:SetScript("OnClick", function() CreateOptionsFrame() end); local profiles = CreateFrame("Button", nil, self, "UIPanelButtonTemplate"); profiles:SetSize(160, 24); profiles:SetPoint("LEFT", open, "RIGHT", 8, 0); profiles:SetText("职业配置"); profiles:SetScript("OnClick", CreateProfileFrame) end)
	if Settings and Settings.RegisterCanvasLayoutCategory then local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name); Settings.RegisterAddOnCategory(category); NewStatusAurasSettingsCategory = category elseif InterfaceOptions_AddCategory then InterfaceOptions_AddCategory(panel); NewStatusAurasSettingsCategory = panel end
end

local events = CreateFrame("Frame")
	events:RegisterEvent("PLAYER_LOGIN"); events:RegisterEvent("PLAYER_LOGOUT"); events:RegisterEvent("PLAYER_ENTERING_WORLD"); events:RegisterEvent("PLAYER_REGEN_ENABLED"); events:RegisterUnitEvent("UNIT_AURA", "player"); events:RegisterEvent("ADDON_LOADED"); events:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED"); events:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
	events:SetScript("OnEvent", function(_, event, addonName)
		if event == "ADDON_LOADED" then
			if addonName == "NewStatusAuras" then
				rootDB = NewStatusAurasDB or {}
				rootDB.profiles = rootDB.profiles or {}
				rootDB.profileKeys = rootDB.profileKeys or {}
				LOAD_INJECT_PROFILES, LOAD_INJECT_AURAS, LOAD_INJECT_GLOBAL_AURAS = 0, 0, 0
				for _, p in pairs(rootDB.profiles) do
					if type(p) == "table" and type(p.auras) == "table" then
						LOAD_INJECT_PROFILES = LOAD_INJECT_PROFILES + 1
						for _ in pairs(p.auras) do LOAD_INJECT_AURAS = LOAD_INJECT_AURAS + 1 end
					end
				end
				LOAD_INJECT_GLOBAL_AURAS = type(rootDB.auras) == "table" and #rootDB.auras or 0
			elseif addonName == "Blizzard_CooldownViewer" then ResetCDMCache(); InstallCDMContextMenus() end
		end
		if event == "PLAYER_LOGIN" then
			-- 关键：始终在注入完成后重新连接 SavedVariables，防止文件顶部捕获到空表
			rootDB = NewStatusAurasDB or rootDB or {}
			rootDB.profiles = rootDB.profiles or {}
			rootDB.profileKeys = rootDB.profileKeys or {}
			SelectProfileDatabase(); EnsureDatabase(); RecoverNonEmptyProfile(); EnsureDatabase(); RegisterSettings(); InstallCDMContextMenus()
			C_Timer.After(0.5, ReportLoadedProfile)
		elseif event == "PLAYER_ENTERING_WORLD" then
			C_Timer.After(0, RefreshLoadedProfile)
			C_Timer.After(1, ReportLoadedProfile)
		elseif event == "PLAYER_LOGOUT" then SaveCurrentDatabase() end
		if event == "PLAYER_REGEN_ENABLED" and rebuildPending then RebuildNative() end
		if event == "COOLDOWN_VIEWER_DATA_LOADED" or event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then ResetCDMCache(); InstallCDMContextMenus() end
		UpdateDisplay()
	end)
events:SetScript("OnUpdate", function(_, elapsed) events.elapsed = (events.elapsed or 0) + elapsed; if events.elapsed >= 0.08 then events.elapsed = 0; UpdateDisplay() end end)

SLASH_NEWSTATUSAURAS1 = "/nsa"; SLASH_NEWSTATUSAURAS2 = "/newstatusauras"
SlashCmdList.NEWSTATUSAURAS = function(message)
	local command = strlower(strtrim(message or ""))
	if command == "import" then ImportFromCooldownViewer() elseif command == "cdm" then OpenCooldownManager() elseif command == "profiles" then CreateProfileFrame() elseif command == "save" then SaveCurrentDatabase(); Print("已保存职业配置：" .. tostring(db and db.profileName or "默认") .. "，光环数量：" .. tostring(CountAuras(db))) elseif command:match("^add%s+") then AddSpell(command:match("^add%s+(.+)$")) elseif command == "test" then testMode = true; UpdateDisplay(); C_Timer.After(3, function() testMode = false; UpdateDisplay() end) elseif command == "debug" then
		local charKey = (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?")
		local classKey = select(2, UnitClass("player")) or "?"
		Print("=== NSA 诊断 ===")
		Print("加载注入: profiles="..LOAD_INJECT_PROFILES.." 光环="..LOAD_INJECT_AURAS.." 旧全局auras="..LOAD_INJECT_GLOBAL_AURAS)
		Print("角色="..charKey.." 职业="..classKey)
		Print("db 引用正确="..tostring(db == (rootDB.profiles and rootDB.profiles[classKey])).." db.profileName="..tostring(db and db.profileName))
		Print("当前职业光环数="..tostring(db and CountAuras(db)))
		local profileCount, auraTotal = 0, 0
		for name, p in pairs(rootDB.profiles or {}) do
			local n = type(p) == "table" and CountAuras(p) or 0
			auraTotal = auraTotal + n; profileCount = profileCount + 1
			Print("  profile["..tostring(name).."] 光环="..tostring(n))
		end
		Print("profiles 数量="..tostring(profileCount).." 光环合计="..tostring(auraTotal))
		Print("profileKeys["..tostring(charKey).."]="..tostring(rootDB.profileKeys and rootDB.profileKeys[charKey] or "无"))
		Print("legacyMigrated="..tostring(rootDB.legacyMigrated and true or false).." 旧全局auras数="..tostring(type(rootDB.auras) == "table" and #rootDB.auras or 0))
	else CreateOptionsFrame() end
end
