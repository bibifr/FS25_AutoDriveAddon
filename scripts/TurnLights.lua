-- Clignotant avant les virages et les croisements
-- AutoDrive allume le clignotant seulement quand l'angle du trajet juste devant dépasse son réglage
-- « Clignotant automatique » : la distance regardée dépend de la vitesse, donc il clignote trop tard.
-- Ici le trajet est regardé sur une distance fixe (réglage « Distance clignotant », 50 m par défaut),
-- le clignotant s'allume du côté du virage et s'éteint une fois le virage passé.
-- Le réglage est ajouté à ceux d'AutoDrive (sauvegarde et multijoueur par AutoDrive) et affiché
-- dans sa page de réglages, juste sous « Clignotant automatique ».

ADAddonTurnLights = {}

ADAddonTurnLights.DISTANCES = { 20, 30, 40, 50, 60, 70, 80, 100 }
ADAddonTurnLights.DEFAULT_INDEX = 4     -- 50 m
ADAddonTurnLights.KEEP_ANGLE = 15       -- degrés de virage encore devant qui gardent le clignotant
ADAddonTurnLights.OFF_DELAY = 1000      -- ms sans virage devant avant d'éteindre (comme AutoDrive)

local isFrench = g_languageShortName == "fr"
local function T(fr, en)
    if isFrench then return fr end
    return en
end

-- Le réglage doit exister avant qu'AutoDrive lise sa configuration (son loadMap)
function ADAddonTurnLights.addSetting(autoDrive)
    if autoDrive == nil or autoDrive.settings == nil or autoDrive.settings.blinkDistance ~= nil then
        return
    end
    local texts = {}
    for i, v in ipairs(ADAddonTurnLights.DISTANCES) do
        texts[i] = v .. " m"
    end
    autoDrive.settings.blinkDistance = {
        values = ADAddonTurnLights.DISTANCES,
        texts = texts,
        default = ADAddonTurnLights.DEFAULT_INDEX,
        current = ADAddonTurnLights.DEFAULT_INDEX,
        text = "gui_ad_blinkDistance",
        tooltip = "gui_ad_blinkDistance_tooltip",
        translate = false,
        isVehicleSpecific = false
    }
end

ADAddonTurnLights.addSetting(ADAddon.getAutoDriveGlobal("AutoDrive"))

-- Renvoie 1 (gauche), -1 (droite) ou 0 si le trajet tourne d'au moins minAngle dans les maxDistance m devant.
-- Un clignotant déjà allumé reste allumé tant qu'il reste au moins KEEP_ANGLE de ce virage devant.
function ADAddonTurnLights.getUpcomingTurnDirection(module, maxDistance, minAngle)
    local autoDrive = ADAddonTurnLights.autoDrive
    local index = module:getCurrentWayPointIndex()
    local wayPoints = module.wayPoints
    if wayPoints == nil or index == nil or wayPoints[index] == nil then
        return 0
    end
    local x, _, z = getWorldTranslation(module.vehicle.components[1].node)
    local prev = wayPoints[index - 1] or { x = x, z = z }
    local current = module.adAddonBlinkDir or 0
    local keepAngle = math.min(ADAddonTurnLights.KEEP_ANGLE, minAngle)
    local distance = MathUtil.vector2Length(wayPoints[index].x - x, wayPoints[index].z - z)
    local cumulated = 0
    local keep = false
    local i = index
    while distance <= maxDistance and wayPoints[i + 1] ~= nil do
        local wpCurrent = wayPoints[i]
        local wpAhead = wayPoints[i + 1]
        local wpRef = (i == index) and prev or wayPoints[i - 1]
        local angle = autoDrive.angleBetween({ x = wpAhead.x - wpCurrent.x, z = wpAhead.z - wpCurrent.z }, { x = wpCurrent.x - wpRef.x, z = wpCurrent.z - wpRef.z })
        cumulated = cumulated + math.max(-90, math.min(90, angle))
        if cumulated >= minAngle then
            return 1
        elseif cumulated <= -minAngle then
            return -1
        end
        if current ~= 0 and cumulated * current >= keepAngle then
            keep = true
        end
        distance = distance + MathUtil.vector2Length(wpAhead.x - wpCurrent.x, wpAhead.z - wpCurrent.z)
        i = i + 1
    end
    if keep then
        return current
    end
    return 0
end

function ADAddonTurnLights.update(module, minAngle, dt)
    local vehicle = module.vehicle
    local maxDistance = ADAddonTurnLights.autoDrive.getSetting("blinkDistance") or 50
    local direction = 0
    if module:isOnRoadNetwork() then
        direction = ADAddonTurnLights.getUpcomingTurnDirection(module, maxDistance, minAngle)
    end
    if direction ~= 0 then
        module.adAddonBlinkClear = 0
        module.adAddonBlinkDir = direction
        if direction > 0 then
            vehicle:setTurnLightState(Lights.TURNLIGHT_LEFT)
        else
            vehicle:setTurnLightState(Lights.TURNLIGHT_RIGHT)
        end
    elseif (module.adAddonBlinkDir or 0) ~= 0 then
        module.adAddonBlinkClear = (module.adAddonBlinkClear or 0) + dt
        if module.adAddonBlinkClear >= ADAddonTurnLights.OFF_DELAY then
            module.adAddonBlinkDir = 0
            vehicle:setTurnLightState(Lights.TURNLIGHT_OFF)
        end
    end
