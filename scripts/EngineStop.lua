-- Délai avant qu'AutoDrive coupe le moteur d'un véhicule arrêté
-- AutoDrive coupe le moteur après 10 s à l'arrêt (valeur fixe dans son code).
-- Ici ce délai est remplacé par celui du menu, ou la coupure est bloquée (« Jamais »).

ADAddonEngineStop = {}

ADAddonEngineStop.AD_DELAY_MS = 10000   -- délai codé dans AutoDrive
ADAddonEngineStop.delayMs = 10000       -- 0 = jamais couper

local function patchTimer(module)
    local timer = module.stoppedTimer
    if timer == nil or timer.adAddonPatched then
        return
    end
    local baseTimer = timer.timer
    -- Seul l'appel avec 10 s (coupure moteur) est changé, pas les autres délais (blocage 15 s)
    timer.timer = function(t, signal, time, dt)
        if time == ADAddonEngineStop.AD_DELAY_MS and ADAddonEngineStop.delayMs > 0 then
            time = ADAddonEngineStop.delayMs
        end
        return baseTimer(t, signal, time, dt)
    end
    timer.adAddonPatched = true
end

function ADAddonEngineStop.install(autoDrive)
    local sdm = ADAddon.getAutoDriveGlobal("ADSpecialDrivingModule")
    if sdm == nil or sdm.reset == nil or sdm.shouldStopMotor == nil then
        print("AutoDriveAddon : ADSpecialDrivingModule introuvable, délai de coupure moteur inactif")
        return
    end

    local originalReset = sdm.reset
    sdm.reset = function(self, ...)
        local r = originalReset(self, ...)
        patchTimer(self)
        return r
    end

    local originalShouldStop = sdm.shouldStopMotor
    sdm.shouldStopMotor = function(self, ...)
        patchTimer(self)
        if ADAddonEngineStop.delayMs <= 0 then
            return false
        end
        return originalShouldStop(self, ...)
    end

    print("AutoDriveAddon : délai de coupure moteur AutoDrive branché (" .. ADAddonEngineStop.describe() .. ")")
end

function ADAddonEngineStop.describe()
    local ms = ADAddonEngineStop.delayMs
    if ms <= 0 then
        return "jamais"
    end
    return string.format("%d s", ms / 1000)
end

ADAddon.addModule(ADAddonEngineStop)
