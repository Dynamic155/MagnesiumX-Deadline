-- essentially a script that searches through all the scripts in the game, finds ur query, gives it to ai, and u profit ig... 
-- oh yeah this uses ollama so if ur potato pc can't run it rip gg, anyways gl! uwu

local HttpService = game:GetService("HttpService")

--// =========================
--// config 
--// =========================

local CONFIG = {
	Search = {
		Queries = {
			"Test",
			-- "remoteevent", 
			-- "fireserver", 
			-- "invokeserver", 
		},

		Mode = "contains", -- contains, exact, pattern 
		IgnoreCase = true,
		IgnoreWhitespace = true,

		ContextLines = 8,
		MaxMatchesPerScript = 12,
		MaxSourceChars = 12000,

		YieldEvery = 5,
		YieldTime = 0.05,
	},

	Classes = {
		LocalScript = true,
		ModuleScript = true,
		Script = false,
	},

	Paths = {
		-- if includepaths is empty, all paths are included unless ignored. 
		IncludePaths = {
			-- "players.*", 
			-- "replicatedstorage.*", 
			-- "startergui.*", 
		},

		IgnorePaths = {
			-- these are examples uwu plz change them or u will have to search thru sm scripts </3

			-- "CorePackages.*",
			-- "CoreGui.*",
			-- "ReplicatedStorage.plugin.include.node_modules.*",
			-- "ReplicatedStorage.include.node_modules.*",
			-- "ReplicatedStorage.attachments.*"
		},
	},

	AI = {
		Enabled = true,
		Url = "http://localhost:11434/api/generate", -- put ollama things here 
		Model = "dolphin-mixtral", -- change the model here 

		-- first ai query handles normal analysis tasks 1-5. 
		RunSummaryQuery = true,

		-- second ai query asks only for task 6: deobfuscation. 
		RunDeobfuscationQuery = true,

		TimeoutRetries = 3,
		RetryDelay = 1,
		CacheSummaries = true,
	},

	Discord = {
		Enabled = false,
		WebhookUrl = "", -- webhook here 
		UseEmbeds = true,

		SendIndexFirst = true,
		SendFullReports = true,

		MaxMessageChars = 1900,
		MaxEmbedDescriptionChars = 3900,
	},

	Export = {
		Enabled = true,
		Format = "json", -- json only for now 

		-- uses writefile only if ur environment provides it. 
		WriteToFile = false,
		OutputFileName = "script_search_results.json",

		-- always prints export json when enabled = true. 
		PrintJson = true,
	},

	Safety = {
		RedactSecrets = true,
	},
}

--// =========================
--// types 
--// =========================

type ScriptClassName = "LocalScript" | "ModuleScript" | "Script"

type QueryMatch = {
	Query: string,
	LineNumber: number,
	LineText: string,
	Context: string,
}

type ScriptResult = {
	Instance: Instance,
	Name: string,
	Path: string,
	Source: string,
	SourceHash: string,
	ScriptType: string,
	ObfuscationScore: number,
	MatchedQueries: { string },
	Matches: { QueryMatch },
	DuplicateOf: string?,
}

type SearchResults = {
	LocalScripts: { ScriptResult },
	ModuleScripts: { ScriptResult },
	Scripts: { ScriptResult },
}

type DiscordEmbed = {
	Title: string,
	Description: string,
	Color: number,
	Fields: { any },
	Footer: string,
}

--// =========================
--// logging and json helpers 
--// =========================

local function log(...)
	print("[Script Search]", ...)
end

local function warnLog(...)
	warn("[Script Search]", ...)
end

local function jsonEncode(value: any): string
	return HttpService:JSONEncode(value)
end

local function jsonDecode(value: string): any
	return HttpService:JSONDecode(value)
end

--// =========================
--// text helpers 
--// =========================

local function truncateText(text: string, maxLength: number): string
	if #text <= maxLength then
		return text
	end

	return string.sub(text, 1, maxLength) .. "\n\n[TRUNCATED]"
end

local function normalizeSearchText(text: string): string
	if CONFIG.Search.IgnoreCase then
		text = string.lower(text)
	end

	if CONFIG.Search.IgnoreWhitespace then
		text = string.gsub(text, "%s+", "")
	end

	return text
end

local function escapePattern(text: string): string
	return string.gsub(text, "([^%w])", "%%%1")
end

