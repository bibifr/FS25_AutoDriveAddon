-- AutoDrive Addon : addon personnel pour AutoDrive (AutoDrive n'est pas modifié)

ADAddon = {}
ADAddon.modName = g_currentModName
ADAddon.modules = {}

-- Chaque mod a son propre environnement Lua : on cherche d'abord dans celui d'AutoDrive
function ADAddon.getAutoDriveGlobal(name)
    local env = _G["FS25_AutoDrive"]
    if type(env) == "table" and env[name] ~= nil then
        return env[name]
    end
    return _G[name]
end

function ADAddon.addModule(module)
    table.insert(ADAddon.modules, module)
end

ADAddon.REQUIRED_MOD = "FS25_RealisticMechanicalSystems"

function ADAddon:loadMap(name)
    if g_modIsLoaded == nil or not g_modIsLoaded[ADAddon.REQUIRED_MOD] then
        print("AutoDriveAddon : " .. ADAddon.REQUIRED_MOD .. " absent, addon inactif")
        return
    end
    local autoDrive = ADAddon.getAutoDriveGlobal("AutoDrive")
    if autoDrive == nil then
        print("AutoDriveAddon : AutoDrive introuvable, addon inactif")
        return
    end
    for _, module in ipairs(ADAddon.modules) do
        module.install(autoDrive)
    end
end

addModEventListener(ADAddon)