end

-- Ligne « Distance clignotant » ajoutée sous « Clignotant automatique » dans la page de réglages d'AutoDrive
local function findFirst(el, pred)
    if el == nil or el.elements == nil then return nil end
    for _, c in ipairs(el.elements) do
        if pred(c) then return c end
        local r = findFirst(c, pred)
        if r ~= nil then return r end
    end
    return nil
end

local function profileContains(c, word)
    return c.profile ~= nil and string.find(string.lower(tostring(c.profile)), word, 1, true) ~= nil
end

local function isTextElement(c)
    return c.isa ~= nil and c:isa(TextElement)
end

function ADAddonTurnLights.addSettingRow(page)
    local source = page.settingElements.blinkValue
    local autoDrive = ADAddonTurnLights.autoDrive
    local setting = autoDrive.settings.blinkDistance
    if source == nil or setting == nil then
        return
    end
    local row = source.parent
    local layout = row.parent
    -- suppressOnCreate : sinon la copie s'enregistrerait à la place de « Clignotant automatique »
    local newRow = row:clone(layout, false, true)
    local option = findFirst(newRow, function(c) return c.isa ~= nil and c:isa(MultiTextOptionElement) end)
    if option == nil then
        newRow:delete()
        print("AutoDriveAddon : option clignotant introuvable dans la ligne copiée")
        return
    end

    -- la copie est ajoutée en fin de page : on la remonte juste sous la ligne d'origine
    for i, c in ipairs(layout.elements) do
        if c == newRow then
            table.remove(layout.elements, i)
            break
        end
    end
    for i, c in ipairs(layout.elements) do
        if c == row then
            table.insert(layout.elements, i + 1, newRow)
            break
        end
    end

    option.name = "blinkDistance"
    option.id = "blinkDistance"
    option:setTexts(setting.texts)
    local tip = findFirst(newRow, function(c) return isTextElement(c) and profileContains(c, "tooltip") end)
    if tip ~= nil then
        tip:setText(T("Distance avant un virage ou un croisement à laquelle le clignotant s'allume.",
                      "Distance before a turn or crossing at which the turn light is switched on."))
    end
    for _, c in ipairs(newRow.elements) do
        if c ~= option and isTextElement(c) and not profileContains(c, "tooltip") then
            c:setText(T("Distance clignotant", "Turnlight Distance"))
            break
        end
    end
    page.settingElements.blinkDistance = option

    -- couleurs alternées des lignes après l'ajout
    local even = false
    for _, c in ipairs(layout.elements) do
        if c.setImageColor ~= nil and c.profile == row.profile then
            c:setImageColor(nil, table.unpack(InGameMenuSettingsFrame.COLOR_ALTERNATING[even]))
            even = not even
        end
    end
    if layout.invalidateLayout ~= nil then layout:invalidateLayout() end
end

function ADAddonTurnLights.install(autoDrive)
    ADAddonTurnLights.autoDrive = autoDrive
    ADAddonTurnLights.addSetting(autoDrive)

    local pathModule = ADAddon.getAutoDriveGlobal("ADDrivePathModule")
    if pathModule == nil or pathModule.checkActiveAttributesSet == nil or pathModule.reset == nil then
        print("AutoDriveAddon : ADDrivePathModule introuvable, clignotant avant virage inactif")
        return
    end

    local originalReset = pathModule.reset
    pathModule.reset = function(self, ...)
        self.adAddonBlinkDir = 0
        self.adAddonBlinkClear = 0
        return originalReset(self, ...)
    end

    -- Le clignotant d'AutoDrive est coupé pendant son appel, puis remplacé par celui-ci
    local originalCheck = pathModule.checkActiveAttributesSet
    pathModule.checkActiveAttributesSet = function(self, dt)
        local vehicle = self.vehicle
        local minAngle = autoDrive.getSetting("blinkValue") or 0
        if not vehicle.isServer or minAngle <= 0 or vehicle.setTurnLightState == nil then
            return originalCheck(self, dt)
        end
        local own = rawget(vehicle, "setTurnLightState")
        vehicle.setTurnLightState = function() end
        local ok, err = pcall(originalCheck, self, dt)
        rawset(vehicle, "setTurnLightState", own)
        if not ok then
            error(err, 0)
        end
        if ((g_updateLoopIndex + vehicle.id) % autoDrive.PERF_FRAMES == 0) then
            ADAddonTurnLights.update(self, minAngle, dt * autoDrive.PERF_FRAMES)
        end
    end

    local settingsPage = ADAddon.getAutoDriveGlobal("ADSettingsPage")
    if settingsPage ~= nil and settingsPage.onFrameOpen ~= nil then
        local originalOpen = settingsPage.onFrameOpen
        settingsPage.onFrameOpen = function(page, ...)
            if page.settingElements ~= nil and page.settingElements.blinkValue ~= nil and not page.adAddonBlinkRowAdded then
                page.adAddonBlinkRowAdded = true
                local okRow, errRow = pcall(ADAddonTurnLights.addSettingRow, page)
                if not okRow then
                    print("AutoDriveAddon : erreur ligne Distance clignotant : " .. tostring(errRow))
                end
            end
            return originalOpen(page, ...)
        end
    end

    print("AutoDriveAddon : clignotant avant virage branché")
end

ADAddon.addModule(ADAddonTurnLights)
