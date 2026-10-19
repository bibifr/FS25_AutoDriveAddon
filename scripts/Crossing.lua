-- Regarder avant de traverser : quand le trajet AutoDrive coupe ou rejoint une route,
-- AutoDrive regarde la route des deux côtés (voitures du jeu, tracteurs, joueur).
-- Si quelque chose arrive, il s'arrête avant le bord, attend que ce soit libre, puis traverse.
-- Les routes sont les lignes du trafic / de l'IA du jeu (splines). Les chemins sans ligne
-- ne sont pas surveillés. Arrêt tenu comme la pesée : la tâche AutoDrive attend et le
-- module de conduite spéciale garde le véhicule à l'arrêt.

ADAddonCrossing = {}

ADAddonCrossing.enabled = true
ADAddonCrossing.watchDist = 80            -- m de route regardés de chaque côté
ADAddonCrossing.WATCH_DISTS = { 40, 60, 80, 100, 120, 150 }

ADAddonCrossing.LOOK_AHEAD = 60           -- m de trajet examinés devant le tracteur
ADAddonCrossing.SAMPLE_STEP = 4           -- m entre deux points d'une ligne de route
ADAddonCrossing.CELL = 32                 -- m, grille de recherche des points
ADAddonCrossing.HIT_DIST = 3              -- m : point de route à moins de 3 m du trajet
ADAddonCrossing.MIN_SIN = 0.42            -- angle mini trajet / route (25°) : on coupe ou on rejoint
ADAddonCrossing.END_IGNORE = 8            -- m : bouts de lignes ignorés quand on roule déjà sur une route
ADAddonCrossing.ZONE_LENGTH = 15          -- m : points de croisement regroupés (route à deux voies)
ADAddonCrossing.ROAD_HALF = 3             -- m : demi-largeur de route
ADAddonCrossing.STOP_MARGIN = 4           -- m : arrêt à 4 m du bord
ADAddonCrossing.APPROACH_DIST = 25        -- m avant l'arrêt : vitesse limitée pour bien regarder
ADAddonCrossing.APPROACH_KMH = 20
ADAddonCrossing.BRAKE_DECEL = 1.5         -- m/s² pour s'arrêter avant le bord
ADAddonCrossing.COMMIT_DIST = 2           -- m avant l'arrêt : si libre, il s'engage
ADAddonCrossing.CLEAR_MS = 2000           -- libre depuis 2 s après une attente
ADAddonCrossing.CHECK_MS = 250
ADAddonCrossing.CLOSE_DIST = 8            -- m : véhicule sur le croisement, même arrêté
ADAddonCrossing.ARRIVAL_S = 8             -- s : véhicule qui arrive dans moins de 8 s
ADAddonCrossing.MOVING_MS = 0.5           -- m/s : en dessous, véhicule arrêté
ADAddonCrossing.STOPPED_KMH = 0.5
ADAddonCrossing.BOX_HALF_WIDTH = 2.2
ADAddonCrossing.BOX_HALF_HEIGHT = 1.5

ADAddonCrossing.splines = nil             -- { {samples = {...}, length = m}, ... }
ADAddonCrossing.grid = {}
ADAddonCrossing.tracks = {}               -- noeud touché -> {d, time}

local frenchCache = nil
local function isFrench()
    if frenchCache ~= nil then return frenchCache end
    local french, known = false, false
    if getLanguage ~= nil and getLanguageCode ~= nil then
        local ok, code = pcall(function() return getLanguageCode(getLanguage()) end)
        if ok and type(code) == "string" then
            known = true
            french = code:lower():sub(1, 2) == "fr"
        end
    end
    if not french and g_languageShortName ~= nil then
        known = true
        french = g_languageShortName == "fr"
    end
    if not french and g_i18n ~= nil and g_i18n.getText ~= nil then
        local ok, t = pcall(g_i18n.getText, g_i18n, "ui_yes")
        if ok and type(t) == "string" and not t:find("Missing") then
            known = true
            french = t == "Oui"
        end
    end
    if known and g_currentMission ~= nil then frenchCache = french end
    return french