local function wildcardToPattern(wildcard: string): string
	local escaped = escapePattern(wildcard)
	local pattern = string.gsub(escaped, "%%%*", ".*")

	return "^" .. pattern .. "$"
end

local function pathMatchesWildcard(path: string, wildcard: string): boolean
	return string.match(path, wildcardToPattern(wildcard)) ~= nil
end

local function pathMatchesAny(path: string, wildcards: { string }): boolean
	for _, wildcard in ipairs(wildcards) do
		if pathMatchesWildcard(path, wildcard) then
			return true
		end
	end

	return false
end

local function isIgnoredPath(path: string): boolean
	return pathMatchesAny(path, CONFIG.Paths.IgnorePaths)
end

local function isIncludedPath(path: string): boolean
	if #CONFIG.Paths.IncludePaths == 0 then
		return true
	end

	return pathMatchesAny(path, CONFIG.Paths.IncludePaths)
end

local function splitLines(text: string): { string }
	local lines = {}

	for line in string.gmatch(text .. "\n", "(.-)\n") do
		table.insert(lines, line)
	end

	return lines
end

local function addLineNumbers(source: string): string
	local numberedLines = {}
	local lines = splitLines(source)

	for index, line in ipairs(lines) do
		table.insert(numberedLines, tostring(index) .. ": " .. line)
	end

	return table.concat(numberedLines, "\n")
end

local function uniqueAppend(list: { string }, value: string)
	for _, existing in ipairs(list) do
		if existing == value then
			return
		end
	end

	table.insert(list, value)
end

-- this is not cryptographic. it is only used to identify duplicate source text during one run. 
local function simpleHash(text: string): string
	local hash = 0

	for i = 1, #text do
		hash = (hash * 31 + string.byte(text, i)) % 1000000007
	end

	return tostring(hash)
end

--// =========================
--// secret redaction 
--// =========================

local function redactSecrets(text: string): string
	if not CONFIG.Safety.RedactSecrets then
		return text
	end

	local redacted = text

	-- discord webhooks 
	redacted = string.gsub(
		redacted,
		"https://discord%.com/api/webhooks/%d+/[%w%-%_]+",
		"[REDACTED_DISCORD_WEBHOOK]"
	)

	-- local/internal http urls with ports 
	redacted = string.gsub(
		redacted,
		"https?://[%w%.%-_]+:%d+[^%s\"']*",
		"[REDACTED_INTERNAL_URL]"
	)

	-- bearer tokens 
	redacted = string.gsub(
		redacted,
		"Bearer%s+[%w%._%-]+",
		"Bearer [REDACTED]"
	)

	-- common token-looking strings with jwt-like structure 
	redacted = string.gsub(
		redacted,
		"[%w_%-]+%.eyJ[%w_%-%.]+",
		"[REDACTED_TOKEN]"
	)

	-- roblox security cookie 
	redacted = string.gsub(
		redacted,
		"_%|WARNING:%-DO%-NOT%-SHARE%-THIS%.+",
		"[REDACTED_ROBLOX_COOKIE]"
	)

	-- generic api key style assignments 
	redacted = string.gsub(
		redacted,
		"([Aa][Pp][Ii]_?[Kk][Ee][Yy]%s*=%s*)[\"'][^\"']+[\"']",
		"%1\"[REDACTED_API_KEY]\""
	)

	redacted = string.gsub(
		redacted,
		"([Tt][Oo][Kk][Ee][Nn]%s*=%s*)[\"'][^\"']+[\"']",
		"%1\"[REDACTED_TOKEN]\""
	)

	redacted = string.gsub(
		redacted,
		"([Ss][Ee][Cc][Rr][Ee][Tt]%s*=%s*)[\"'][^\"']+[\"']",
		"%1\"[REDACTED_SECRET]\""
	)

	return redacted
end

local function truncateSource(source: string): string
	return truncateText(source, CONFIG.Search.MaxSourceChars)
end

local function getSafeSource(source: string): string
	return redactSecrets(truncateSource(source))
end

--// =========================
--// search helpers 
--// =========================

