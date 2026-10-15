-- Moteur coupé par AutoDrive : seuls les phares de base restent allumés,
-- puis les feux sont remis comme avant au redémarrage du moteur

ADAddonLightsOff = {}

-- Bit 0 du masque = phares de base (touche L)
ADAddonLightsOff.HEADLIGHTS_MASK = 1

local function getLightsState(vehicle)
    local spec = vehicle.spec_lights
    return {
        mask = spec.lightsTypesMask or 0,
        beacon = spec.beaconLightsActive == true,
        turn = spec.turnLightState or Lights.TURNLIGHT_OFF
    }
end

local function applyLightsState(vehicle, state)
    local current = getLightsState(vehicle)
    if current.mask ~= state.mask and vehicle.setLightsTypesMask ~= nil then
        vehicle:setLightsTypesMask(state.mask, true)
    end
    if current.beacon ~= state.beacon and vehicle.setBeaconLightsVisibility ~= nil then
        vehicle:setBeaconLightsVisibility(state.beacon)
    end
    if current.turn ~= state.turn and vehicle.setTurnLightState ~= nil then
        vehicle:setTurnLightState(state.turn)
    end
end

local PARKED_STATE = {
    mask = ADAddonLightsOff.HEADLIGHTS_MASK,
    beacon = false,
    turn = Lights.TURNLIGHT_OFF
}

function ADAddonLightsOff.install(autoDrive)
    local original = autoDrive.updateAutoDriveLights
    if original == nil then
        print("AutoDriveAddon : updateAutoDriveLights introuvable, gestion des feux inactive")
        return
    end

    -- AutoDrive appelle AutoDrive.updateAutoDriveLights(vehicle) à chaque image
    autoDrive.updateAutoDriveLights = function(vehicle, switchOff)
        if vehicle.spec_lights == nil or vehicle.getIsMotorStarted == nil then
            return original(vehicle, switchOff)
        end

        if switchOff then
            -- AutoDrive s'arrête : il gère lui-même les feux
            vehicle.adAddonSavedLights = nil
            return original(vehicle, switchOff)
        end

        local isActive = vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule:isActive()

        if isActive and not vehicle:getIsMotorStarted() then
            if vehicle.adAddonSavedLights == nil then
                vehicle.adAddonSavedLights = getLightsState(vehicle)
            end
            applyLightsState(vehicle, PARKED_STATE)
            return
        end

        if vehicle.adAddonSavedLights ~= nil and vehicle:getIsMotorStarted() then
            applyLightsState(vehicle, vehicle.adAddonSavedLights)
            vehicle.adAddonSavedLights = nil
        end

        return original(vehicle, switchOff)
    end

    print("AutoDriveAddon : feux moteur coupé (phares de base seuls) branchés sur AutoDrive")
end

ADAddon.addModule(ADAddonLightsOff)
