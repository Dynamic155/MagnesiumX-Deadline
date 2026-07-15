local SEARCH_QUERY = 'game:GetService("ReplicatedStorage"), "module", "caster", "caster"'
local IGNORE_WHITESPACE = true
local YIELD_EVERY = 20
local YIELD_TIME = 0.1

local IGNORE_PATHS = {
    "CorePackages.*",
    "CoreGui.*",
    "ReplicatedStorage.plugin.include.node_modules.*",
    "ReplicatedStorage.include.node_modules.*",
    "ReplicatedStorage.attachments.*"
}

local SCRIPT_CLASSES = {
    LocalScript = "LocalScripts",
    ModuleScript = "ModuleScripts"
}

local function log(...)
    print("[Script Search]", ...)
end

local function normalizeText(text)
    if not IGNORE_WHITESPACE then
        return text
    end

    return string.gsub(text, "%s+", "")
end

local function pathMatchesPattern(path, pattern)
    local escapedPattern = string.gsub(pattern, "([^%w%.%*])", "%%%1")
    local luaPattern = "^" .. string.gsub(escapedPattern, "%*", ".*") .. "$"

    return string.match(path, luaPattern) ~= nil
end

local function isIgnoredPath(path)
    for _, pattern in ipairs(IGNORE_PATHS) do
        if pathMatchesPattern(path, pattern) then
            return true
        end
    end

    return false
end

local function includes(text, query)
    text = string.lower(normalizeText(text))
    query = string.lower(normalizeText(query))

    return string.find(text, query, 1, true) ~= nil
end

local function getScriptType(instance)
    for className, resultKey in pairs(SCRIPT_CLASSES) do
        if instance:IsA(className) then
            return resultKey
        end
    end

    return nil
end

local function tryDecompile(scriptInstance)
    local success, source = pcall(decompile, scriptInstance)

    if not success then
        warn("[Script Search] Failed to decompile:", scriptInstance:GetFullName())
        return nil
    end

    if type(source) ~= "string" then
        return nil
    end

    return source
end

local function createResult(scriptInstance, source)
    return {
        Instance = scriptInstance,
        Name = scriptInstance.Name,
        Path = scriptInstance:GetFullName(),
        Source = source
    }
end

local function collectScripts()
    local scripts = {
        LocalScripts = {},
        ModuleScripts = {}
    }

    local ignoredCount = 0

    log("Collecting scripts...")

    for _, instance in ipairs(game:GetDescendants()) do
        local resultKey = getScriptType(instance)

        if not resultKey then
            continue
        end

        local path = instance:GetFullName()

        if isIgnoredPath(path) then
            ignoredCount += 1
            continue
        end

        table.insert(scripts[resultKey], instance)
    end

    log("Found", #scripts.LocalScripts, "LocalScripts")
    log("Found", #scripts.ModuleScripts, "ModuleScripts")
    log("Ignored", ignoredCount, "scripts")

    return scripts
end

local function searchScriptList(scriptList, scriptTypeName, query, results)
    local total = #scriptList

    for index, scriptInstance in ipairs(scriptList) do
        local path = scriptInstance:GetFullName()

        log("Searching", scriptTypeName, index .. "/" .. total, path)

        local source = tryDecompile(scriptInstance)

        if source and includes(source, query) then
            table.insert(results, createResult(scriptInstance, source))
            log("Match found:", path)
        end

        if index % YIELD_EVERY == 0 then
            task.wait(YIELD_TIME)
        end
    end
end

local function searchScripts(query)
    local scripts = collectScripts()

    local results = {
        LocalScripts = {},
        ModuleScripts = {}
    }

    task.wait(YIELD_TIME)

    searchScriptList(
        scripts.LocalScripts,
        "LocalScript",
        query,
        results.LocalScripts
    )

    task.wait(YIELD_TIME)

    searchScriptList(
        scripts.ModuleScripts,
        "ModuleScript",
        query,
        results.ModuleScripts
    )

    return results
end

local function printResultGroup(title, results)
    log("-----", title, "-----")
    log("Matches:", #results)

    for _, result in ipairs(results) do
        print(result.Path)
    end
end

local function printResults(results)
    log("========== SEARCH COMPLETE ==========")

    printResultGroup("LocalScripts", results.LocalScripts)
    printResultGroup("ModuleScripts", results.ModuleScripts)

    log("=====================================")
end

local results = searchScripts(SEARCH_QUERY)

printResults(results)