end
local function T(fr, en)
    if isFrench() then return fr end
    return en
end

local function log(text, ...)
    print("AutoDriveAddon : [croisement] " .. string.format(text, ...))
end

-------------------------------------------------------------------------------
-- Lignes de route du jeu
-------------------------------------------------------------------------------

local function isSpline(node)
    if node == nil or node == 0 then return false end
    if getHasClassId ~= nil and ClassIds ~= nil and ClassIds.SPLINE ~= nil then
        return getHasClassId(node, ClassIds.SPLINE)
    end
    local ok, length = pcall(getSplineLength, node)
    return ok and type(length) == "number" and length > 0
end

local function collectSplines(node, out, seen, depth)
    if node == nil or node == 0 or depth > 8 then return end
    if isSpline(node) then
        if not seen[node] then
            seen[node] = true
            table.insert(out, node)
        end
        return
    end
    for i = 0, getNumOfChildren(node) - 1 do
        collectSplines(getChildAt(node, i), out, seen, depth + 1)
    end
end

local function gridKey(x, z)
    local c = ADAddonCrossing.CELL
    return math.floor(x / c) * 100000 + math.floor(z / c)
end

local function sampleSpline(spline)
    local length = getSplineLength(spline)
    if length == nil or length < 1 then return nil end
    local step = ADAddonCrossing.SAMPLE_STEP
    local count = math.max(2, math.ceil(length / step) + 1)
    local samples = {}
    for i = 0, count - 1 do
        local t = math.min(1, i / (count - 1))
        local x, y, z = getSplinePosition(spline, t)
        if x ~= nil then
            table.insert(samples, { x = x, y = y, z = z, dist = t * length })
        end
    end
    if #samples < 2 then return nil end
    for i, s in ipairs(samples) do
        local a = samples[math.max(1, i - 1)]
        local b = samples[math.min(#samples, i + 1)]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l < 0.01 then dx, dz, l = 0, 1, 1 end
        s.dx, s.dz = dx / l, dz / l
    end
    return { samples = samples, length = length }
end

function ADAddonCrossing.loadSplines()
    local nodes, seen = {}, {}
    local mission = g_currentMission
    local ai = mission ~= nil and mission.aiSystem or nil
    if ai ~= nil and type(ai.roadSplines) == "table" then
        for _, s in pairs(ai.roadSplines) do
            if type(s) == "number" and not seen[s] and isSpline(s) then
                seen[s] = true
                table.insert(nodes, s)
            end
        end
    end
    -- lignes du trafic des voitures (sous le noeud du système de trafic)
    local traffic = mission ~= nil and mission.trafficSystem or nil
    if traffic ~= nil then
        for _, key in ipairs({ "rootNodeId", "rootNode", "splinesRootNode", "trafficSystemId" }) do
            local root = traffic[key]
            if type(root) == "number" and root ~= 0 and entityExists ~= nil and entityExists(root) then
                pcall(collectSplines, root, nodes, seen, 0)
            end
        end
    end

    ADAddonCrossing.splines = {}
    ADAddonCrossing.grid = {}
    local total = 0
    for _, node in ipairs(nodes) do
        local ok, sp = pcall(sampleSpline, node)
        if ok and sp ~= nil then
            table.insert(ADAddonCrossing.splines, sp)
            local index = #ADAddonCrossing.splines
            for i, s in ipairs(sp.samples) do
                s.spline, s.index = index, i
                local key = gridKey(s.x, s.z)
                local cell = ADAddonCrossing.grid[key]
                if cell == nil then
                    cell = {}
                    ADAddonCrossing.grid[key] = cell
                end
                table.insert(cell, s)
            end
            total = total + sp.length
        end
    end
    log("%d lignes de route trouvées (%.1f km)", #ADAddonCrossing.splines, total / 1000)
end

-- Points de route proches d'un segment (grille)
local function samplesNear(ax, az, bx, bz, margin)
    local c = ADAddonCrossing.CELL
    local out = {}
    local x0, x1 = math.floor((math.min(ax, bx) - margin) / c), math.floor((math.max(ax, bx) + margin) / c)
    local z0, z1 = math.floor((math.min(az, bz) - margin) / c), math.floor((math.max(az, bz) + margin) / c)
    for cx = x0, x1 do
        for cz = z0, z1 do
            local cell = ADAddonCrossing.grid[cx * 100000 + cz]
            if cell ~= nil then
                for _, s in ipairs(cell) do
                    table.insert(out, s)
                end
            end
        end
    end
    return out
end

local function isNearSplineEnd(s)
    local sp = ADAddonCrossing.splines[s.spline]
    return s.dist < ADAddonCrossing.END_IGNORE or sp.length - s.dist < ADAddonCrossing.END_IGNORE
end

-------------------------------------------------------------------------------
-- Croisement devant le tracteur
-------------------------------------------------------------------------------

local function getFrontOffset(vehicle)
    local length = vehicle.size ~= nil and vehicle.size.length or 6
    local offset = vehicle.size ~= nil and vehicle.size.lengthOffset or 0
    return length * 0.5 + offset
end

local function getTrainLength(vehicle)
    local total = 0
    local list = vehicle.rootVehicle ~= nil and vehicle.rootVehicle.childVehicles or nil
    if list ~= nil then
        for _, v in pairs(list) do
            if v.size ~= nil then total = total + v.size.length end
        end
    end
    if total <= 0 then total = vehicle.size ~= nil and vehicle.size.length or 6 end
    return total
end

-- Le tracteur roule déjà sur une route (ligne proche et dans le même sens)
local function isOnRoad(x, z, dx, dz)
    for _, s in ipairs(samplesNear(x, z, x, z, 4)) do
        local ox, oz = x - s.x, z - s.z
        if ox * ox + oz * oz < 16 and math.abs(dx * s.dz - dz * s.dx) < 0.5 then
            return true
        end
    end
    return false
end

-- Premier croisement sur le trajet devant : renvoie {dist = m depuis l'avant du tracteur, points = {...}} ou nil
local function findCrossing(vehicle)
    local ad = vehicle.ad
    local dpm = ad.drivePathModule
    if dpm == nil or dpm.getWayPoints == nil then return nil end
    local wayPoints, index = dpm:getWayPoints()
    if wayPoints == nil or index == nil or wayPoints[index] == nil then return nil end

    local root = vehicle.components ~= nil and vehicle.components[1].node or vehicle.rootNode
    local x, _, z = getWorldTranslation(root)
    local hdx, _, hdz = localDirectionToWorld(root, 0, 0, 1)
    local front = getFrontOffset(vehicle)
    local onRoad = isOnRoad(x, z, hdx, hdz)

    local hits = {}
    local cum = -front
    local px, pz = x, z
    local i = index
    local first = nil
    while wayPoints[i] ~= nil and cum < ADAddonCrossing.LOOK_AHEAD do
        local wp = wayPoints[i]
        local sx, sz = wp.x - px, wp.z - pz
        local segLen = math.sqrt(sx * sx + sz * sz)
        if segLen > 0.05 then
            local ux, uz = sx / segLen, sz / segLen
            for _, s in ipairs(samplesNear(px, pz, wp.x, wp.z, ADAddonCrossing.HIT_DIST + 1)) do
                local ox, oz = s.x - px, s.z - pz
                local along = ox * ux + oz * uz
                if along >= 0 and along <= segLen then
                    local side = math.abs(ox * uz - oz * ux)
                    local sin = math.abs(ux * s.dz - uz * s.dx)
                    if side <= ADAddonCrossing.HIT_DIST and sin >= ADAddonCrossing.MIN_SIN
                        and not (onRoad and isNearSplineEnd(s)) then
                        local d = cum + along
                        if d > -front then
                            if first == nil then first = d end
                            if d <= first + ADAddonCrossing.ZONE_LENGTH then
                                table.insert(hits, { s = s, dist = d })
                            end
                        end
                    end
                end
            end
            cum = cum + segLen
        end
        if first ~= nil and cum > first + ADAddonCrossing.ZONE_LENGTH then break end
        px, pz = wp.x, wp.z
        i = i + 1
    end
    if first == nil then return nil end

    -- un seul point par ligne : le plus proche du trajet suffit
    local bySpline, points = {}, {}
    local last = first
    for _, h in ipairs(hits) do
        if bySpline[h.s.spline] == nil then
            bySpline[h.s.spline] = true
            table.insert(points, h.s)
        end
        if h.dist > last then last = h.dist end
    end
    return { dist = first, last = last, points = points, x = points[1].x, z = points[1].z }
end

-------------------------------------------------------------------------------
-- Trafic sur la route
-------------------------------------------------------------------------------

local function getMask()
    local m = 0
    for _, name in ipairs({ "VEHICLE", "TRAFFIC_VEHICLE", "TRAFFIC_VEHICLE_BLOCKING" }) do
        if CollisionFlag ~= nil and CollisionFlag[name] ~= nil then m = m + CollisionFlag[name] end
    end
    return m
end

function ADAddonCrossing:overlapCallback(node)
    if node == nil or node == 0 or node == g_currentMission.terrainRootNode then
        return true
    end
    local object = g_currentMission:getNodeObject(node)
    if object == nil then
        local parent = getParent(node)
        if parent ~= nil and parent ~= 0 then
            object = g_currentMission:getNodeObject(parent)
        end
    end
    local me = self.scanVehicle
    if object ~= nil and me ~= nil then
        local autoDrive = ADAddon.getAutoDriveGlobal("AutoDrive")
        if object == me or object == me:getRootVehicle()
            or (autoDrive ~= nil and autoDrive.checkIsConnected ~= nil and autoDrive:checkIsConnected(me:getRootVehicle(), object)) then
            return true
        end
    end
    local key = object ~= nil and object or node
    if not self.scanSeen[key] then
        self.scanSeen[key] = true
        table.insert(self.scanHits, { key = key, node = node, object = object })
    end
    return true
end

-- Boîtes posées le long d'une ligne, des deux côtés du point de croisement
local function scanSpline(point, dist)
    local sp = ADAddonCrossing.splines[point.spline]
    local samples = sp.samples
    local mask = getMask()
    local step = 2
    for dir = -1, 1, 2 do
        local i = point.index
        while true do
            local j = i + dir * step
            if j < 1 or j > #samples then break end
            local a, b = samples[i], samples[j]
            if math.abs(a.dist - point.dist) > dist then break end
            local cx, cy, cz = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5
            local dx, dz = b.x - a.x, b.z - a.z
            local half = math.sqrt(dx * dx + dz * dz) * 0.5 + 0.5
            local ry = math.atan2(dx, dz)
            overlapBox(cx, cy + ADAddonCrossing.BOX_HALF_HEIGHT + 0.2, cz, 0, ry, 0,
                ADAddonCrossing.BOX_HALF_WIDTH, ADAddonCrossing.BOX_HALF_HEIGHT, half,
                "overlapCallback", ADAddonCrossing, mask, true, true, true, true)
            i = j
        end
    end
    -- le point lui-même
    overlapBox(point.x, point.y + ADAddonCrossing.BOX_HALF_HEIGHT + 0.2, point.z, 0, math.atan2(point.dx, point.dz), 0,
        ADAddonCrossing.BOX_HALF_WIDTH, ADAddonCrossing.BOX_HALF_HEIGHT, ADAddonCrossing.SAMPLE_STEP,
        "overlapCallback", ADAddonCrossing, mask, true, true, true, true)
end

-- Quelque chose arrive ? renvoie true + texte pour le log
local function isTrafficComing(vehicle, crossing)
    ADAddonCrossing.scanVehicle = vehicle
    ADAddonCrossing.scanHits = {}
    ADAddonCrossing.scanSeen = {}
    for _, p in ipairs(crossing.points) do
        scanSpline(p, ADAddonCrossing.watchDist)
    end
    ADAddonCrossing.scanVehicle = nil

    local now = g_time
    local tracks = ADAddonCrossing.tracks
    local danger, reason = false, nil
    for _, h in ipairs(ADAddonCrossing.scanHits) do
        local hx, _hy, hz
        if h.object ~= nil and h.object.rootNode ~= nil then
            hx, _hy, hz = getWorldTranslation(h.object.rootNode)
        else
            hx, _hy, hz = getWorldTranslation(h.node)
        end
        -- distance au point de croisement le plus proche
        local d = math.huge
        for _, p in ipairs(crossing.points) do
            local ox, oz = hx - p.x, hz - p.z
            d = math.min(d, math.sqrt(ox * ox + oz * oz))
        end
        local speed
        if h.object ~= nil and h.object.lastSpeedReal ~= nil then
            speed = h.object.lastSpeedReal * 1000 -- m/s
        end
        local t = tracks[h.key]
        local closing = nil
        if t ~= nil and now - t.time > 100 and now - t.time < 2000 then
            closing = (t.d - d) / ((now - t.time) / 1000) -- m/s, > 0 = s'approche
        end
        if t == nil or now - t.time >= 100 then
            tracks[h.key] = { d = d, time = now }
        end
        if speed == nil and closing ~= nil then speed = math.abs(closing) end

        local name = h.object ~= nil and h.object.getFullName ~= nil and h.object:getFullName() or "voiture"
        if d <= ADAddonCrossing.CLOSE_DIST then
            danger, reason = true, string.format("%s sur le croisement (%.0f m)", name, d)
        elseif closing == nil then
            -- vu pour la première fois : prudence s'il est assez près et roule (sens connu au prochain regard)
            if d < 40 and (speed == nil or speed > ADAddonCrossing.MOVING_MS) then
                danger, reason = true, string.format("%s à %.0f m", name, d)
            end
        elseif closing > ADAddonCrossing.MOVING_MS and d / closing < ADAddonCrossing.ARRIVAL_S then
            danger, reason = true, string.format("%s arrive (%.0f m, %.0f km/h)", name, d, closing * 3.6)
        elseif closing > ADAddonCrossing.MOVING_MS and d < 40 then
            danger, reason = true, string.format("%s arrive (%.0f m)", name, d)
        end
        if danger then break end
    end

    -- ménage des suivis anciens
    for k, t in pairs(tracks) do
        if now - t.time > 5000 then tracks[k] = nil end
    end
    return danger, reason
end

-------------------------------------------------------------------------------
-- Conduite
-------------------------------------------------------------------------------

local function release(vehicle, c)
    if c ~= nil and c.holding then
        local sdm = vehicle.ad.specialDrivingModule
        if sdm ~= nil then sdm:releaseVehicle() end
    end
end

local function clear(vehicle)
    local c = vehicle.adAddonCross
    release(vehicle, c)
    vehicle.adAddonCross = nil
    vehicle.adAddonCrossSpeed = nil
end

local function isSameCrossing(a, x, z)
    local dx, dz = a.x - x, a.z - z
    return dx * dx + dz * dz < 400
end

-- Une image d'AutoDrive : renvoie true si la tâche doit attendre (arrêt avant la route)
local function crossStep(self, dt)
    local vehicle = self.vehicle
    if vehicle == nil or vehicle.ad == nil or not vehicle.isServer then
        return false
    end
    if not ADAddonCrossing.enabled or self.activeTask == nil then
        if vehicle.adAddonCross ~= nil then clear(vehicle) end
        return false
    end
    if ADAddonCrossing.splines == nil then
        ADAddonCrossing.loadSplines()
    end
    if #ADAddonCrossing.splines == 0 then
        return false
    end
    local dpm = vehicle.ad.drivePathModule
    if dpm == nil or (dpm.getIsReversing ~= nil and dpm:getIsReversing()) then
        if vehicle.adAddonCross ~= nil and not vehicle.adAddonCross.committed then clear(vehicle) end
        return false
    end

    local c = vehicle.adAddonCross
    if c == nil then
        c = { nextCheck = 0, clearTime = 0 }
        vehicle.adAddonCross = c
    end

    -- engagé : on traverse sans regarder, jusqu'à ce que tout l'attelage soit passé
    if c.committed then
        local root = vehicle.components[1].node
        local x, _, z = getWorldTranslation(root)
        local ox, oz = x - c.committed.x, z - c.committed.z
        c.travel = (c.travel or 0) + (vehicle.lastMovedDistance or 0)
        if c.travel > c.committed.span or ox * ox + oz * oz > (c.committed.span + 30) ^ 2 then
            c.done = { x = c.committed.x, z = c.committed.z, time = g_time }
            c.committed, c.travel = nil, nil
        end
        vehicle.adAddonCrossSpeed = nil
        return false
    end

    if g_time < c.nextCheck then
        if c.holding then
            local sdm = vehicle.ad.specialDrivingModule
            sdm.motorShouldNotBeStopped = true
            sdm:stopVehicle()
            sdm:update(dt)
            sdm.motorShouldNotBeStopped = false
            return true
        end
        return false
    end
    c.nextCheck = g_time + ADAddonCrossing.CHECK_MS

    local crossing = findCrossing(vehicle)
    if c.done ~= nil and g_time - c.done.time > 60000 then c.done = nil end
    if crossing ~= nil and c.done ~= nil and isSameCrossing(c.done, crossing.x, crossing.z) then
        crossing = nil -- déjà traversé
    end
    if crossing == nil then
        if c.holding then release(vehicle, c) end
        c.holding, c.waited, c.clearTime = false, false, 0
        vehicle.adAddonCrossSpeed = nil
        return false
    end

    local toStop = crossing.dist - ADAddonCrossing.ROAD_HALF - ADAddonCrossing.STOP_MARGIN
    local danger, reason = isTrafficComing(vehicle, crossing)
    local kmh = (vehicle.lastSpeedReal or 0) * 3600

    if danger then
        c.clearTime = 0
        if not c.waited then
            c.waited = true
            log("%s attend : %s", tostring(vehicle:getFullName()), tostring(reason))
        end
        if toStop <= 1 then
            -- trop tard pour s'arrêter avant le bord (déjà engagé) : on passe
            if toStop < -1 and not c.holding then
                log("%s déjà sur la route, il passe", tostring(vehicle:getFullName()))
                c.committed = { x = crossing.x, z = crossing.z, span = crossing.last + getTrainLength(vehicle) + ADAddonCrossing.ROAD_HALF * 2 }
                c.holding, c.waited, c.travel = false, false, 0
                return false
            end
            c.holding = true
        end
        local v = math.sqrt(2 * ADAddonCrossing.BRAKE_DECEL * math.max(0, toStop)) * 3.6
        vehicle.adAddonCrossSpeed = math.max(3, math.min(ADAddonCrossing.APPROACH_KMH, v))
    else
        if c.waited then
            if c.clearTime == 0 then c.clearTime = g_time end
        end
        local clearLongEnough = not c.waited or g_time - c.clearTime >= ADAddonCrossing.CLEAR_MS
        if toStop <= ADAddonCrossing.COMMIT_DIST and clearLongEnough then
            if c.waited then
                log("%s libre, il traverse", tostring(vehicle:getFullName()))
            end
            release(vehicle, c)
            c.committed = { x = crossing.x, z = crossing.z, span = crossing.last + getTrainLength(vehicle) + ADAddonCrossing.ROAD_HALF * 2 }
            c.holding, c.waited, c.clearTime, c.travel = false, false, 0, 0
            vehicle.adAddonCrossSpeed = nil
            return false
        end
        if c.waited and toStop <= 1 then
            c.holding = true -- encore à l'arrêt pendant les 2 s de libre
        end
        if toStop < ADAddonCrossing.APPROACH_DIST then
            vehicle.adAddonCrossSpeed = ADAddonCrossing.APPROACH_KMH
        else
            vehicle.adAddonCrossSpeed = nil
        end
    end

    if c.holding then
        local sdm = vehicle.ad.specialDrivingModule
        if sdm == nil then
            c.holding = false
            return false
        end
        sdm.motorShouldNotBeStopped = true
        sdm:stopVehicle()
        sdm:update(dt)
        sdm.motorShouldNotBeStopped = false
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- Réglages (Paramètres > AutoDrive Addon), fichier modSettings/FS25_AutoDriveAddon/crossing.xml
-------------------------------------------------------------------------------

local function getSettingsFile()
    return getUserProfileAppPath() .. "modSettings/FS25_AutoDriveAddon/crossing.xml"
end

function ADAddonCrossing.loadSettings()
    local file = getSettingsFile()
    if fileExists(file) then
        local xml = loadXMLFile("adAddonCrossing", file)
        if xml ~= nil and xml ~= 0 then
            local e = getXMLBool(xml, "crossing#enabled")
            if e ~= nil then ADAddonCrossing.enabled = e end
            local d = getXMLInt(xml, "crossing#watchDistance")
            if d ~= nil then ADAddonCrossing.watchDist = math.max(20, d) end
            delete(xml)
        end
    end
end

function ADAddonCrossing.saveSettings()
    local ok, err = pcall(function()
        createFolder(getUserProfileAppPath() .. "modSettings/")
        createFolder(getUserProfileAppPath() .. "modSettings/FS25_AutoDriveAddon/")
        local xml = createXMLFile("adAddonCrossing", getSettingsFile(), "crossing")
        if xml ~= nil and xml ~= 0 then
            setXMLBool(xml, "crossing#enabled", ADAddonCrossing.enabled)
            setXMLInt(xml, "crossing#watchDistance", ADAddonCrossing.watchDist)
            saveXMLFile(xml)
            delete(xml)
        end
    end)
    if not ok then log("échec de la sauvegarde des réglages : %s", tostring(err)) end
end

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

local function getIndex(list, v)
    local best, bestDiff = 1, math.huge
    for i, val in ipairs(list) do
        local d = math.abs(val - v)
        if d < bestDiff then best, bestDiff = i, d end
    end
    return best
end

function ADAddonCrossing:onEnabledChanged(state)
    ADAddonCrossing.enabled = state == 2
    ADAddonCrossing.saveSettings()
    log("regarder aux routes : %s", ADAddonCrossing.enabled and "oui" or "non")
end

function ADAddonCrossing:onDistChanged(state)
    local v = ADAddonCrossing.WATCH_DISTS[state]
    if v ~= nil then
        ADAddonCrossing.watchDist = v
        ADAddonCrossing.saveSettings()
        log("distance de regard : %d m", v)
    end
end

local function addRow(layout, template, label, tooltip, texts, state, callback)
    local row = template:clone(layout)
    local option = findFirst(row, isRealMultiText)
    if option == nil then return nil end
    for _, c in ipairs(row.elements) do
        if c.isa ~= nil and c:isa(TextElement) then
            c:setText(label)
            break
        end
    end
    local tip = findFirst(row, function(c)
        return c.isa ~= nil and c:isa(TextElement) and profileContains(c, "tooltip")
    end)
    if tip ~= nil then tip:setText(tooltip) end
    option:setTexts(texts)
    option:setState(state)
    option.target = ADAddonCrossing
    option.onClickCallback = callback
    return option
end

function ADAddonCrossing.buildUI(frame)
    local layout = frame.generalSettingsLayout or frame.gameSettingsLayout
    if layout == nil or layout.elements == nil then return end
    local template
    for _, row in ipairs(layout.elements) do
        if not isMultiText(row) and findFirst(row, isRealMultiText) ~= nil then
            template = row
            break
        end
    end
    if template == nil then return end

    ADAddonCrossing.enabledOption = addRow(layout, template,
        T("Regarder avant de traverser une route", "Look before crossing a road"),
        T("AutoDrive regarde la route des deux côtés avant de la couper ou de la rejoindre, et attend si un véhicule arrive.",
          "AutoDrive looks both ways before crossing or joining a road, and waits if a vehicle is coming."),
        { T("Non", "No"), T("Oui", "Yes") }, ADAddonCrossing.enabled and 2 or 1, ADAddonCrossing.onEnabledChanged)

    local texts = {}
    for i, v in ipairs(ADAddonCrossing.WATCH_DISTS) do texts[i] = v .. " m" end
    ADAddonCrossing.distOption = addRow(layout, template,
        T("Distance de regard sur la route", "Road look distance"),
        T("Longueur de route regardée de chaque côté du croisement.", "Length of road watched on each side of the crossing."),
        texts, getIndex(ADAddonCrossing.WATCH_DISTS, ADAddonCrossing.watchDist), ADAddonCrossing.onDistChanged)

    if layout.invalidateLayout ~= nil then layout:invalidateLayout() end
    ADAddonCrossing.built = true
end

function ADAddonCrossing.onSettingsFrameOpen(frame)
    if not ADAddonCrossing.active then return end
    if not ADAddonCrossing.built then
        local ok, err = pcall(ADAddonCrossing.buildUI, frame)
        if not ok then log("erreur menu : %s", tostring(err)) end
    else
        if ADAddonCrossing.enabledOption ~= nil then ADAddonCrossing.enabledOption:setState(ADAddonCrossing.enabled and 2 or 1) end
        if ADAddonCrossing.distOption ~= nil then ADAddonCrossing.distOption:setState(getIndex(ADAddonCrossing.WATCH_DISTS, ADAddonCrossing.watchDist)) end
    end
end

-- chargé après Settings.lua : les lignes arrivent sous celles de l'addon
if InGameMenuSettingsFrame ~= nil and InGameMenuSettingsFrame.onFrameOpen ~= nil then
    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, function(frame)
        ADAddonCrossing.onSettingsFrameOpen(frame)
    end)
end

-------------------------------------------------------------------------------
-- Branchement sur AutoDrive
-------------------------------------------------------------------------------

function ADAddonCrossing.install(autoDrive)
    ADAddonCrossing.active = true
    ADAddonCrossing.loadSettings()

    local taskModule = ADAddon.getAutoDriveGlobal("ADTaskModule")
    if taskModule == nil or taskModule.update == nil then
        log("ADTaskModule introuvable, inactif")
        return
    end
    local originalUpdate = taskModule.update
    taskModule.update = function(self, dt, ...)
        local ok, wait = pcall(crossStep, self, dt)
        if not ok then
            if not ADAddonCrossing.errorShown then
                ADAddonCrossing.errorShown = true
                log("erreur : %s", tostring(wait))
            end
            if self.vehicle ~= nil then
                pcall(clear, self.vehicle)
            end
        elseif wait then
            return
        end
        return originalUpdate(self, dt, ...)
    end

    local drivePath = ADAddon.getAutoDriveGlobal("ADDrivePathModule")
    if drivePath ~= nil and drivePath.getSpeedLimitBySteeringAngle ~= nil then
        local originalLimit = drivePath.getSpeedLimitBySteeringAngle
        drivePath.getSpeedLimitBySteeringAngle = function(self, ...)
            local limit = originalLimit(self, ...)
            local kmh = self.vehicle ~= nil and self.vehicle.adAddonCrossSpeed or nil
            if kmh ~= nil and limit ~= nil then
                -- hors réseau AutoDrive, la valeur est multipliée par 1,5 ensuite
                if self.isOnRoadNetwork ~= nil and not self:isOnRoadNetwork() then
                    kmh = kmh / 1.5
                end
                return math.min(limit, kmh)
            end
            return limit
        end
    end

    local stateModule = ADAddon.getAutoDriveGlobal("ADStateModule")
    if stateModule ~= nil and stateModule.setActive ~= nil then
        local originalSetActive = stateModule.setActive
        stateModule.setActive = function(self, active, ...)
            if not active and self.vehicle ~= nil then
                pcall(clear, self.vehicle)
            end
            return originalSetActive(self, active, ...)
        end
    end

    log("regarder avant de traverser branché sur AutoDrive (%s, %d m)", ADAddonCrossing.enabled and "oui" or "non", ADAddonCrossing.watchDist)
end

ADAddon.addModule(ADAddonCrossing)
