-- Réglages de l'addon dans Paramètres (section « AutoDrive Addon »)
-- Sauvegardés dans modSettings/FS25_AutoDriveAddon/settings.xml

ADAddonSettings = {}

-- Délai de coupure moteur, en secondes (0 = jamais)
ADAddonSettings.ENGINE_DELAYS = { 0, 10, 30, 60, 120, 300 }
ADAddonSettings.engineDelay = 10
ADAddonSettings.active = false
ADAddonSettings.built = false

local isFrench = g_languageShortName == "fr"
local function T(fr, en)
    if isFrench then return fr end
    return en
end

local function getSettingsFile()
    return getUserProfileAppPath() .. "modSettings/FS25_AutoDriveAddon/settings.xml"
end

function ADAddonSettings:apply()
    ADAddonEngineStop.delayMs = self.engineDelay * 1000
end

function ADAddonSettings:load()
    local file = getSettingsFile()
    if fileExists(file) then
        local xml = loadXMLFile("adAddonSettings", file)
        if xml ~= nil and xml ~= 0 then
            local d = getXMLInt(xml, "adAddon.engineStop#delaySeconds")
            if d ~= nil then self.engineDelay = math.max(0, d) end
            delete(xml)
        end
    end
end

function ADAddonSettings:save()
    local ok, err = pcall(function()
        createFolder(getUserProfileAppPath() .. "modSettings/")
        createFolder(getUserProfileAppPath() .. "modSettings/FS25_AutoDriveAddon/")
        local xml = createXMLFile("adAddonSettings", getSettingsFile(), "adAddon")
        if xml ~= nil and xml ~= 0 then
            setXMLInt(xml, "adAddon.engineStop#delaySeconds", self.engineDelay)
            saveXMLFile(xml)
            delete(xml)
        end
    end)
    if not ok then print("AutoDriveAddon : échec de la sauvegarde des réglages : " .. tostring(err)) end
end

local function delayText(s)
    if s <= 0 then return T("Jamais", "Never") end
    if s < 60 then return s .. " s" end
    return (s / 60) .. " min"
end

local function getIndex(list, v)
    local best, bestDiff = 1, math.huge
    for i, val in ipairs(list) do
        local d = math.abs(val - v)
        if d < bestDiff then best, bestDiff = i, d end
    end
    return best
end

function ADAddonSettings:onEngineDelayChanged(state, element)
    local v = self.ENGINE_DELAYS[state]
    if v ~= nil then
        self.engineDelay = v
        self:apply()
        self:save()
        print("AutoDriveAddon : coupure moteur AutoDrive " .. ADAddonEngineStop.describe())
    end
end

-- Construction du menu (même méthode qu'AutoSwitch : clone d'une ligne existante)
local function findFirst(el, pred)
    if el == nil or el.elements == nil then return nil end
    for _, c in ipairs(el.elements) do
        if pred(c) then return c end
        local r = findFirst(c, pred)
        if r ~= nil then return r end
    end
    return nil
end

local function isMultiText(c)
    return c.isa ~= nil and c:isa(MultiTextOptionElement)
end

local function profileContains(c, word)
    return c.profile ~= nil and string.find(string.lower(tostring(c.profile)), word, 1, true) ~= nil
end

local function isRealMultiText(c)
    if not isMultiText(c) then return false end
    if BinaryOptionElement ~= nil and c:isa(BinaryOptionElement) then return false end
    if profileContains(c, "binary") then return false end
    return true
end

function ADAddonSettings:buildUI(frame)
    local layout = frame.generalSettingsLayout or frame.gameSettingsLayout
    if layout == nil or layout.elements == nil then
        print("AutoDriveAddon : mise en page des paramètres introuvable")
        return
    end

    local template
    for _, row in ipairs(layout.elements) do
        if not isMultiText(row) and findFirst(row, isRealMultiText) ~= nil then
            template = row
            break
        end
    end
    if template == nil then
        print("AutoDriveAddon : aucun modèle d'option trouvé dans les paramètres")
        return
    end

    for _, row in ipairs(layout.elements) do
        if row.isa ~= nil and row:isa(TextElement) and profileContains(row, "header") then
            local header = row:clone(layout)
            header:setText("AutoDrive Addon")
            break
        end
    end

    local row = template:clone(layout)
    local option = findFirst(row, isRealMultiText)
    if option == nil then
        print("AutoDriveAddon : option introuvable dans la ligne clonée")
        return
    end
    for _, c in ipairs(row.elements) do
        if c.isa ~= nil and c:isa(TextElement) then
            c:setText(T("Coupure moteur AutoDrive", "AutoDrive engine stop"))
            break
        end
    end
    local tip = findFirst(row, function(c)
        return c.isa ~= nil and c:isa(TextElement) and profileContains(c, "tooltip")
    end)
    if tip ~= nil then
        tip:setText(T("Temps à l'arrêt avant qu'AutoDrive coupe le moteur. 10 s = AutoDrive de base. Jamais = le moteur reste allumé.",
                      "Time stopped before AutoDrive turns the engine off. 10 s = AutoDrive default. Never = the engine keeps running."))
    end

    local texts = {}
    for i, v in ipairs(self.ENGINE_DELAYS) do
        texts[i] = delayText(v)
    end
    option:setTexts(texts)
    option:setState(getIndex(self.ENGINE_DELAYS, self.engineDelay))
    option.target = self
    option.onClickCallback = ADAddonSettings.onEngineDelayChanged
    self.engineOption = option

    if layout.invalidateLayout ~= nil then layout:invalidateLayout() end
    self.built = true
end

function ADAddonSettings:onSettingsFrameOpen(frame)
    if not self.active then return end
    if not self.built then
        local ok, err = pcall(self.buildUI, self, frame)
        if not ok then print("AutoDriveAddon : erreur menu : " .. tostring(err)) end
    elseif self.engineOption ~= nil then
        self.engineOption:setState(getIndex(self.ENGINE_DELAYS, self.engineDelay))
    end
end

-- Appelé par ADAddon au chargement de la carte (seulement si l'addon est actif)
function ADAddonSettings.install(autoDrive)
    ADAddonSettings.active = true
    ADAddonSettings:load()
    ADAddonSettings:apply()
end

if InGameMenuSettingsFrame ~= nil and InGameMenuSettingsFrame.onFrameOpen ~= nil then
    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, function(frame)
        ADAddonSettings:onSettingsFrameOpen(frame)
    end)
end

-- Les réglages sont chargés avant les modules qui les utilisent
table.insert(ADAddon.modules, 1, ADAddonSettings)