local function sourceMatchesQuery(source: string, query: string): boolean
	local mode = CONFIG.Search.Mode

	if mode == "contains" then
		local normalizedSource = normalizeSearchText(source)
		local normalizedQuery = normalizeSearchText(query)
		return string.find(normalizedSource, normalizedQuery, 1, true) ~= nil
	end

	if mode == "exact" then
		return normalizeSearchText(source) == normalizeSearchText(query)
	end

	if mode == "pattern" then
		local searchSource = source
		local searchQuery = query

		if CONFIG.Search.IgnoreCase then
			searchSource = string.lower(searchSource)
			searchQuery = string.lower(searchQuery)
		end

		return string.find(searchSource, searchQuery) ~= nil
	end

	warnLog("Unknown search mode:", mode, "falling back to contains")
	local normalizedSource = normalizeSearchText(source)
	local normalizedQuery = normalizeSearchText(query)
	return string.find(normalizedSource, normalizedQuery, 1, true) ~= nil
end

local function lineMatchesQuery(line: string, query: string): boolean
	return sourceMatchesQuery(line, query)
end

local function buildContext(lines: { string }, lineNumber: number, contextLines: number): string
	local startLine = math.max(1, lineNumber - contextLines)
	local endLine = math.min(#lines, lineNumber + contextLines)

	local output = {}

	for i = startLine, endLine do
		local marker = if i == lineNumber then ">> " else "   "
		table.insert(output, marker .. tostring(i) .. ": " .. lines[i])
	end

	return table.concat(output, "\n")
end

local function findQueryMatches(source: string, queries: { string }): ({ QueryMatch }, { string })
	local lines = splitLines(source)
	local matches: { QueryMatch } = {}
	local matchedQueries: { string } = {}

	for _, query in ipairs(queries) do
		local foundForQuery = 0

		for lineNumber, line in ipairs(lines) do
			if lineMatchesQuery(line, query) then
				foundForQuery += 1
				uniqueAppend(matchedQueries, query)

				table.insert(matches, {
					Query = query,
					LineNumber = lineNumber,
					LineText = line,
					Context = buildContext(lines, lineNumber, CONFIG.Search.ContextLines),
				})

				if foundForQuery >= CONFIG.Search.MaxMatchesPerScript then
					break
				end
			end
		end
	end

	return matches, matchedQueries
end

local function getObfuscationScore(source: string): number
	local score = 0

	if string.find(source, "loadstring", 1, true) then
		score += 2
	end

	if string.find(source, "getfenv", 1, true) then
		score += 1
	end

	if string.find(source, "setfenv", 1, true) then
		score += 1
	end

	if string.find(source, "\\%d%d%d") then
		score += 1
	end

	if string.find(source, "string%.char") then
		score += 1
	end

	if string.find(source, "bit32") then
		score += 1
	end

	if #source > 5000 and string.find(source, "_G", 1, true) then
		score += 1
	end

	if string.find(source, "debug%.") then
		score += 1
	end

	return score
end

--// =========================
--// script helpers 
--// =========================

local function getScriptResultKey(instance: Instance): string?
	if instance:IsA("LocalScript") and CONFIG.Classes.LocalScript then
		return "LocalScripts"
	end

	if instance:IsA("ModuleScript") and CONFIG.Classes.ModuleScript then
		return "ModuleScripts"
	end

	if instance:IsA("Script") and CONFIG.Classes.Script then
		return "Scripts"
	end

	return nil
end

local function getScriptTypeName(instance: Instance): string
	if instance:IsA("LocalScript") then
		return "LocalScript"
	end

	if instance:IsA("ModuleScript") then
		return "ModuleScript"
	end

	if instance:IsA("Script") then
		return "Script"
	end

	return "Unknown"
end

local function tryGetSource(scriptInstance: Instance): string?
	-- in studio/plugin contexts, source may be accessible for scripts u own. 
	local sourceSuccess, source = pcall(function()
		return (scriptInstance :: any).Source
	end)

	if sourceSuccess and type(source) == "string" and source ~= "" then
		return source
	end

	-- some executor environments expose decompile(). only use where authorized. 
	if type((getfenv() :: any).decompile) == "function" then
		local decompileSuccess, decompiled = pcall(function()
			return (getfenv() :: any).decompile(scriptInstance)
		end)

		if decompileSuccess and type(decompiled) == "string" then
			return decompiled
		end
	end

	warnLog("Unable to read source for:", scriptInstance:GetFullName())
	return nil
end

local function createResult(
	scriptInstance: Instance,
	source: string,
	matches: { QueryMatch },
	matchedQueries: { string },
	duplicateOf: string?
): ScriptResult
	return {
		Instance = scriptInstance,
		Name = scriptInstance.Name,
		Path = scriptInstance:GetFullName(),
		Source = source,
		SourceHash = simpleHash(source),
		ScriptType = getScriptTypeName(scriptInstance),
		ObfuscationScore = getObfuscationScore(source),
		MatchedQueries = matchedQueries,
		Matches = matches,
		DuplicateOf = duplicateOf,
	}
end

local function collectScripts(): { LocalScripts: { Instance }, ModuleScripts: { Instance }, Scripts: { Instance } }
	local scripts = {
		LocalScripts = {},
		ModuleScripts = {},
		Scripts = {},
	}

	local ignoredCount = 0
	local notIncludedCount = 0

	log("Collecting scripts...")

	for _, instance in ipairs(game:GetDescendants()) do
		local resultKey = getScriptResultKey(instance)

		if not resultKey then
			continue
		end

		local path = instance:GetFullName()

		if isIgnoredPath(path) then
			ignoredCount += 1
			continue
		end

		if not isIncludedPath(path) then
			notIncludedCount += 1
			continue
		end

		table.insert((scripts :: any)[resultKey], instance)
	end

	log("Found", #scripts.LocalScripts, "LocalScripts")
	log("Found", #scripts.ModuleScripts, "ModuleScripts")
	log("Found", #scripts.Scripts, "Scripts")
	log("Ignored", ignoredCount, "scripts")
	log("Excluded by include paths", notIncludedCount, "scripts")

	return scripts
end

--// =========================
--// searching 
--// =========================

local function searchScriptList(
	scriptList: { Instance },
	scriptTypeName: string,
	results: { ScriptResult },
	seenHashes: { [string]: string }
)
	local total = #scriptList

	for index, scriptInstance in ipairs(scriptList) do
		local path = scriptInstance:GetFullName()

		log("Searching", scriptTypeName, index .. "/" .. total, path)

		local source = tryGetSource(scriptInstance)

		if source then
			local matches, matchedQueries = findQueryMatches(source, CONFIG.Search.Queries)

			if #matches > 0 then
				local hash = simpleHash(source)
				local duplicateOf = seenHashes[hash]

				if not duplicateOf then
					seenHashes[hash] = path
				end

				table.insert(results, createResult(
					scriptInstance,
					source,
					matches,
					matchedQueries,
					duplicateOf
				))

				log("Match found:", path, "Queries:", table.concat(matchedQueries, ", "))
			end
		end

		if index % CONFIG.Search.YieldEvery == 0 then
			task.wait(CONFIG.Search.YieldTime)
		end
	end
end

local function searchScripts(): SearchResults
	local scripts = collectScripts()

	local results: SearchResults = {
		LocalScripts = {},
		ModuleScripts = {},
		Scripts = {},
	}

	local seenHashes: { [string]: string } = {}

	task.wait(CONFIG.Search.YieldTime)

	searchScriptList(
		scripts.LocalScripts,
		"LocalScript",
		results.LocalScripts,
		seenHashes
	)

	task.wait(CONFIG.Search.YieldTime)

	searchScriptList(
		scripts.ModuleScripts,
		"ModuleScript",
		results.ModuleScripts,
		seenHashes
	)

	task.wait(CONFIG.Search.YieldTime)

	searchScriptList(
		scripts.Scripts,
		"Script",
		results.Scripts,
		seenHashes
	)

	return results
end

--// =========================
--// result helpers 
--// =========================

local function flattenResults(results: SearchResults): { ScriptResult }
	local flatResults: { ScriptResult } = {}

	for _, result in ipairs(results.LocalScripts) do
		table.insert(flatResults, result)
	end

	for _, result in ipairs(results.ModuleScripts) do
		table.insert(flatResults, result)
	end

	for _, result in ipairs(results.Scripts) do
		table.insert(flatResults, result)
	end

	return flatResults
end

local function makeMatchSummary(result: ScriptResult): string
	local output = {}

	table.insert(output, "Matched queries: " .. table.concat(result.MatchedQueries, ", "))
	table.insert(output, "Obfuscation score: " .. tostring(result.ObfuscationScore))

	if result.DuplicateOf then
		table.insert(output, "Duplicate source of: " .. result.DuplicateOf)
	end

	table.insert(output, "")
	table.insert(output, "Match contexts:")

	for index, match in ipairs(result.Matches) do
		table.insert(output, "")
		table.insert(output, "Match " .. tostring(index) .. " | Query: " .. match.Query .. " | Line: " .. tostring(match.LineNumber))
		table.insert(output, "```lua")
		table.insert(output, redactSecrets(match.Context))
		table.insert(output, "```")
	end

	return table.concat(output, "\n")
end

local function getRiskTagsInstruction(): string
	return [[
Classify the script using any relevant tags from this list:
- UI
- Networking
- DataStore
- Monetization
- Anti-cheat
- Admin
- Obfuscated
- Suspicious
- Utility
- Gameplay
- Remotes
- Client-only
- Server-only
]]
end

--// =========================
--// ai prompts 
--// =========================

local function makeSummaryPrompt(result: ScriptResult): string
	local moduleInstructions = ""

	if result.ScriptType == "ModuleScript" then
		moduleInstructions = [[

Because this is a ModuleScript:
- Identify useful functions, methods, tables, or values it appears to expose.
- Give real examples of functions that can be run relating to the script when the names are clear.
- Suggest possible ways a developer might require and call it.
- If exact function names are unclear, say that instead of guessing.
- Include small Luau usage examples where possible.
]]
	end

	return [[
You are analyzing a Roblox Luau script that the user is authorized to inspect.

The user searched for these queries:
]] .. table.concat(CONFIG.Search.Queries, ", ") .. [[

Search settings:
Mode: ]] .. CONFIG.Search.Mode .. [[
Ignore case: ]] .. tostring(CONFIG.Search.IgnoreCase) .. [[
Ignore whitespace: ]] .. tostring(CONFIG.Search.IgnoreWhitespace) .. [[

Script metadata:
Path: ]] .. result.Path .. [[
Name: ]] .. result.Name .. [[
Type: ]] .. result.ScriptType .. [[
Source hash: ]] .. result.SourceHash .. [[
Obfuscation score: ]] .. tostring(result.ObfuscationScore) .. [[
Duplicate of: ]] .. tostring(result.DuplicateOf) .. [[

Matched query context:
]] .. makeMatchSummary(result) .. [[

Tasks:
1. Give a concise general description of what this script does.
2. Explain why this script may have matched the user's search query or queries.
3. Explain what the matched query or queries appear to be used for in this script.
4. Mention important remotes, services, UI objects, variables, or game systems involved.
5. Keep the summary practical and developer-focused.

]] .. getRiskTagsInstruction() .. moduleInstructions .. [[

Do not return a deobfuscated script in this response. That is handled by a separate request.

Decompiled/source text with line numbers:
```lua
]] .. addLineNumbers(getSafeSource(result.Source)) .. [[
```
]]
end

local function makeDeobfuscationPrompt(result: ScriptResult): string
	return [[
You are analyzing a Roblox Luau script that the user is authorized to inspect.

Script metadata:
Path: ]] .. result.Path .. [[
Name: ]] .. result.Name .. [[
Type: ]] .. result.ScriptType .. [[
Source hash: ]] .. result.SourceHash .. [[
Obfuscation score: ]] .. tostring(result.ObfuscationScore) .. [[

Task:
6. Return a deobfuscated version of the script.

Rules:
- Preserve behavior as closely as possible.
- Rename unclear variables to descriptive names when meaning is reasonably clear.
- Add short comments only where they clarify intent.
- If the code is not actually obfuscated, return a cleaner readable version and say it was not strongly obfuscated.
- Do not invent missing dependencies or APIs.
- Keep output focused on the rewritten Luau code.

Original source:
```lua
]] .. getSafeSource(result.Source) .. [[
```
]]
end

--// =========================
--// request helpers 
--// =========================

local function requestOllama(prompt: string): (string?, string?)
	local body = jsonEncode({
		model = CONFIG.AI.Model,
		prompt = prompt,
		stream = false,
	})

	local success, response = pcall(function()
		return request({
			Url = CONFIG.AI.Url,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
			},
			Body = body,
		})
	end)

	if not success then
		return nil, "request() failed"
	end

	if not response.Success then
		return nil, "HTTP " .. tostring(response.StatusCode) .. " " .. tostring(response.StatusMessage)
	end

	local decodeSuccess, data = pcall(function()
		return jsonDecode(response.Body)
	end)

	if not decodeSuccess then
		return nil, "Failed to decode Ollama response"
	end

	if type(data.response) ~= "string" then
		return nil, "Ollama response did not include response text"
	end

	return data.response, nil
end

local function requestOllamaWithRetry(prompt: string): (string?, string?)
	local lastError = nil

	for attempt = 1, CONFIG.AI.TimeoutRetries do
		local response, err = requestOllama(prompt)

		if response then
			return response, nil
		end

		lastError = err
		warnLog("Ollama request failed. Attempt", attempt .. "/" .. CONFIG.AI.TimeoutRetries, err)

		if attempt < CONFIG.AI.TimeoutRetries then
			task.wait(CONFIG.AI.RetryDelay * attempt)
		end
	end

	return nil, lastError or "Unknown Ollama error"
end

--// =========================
--// discord helpers 
--// =========================

local function canSendDiscord(): boolean
	if not CONFIG.Discord.Enabled then
		return false
	end

	if CONFIG.Discord.WebhookUrl == "" then
		warnLog("Discord webhook is enabled, but WebhookUrl is empty.")
		return false
	end

	return true
end

local function sendDiscordPayload(payload: any): boolean
	if not canSendDiscord() then
		return false
	end

	local safePayloadJson = jsonEncode(payload)

	local success, response = pcall(function()
		return request({
			Url = CONFIG.Discord.WebhookUrl,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
			},
			Body = safePayloadJson,
		})
	end)

	if not success then
		warnLog("Discord webhook request failed.")
		return false
	end

	if not response.Success then
		warnLog("Discord webhook failed:", response.StatusCode, response.StatusMessage)
		return false
	end

	log("Discord report sent.")
	return true
end

local function sendDiscordMessage(message: string): boolean
	local safeMessage = truncateText(redactSecrets(message), CONFIG.Discord.MaxMessageChars)

	return sendDiscordPayload({
		content = safeMessage,
	})
end

local function sendDiscordEmbed(embed: DiscordEmbed): boolean
	return sendDiscordPayload({
		embeds = {
			{
				title = embed.Title,
				description = truncateText(redactSecrets(embed.Description), CONFIG.Discord.MaxEmbedDescriptionChars),
				color = embed.Color,
				fields = embed.Fields,
				footer = {
					text = embed.Footer,
				},
			},
		},
	})
end

local function getDiscordColorForResult(result: ScriptResult): number
	if result.ScriptType == "ModuleScript" then
		return 65280
	end

	if result.ScriptType == "Script" then
		return 15105570
	end

	return 3447003
end

local function makeDiscordReportText(result: ScriptResult, summary: string?, deobfuscated: string?): string
	local parts = {
		"**AI Script Report**",
		"",
		"**Path:** `" .. result.Path .. "`",
		"**Type:** `" .. result.ScriptType .. "`",
		"**Search Queries:** `" .. table.concat(result.MatchedQueries, ", ") .. "`",
		"**Obfuscation Score:** `" .. tostring(result.ObfuscationScore) .. "`",
		"**Source Hash:** `" .. result.SourceHash .. "`",
	}

	if result.DuplicateOf then
		table.insert(parts, "**Duplicate Of:** `" .. result.DuplicateOf .. "`")
	end

	if summary then
		table.insert(parts, "")
		table.insert(parts, "**Summary**")
		table.insert(parts, summary)
	end

	if deobfuscated then
		table.insert(parts, "")
		table.insert(parts, "**Deobfuscated Version**")
		table.insert(parts, deobfuscated)
	end

	return redactSecrets(table.concat(parts, "\n"))
end

local function sendDiscordReport(result: ScriptResult, summary: string?, deobfuscated: string?)
	if not canSendDiscord() or not CONFIG.Discord.SendFullReports then
		return
	end

	local reportText = makeDiscordReportText(result, summary, deobfuscated)

	if not CONFIG.Discord.UseEmbeds then
		sendDiscordMessage(reportText)
		return
	end

	sendDiscordEmbed({
		Title = "AI Script Report",
		Description = truncateText(reportText, CONFIG.Discord.MaxEmbedDescriptionChars),
		Color = getDiscordColorForResult(result),
		Fields = {
			{
				name = "Path",
				value = truncateText("`" .. result.Path .. "`", 1024),
				inline = false,
			},
			{
				name = "Type",
				value = "`" .. result.ScriptType .. "`",
				inline = true,
			},
			{
				name = "Queries",
				value = truncateText("`" .. table.concat(result.MatchedQueries, ", ") .. "`", 1024),
				inline = true,
			},
			{
				name = "Obfuscation",
				value = "`" .. tostring(result.ObfuscationScore) .. "`",
				inline = true,
			},
		},
		Footer = "Script Search + Ollama",
	})
end

local function sendDiscordIndex(results: SearchResults)
	if not canSendDiscord() or not CONFIG.Discord.SendIndexFirst then
		return
	end

	local flatResults = flattenResults(results)
	local lines = {
		"**Script Search Complete**",
		"",
		"Total matches: `" .. tostring(#flatResults) .. "`",
		"LocalScripts: `" .. tostring(#results.LocalScripts) .. "`",
		"ModuleScripts: `" .. tostring(#results.ModuleScripts) .. "`",
		"Scripts: `" .. tostring(#results.Scripts) .. "`",
		"",
		"**Matches**",
	}

	for index, result in ipairs(flatResults) do
		local duplicateText = if result.DuplicateOf then " duplicate" else ""
		table.insert(lines, tostring(index) .. ". `" .. result.Path .. "` [" .. result.ScriptType .. duplicateText .. "]")
	end

	sendDiscordMessage(table.concat(lines, "\n"))
end

--// =========================
--// ai summarization 
--// =========================

local SUMMARY_CACHE: { [string]: string } = {}
local DEOBFUSCATION_CACHE: { [string]: string } = {}

local function runSummaryQuery(result: ScriptResult): string?
	if not CONFIG.AI.RunSummaryQuery then
		return nil
	end

	if CONFIG.AI.CacheSummaries and SUMMARY_CACHE[result.SourceHash] then
		log("Using cached summary for", result.Path)
		return SUMMARY_CACHE[result.SourceHash]
	end

	local prompt = makeSummaryPrompt(result)
	local summary, err = requestOllamaWithRetry(prompt)

	if not summary then
		warnLog("Failed summary query:", result.Path, err)
		return nil
	end

	if CONFIG.AI.CacheSummaries then
		SUMMARY_CACHE[result.SourceHash] = summary
	end

	return summary
end

local function runDeobfuscationQuery(result: ScriptResult): string?
	if not CONFIG.AI.RunDeobfuscationQuery then
		return nil
	end

	if CONFIG.AI.CacheSummaries and DEOBFUSCATION_CACHE[result.SourceHash] then
		log("Using cached deobfuscation for", result.Path)
		return DEOBFUSCATION_CACHE[result.SourceHash]
	end

	local prompt = makeDeobfuscationPrompt(result)
	local deobfuscated, err = requestOllamaWithRetry(prompt)

	if not deobfuscated then
		warnLog("Failed deobfuscation query:", result.Path, err)
		return nil
	end

	if CONFIG.AI.CacheSummaries then
		DEOBFUSCATION_CACHE[result.SourceHash] = deobfuscated
	end

	return deobfuscated
end

local function analyzeResult(result: ScriptResult, index: number, total: number)
	log("Analyzing", index .. "/" .. total, result.Path)

	print("")
	print("========== MATCH ==========")
	print("Path:", result.Path)
	print("Type:", result.ScriptType)
	print("Matched Queries:", table.concat(result.MatchedQueries, ", "))
	print("Obfuscation Score:", result.ObfuscationScore)

	if result.DuplicateOf then
		print("Duplicate Of:", result.DuplicateOf)
	end

	print("")
	print(makeMatchSummary(result))

	local summary: string? = nil
	local deobfuscated: string? = nil

	if CONFIG.AI.Enabled then
		if CONFIG.AI.RunSummaryQuery then
			print("")
			print("========== AI SUMMARY QUERY ==========")
			summary = runSummaryQuery(result)

			if summary then
				print(summary)
			else
				print("Summary failed.")
			end
		end

		if CONFIG.AI.RunDeobfuscationQuery then
			print("")
			print("========== AI DEOBFUSCATION QUERY ==========")
			deobfuscated = runDeobfuscationQuery(result)

			if deobfuscated then
				print(deobfuscated)
			else
				print("Deobfuscation failed.")
			end
		end
	else
		log("AI disabled; skipping Ollama queries.")
	end

	print("================================")
	print("")

	sendDiscordReport(result, summary, deobfuscated)

	task.wait(CONFIG.Search.YieldTime)
end

local function analyzeResults(results: SearchResults)
	if not CONFIG.AI.Enabled then
		log("AI summaries disabled.")
		return
	end

	local flatResults = flattenResults(results)
	local total = #flatResults

	if total == 0 then
		log("No matching scripts to analyze.")
		return
	end

	log("Sending", total, "matched scripts to Ollama for analysis...")

	for index, result in ipairs(flatResults) do
		analyzeResult(result, index, total)
	end
end

--// =========================
--// printing and export 
--// =========================

local function printResultPaths(title: string, results: { ScriptResult })
	log("-----", title, "-----")
	log("Matches:", #results)

	for _, result in ipairs(results) do
		local duplicateText = if result.DuplicateOf then " [DUPLICATE]" else ""
		print(result.Path .. duplicateText)
	end
end

local function printFinalResults(results: SearchResults)
	log("========== SEARCH COMPLETE ==========")

	printResultPaths("LocalScripts", results.LocalScripts)
	printResultPaths("ModuleScripts", results.ModuleScripts)
	printResultPaths("Scripts", results.Scripts)

	log("=====================================")
end

local function makeExportableResult(result: ScriptResult): any
	local exportMatches = {}

	for _, match in ipairs(result.Matches) do
		table.insert(exportMatches, {
			query = match.Query,
			lineNumber = match.LineNumber,
			lineText = redactSecrets(match.LineText),
			context = redactSecrets(match.Context),
		})
	end

	return {
		name = result.Name,
		path = result.Path,
		type = result.ScriptType,
		sourceHash = result.SourceHash,
		obfuscationScore = result.ObfuscationScore,
		matchedQueries = result.MatchedQueries,
		duplicateOf = result.DuplicateOf,
		matches = exportMatches,

		-- export redacted source only. 
		source = getSafeSource(result.Source),
	}
end

local function exportResults(results: SearchResults): string
	local flatResults = flattenResults(results)
	local export = {
		generatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		search = {
			queries = CONFIG.Search.Queries,
			mode = CONFIG.Search.Mode,
			ignoreCase = CONFIG.Search.IgnoreCase,
			ignoreWhitespace = CONFIG.Search.IgnoreWhitespace,
		},
		counts = {
			total = #flatResults,
			localScripts = #results.LocalScripts,
			moduleScripts = #results.ModuleScripts,
			scripts = #results.Scripts,
		},
		results = {},
	}

	for _, result in ipairs(flatResults) do
		table.insert(export.results, makeExportableResult(result))
	end

	return jsonEncode(export)
end

local function outputExport(results: SearchResults)
	if not CONFIG.Export.Enabled then
		return
	end

	local exported = exportResults(results)

	if CONFIG.Export.PrintJson then
		print("")
		print("========== JSON EXPORT ==========")
		print(exported)
		print("=================================")
		print("")
	end

	if CONFIG.Export.WriteToFile then
		local env = getfenv() :: any

		if type(env.writefile) == "function" then
			local success, err = pcall(function()
				env.writefile(CONFIG.Export.OutputFileName, exported)
			end)

			if success then
				log("Wrote export to file:", CONFIG.Export.OutputFileName)
			else
				warnLog("Failed to write export file:", err)
			end
		else
			warnLog("writefile is not available in this environment.")
		end
	end
end

--// =========================
--// main 
--// =========================

local function validateConfig(): boolean
	if #CONFIG.Search.Queries == 0 then
		warnLog("No search queries configured.")
		return false
	end

	if CONFIG.AI.Enabled and CONFIG.AI.Url == "" then
		warnLog("AI is enabled, but CONFIG.AI.Url is empty.")
		return false
	end

	if CONFIG.Discord.Enabled and CONFIG.Discord.WebhookUrl == "" then
		warnLog("Discord is enabled, but CONFIG.Discord.WebhookUrl is empty.")
		return false
	end

	return true
end

local function run()
	if not validateConfig() then
		return
	end

	log("Search queries:", table.concat(CONFIG.Search.Queries, ", "))
	log("Search mode:", CONFIG.Search.Mode)
	log("Ignore case:", CONFIG.Search.IgnoreCase)
	log("Ignore whitespace:", CONFIG.Search.IgnoreWhitespace)
	log("AI enabled:", CONFIG.AI.Enabled)
	log("AI summary query:", CONFIG.AI.RunSummaryQuery)
	log("AI deobfuscation query:", CONFIG.AI.RunDeobfuscationQuery)
	log("Discord enabled:", CONFIG.Discord.Enabled)
	log("Export enabled:", CONFIG.Export.Enabled)

	local results = searchScripts()

	printFinalResults(results)
	sendDiscordIndex(results)
	outputExport(results)
	analyzeResults(results)
end

run()
