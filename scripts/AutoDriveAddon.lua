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

function ADAddon:loadMap(name)
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
