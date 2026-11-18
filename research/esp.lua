--!strict

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

--// Double-run guard: if an older copy is still running, shut it down first.

local GLOBAL_KEY = "__DeadlineEsp_Cleanup"

local rawEnv: any = getfenv()
local globalEnv: any = if typeof(rawEnv.getgenv) == "function" then rawEnv.getgenv() else _G

do
	local previous = globalEnv[GLOBAL_KEY]

	if typeof(previous) == "function" then
		pcall(previous)
	end

	globalEnv[GLOBAL_KEY] = nil
end

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui", 15) :: PlayerGui?

if not PlayerGui then
	warn("[ESP] PlayerGui not found.")
	return
end

local SETTINGS = {
	-- Character models are inside workspace.characters
	CharactersFolderName = "characters",

	-- Kill key
	KillKey = Enum.KeyCode.PageDown,

	-- Prints how every character is being classified (team debugging)
	DumpKey = Enum.KeyCode.PageUp,

	-- Only add ESP to models named like "12345"
	OnlyNumericNames = true,

	-- Box is sized from the character's real bounding box.
	-- Extra room added around the character, in studs
	BoxPaddingStuds = 0.25,

	-- Box width never exceeds height * this (stops held weapons / arms making it fat)
	MaxWidthToHeightRatio = 0.6,

	-- How often the real bounding box is re-measured (position is still per-frame)
	BoundsRefreshInterval = 0.1,

	-- Which parts count towards the box. Characters in this game contain parts
	-- far outside the body (that is what made the first version's boxes huge),
	-- so only nearby, normal-sized parts are measured.
	PartRefreshInterval = 1, -- how often the part list is rebuilt
	MaxPartDistanceFromRoot = 8, -- studs; parts further from the root are ignored
	MaxPartDimension = 10, -- studs; bigger parts are ignored
	IgnoreTools = true, -- held weapons would stretch the box
	IgnoreInvisibleParts = true, -- Transparency == 1 (hitboxes, the root part)
	MaxCharacterHeightStuds = 12, -- measured height above this is rejected -> fallback size

	-- Only used until the first bounding box has been measured
	FallbackHeightStuds = 6,
	FallbackWidthToHeightRatio = 0.5,

	-- Adjust if box is slightly too high/low
	ScreenYOffset = 0,

	-- Team colors
	TeamColor = Color3.fromRGB(111, 184, 194),
	EnemyColor = Color3.fromRGB(126, 108, 190),
	UnknownColor = Color3.fromRGB(255, 255, 255),

	-- Wall check: colours used when you have line of sight to the player
	-- (EnemyColor / UnknownColor are used when they are behind cover)
	EnemyVisibleColor = Color3.fromRGB(255, 70, 70),
	UnknownVisibleColor = Color3.fromRGB(255, 235, 120),

	WallCheck = true,
	WallCheckInterval = 0.1, -- seconds between line-of-sight checks per player
	WallCheckIgnoreTransparency = 0.9, -- hit parts at least this transparent do not block sight

	BoxThickness = 2,

	ShowName = true,
	ShowDistance = true,
	ShowTeamText = false,
	ShowTeamESP = false,

	MaxDistance = 2000,

	-- Refreshes player/team data from the remote every X seconds
	TeamRefreshInterval = 1,

	-- Player/team data is read from the game's own objects in memory (needs getgc).
	-- Each player has a table { player = <Player>, ingame_id = <number>, ... } and a
	-- state table with ingame_id + replicated_team; teammates share replicated_team.
	UseMemoryScan = true,
	UseTeamValue = true, -- classify with replicated_team; falls back to marker.Visible
	MemoryScanMinInterval = 2, -- seconds between scans (a scan can hitch for a moment)
	MemoryScanMissingRetry = 3, -- seconds before a still-unknown character triggers another scan

	-- The old player-list remote no longer exists (its ids changed). Off by default.
	UseRemote = false,
	RemoteNamespace = "447425.4364725505",
	RemoteName = "308821.47331327957",

	-- Timeouts (seconds)
	WaitTimeout = 15, -- waiting for the characters folder
	RemoteResolveTimeout = 3, -- waiting for the remotes module
	RemoteCallTimeout = 5, -- waiting for the player list reply

	Debug = true,
}

-- Minimum gap between event-triggered (non-interval) team refreshes
local MIN_REFRESH_GAP = 0.25
-- How often a missing HumanoidRootPart is searched for again
local ROOT_SEARCH_INTERVAL = 0.5

type TeamInfo = {
	Username: string,
	Marker: GuiObject?,
	TeamObject: any?, -- game table holding this character's live replicated_team
}

type Entry = {
	Box: Frame,
	Stroke: UIStroke,
	Label: TextLabel,

	Root: BasePart?,
	NextRootSearch: number,

	Parts: { BasePart },
	NextParts: number,

	Size: Vector3?,
	Offset: Vector3?, -- bounding box centre relative to the root part
	WorldCenter: Vector3?,
	NextBounds: number,

	Visible: boolean, -- line of sight from the camera (wall check)
	NextVisibility: number,

	LastText: string,
	LastColor: Color3,
	LastThickness: number,
	Shown: boolean,
}

local charactersFolder: Instance? = nil
local espContainer: Frame? = nil
local entries: { [Model]: Entry } = {}

-- Cached by the background loop, only READ by the render step
local teamData: { [Instance]: TeamInfo } = {}
local playersById: { [number]: string } = {}
local teamObjects: { [number]: any } = {} -- ingame_id -> game table with replicated_team
local localIngameId: number? = nil
local localTeamObject: any = nil
local localTeamValue: any = nil -- our replicated_team; kept while dead so teams keep working
local localTeamSource = ""
local lastTeamMismatch = false
local nextMemoryScan = 0
local missingRetryAt: { [number]: number } = {}

local connections: { RBXScriptConnection } = {}
local killed = false
local refreshRequested = false
local lastSummary = ""

local function log(...)
	if SETTINGS.Debug then
		warn("[ESP]", ...)
	end
end

local function disconnectAll()
	for _, connection in ipairs(connections) do
		if connection.Connected then
			connection:Disconnect()
		end
	end

	table.clear(connections)
end

local function isNumericName(name: string): boolean
	return string.match(name, "^%d+$") ~= nil
end

local function isValidCharacter(object: Instance): boolean
	if not object:IsA("Model") then
		return false
	end

	if SETTINGS.OnlyNumericNames and not isNumericName(object.Name) then
		return false
	end

	return true
end

--// Marker GUI

local function getMarkerFrame(): GuiObject?
	for _, gui in ipairs(PlayerGui:GetChildren()) do
		if not gui:IsA("ScreenGui") then
			continue
		end

		if string.sub(gui.Name, 1, 1) ~= "{" then
			continue
		end

		local frame = gui:FindFirstChild("Frame")

		if frame and frame:IsA("GuiObject") then
			return frame
		end
	end

	return nil
end

local function getMarkersByUsername(markerFrame: GuiObject): { [string]: GuiObject }
	local markersByUsername = {}

	for _, marker in ipairs(markerFrame:GetChildren()) do
		if not marker:IsA("GuiObject") then
			continue
		end

		-- Ignore our own ESP container
		if marker.Name == "ESPContainer" then
			continue
		end

		markersByUsername[marker.Name] = marker
	end

	return markersByUsername
end

--// Remote player data

local getPlayersRemote: any = nil
local nextRemoteAttempt = 0 -- after a failure the remote is only retried every 10s
local lastRemoteError = ""

local function getUsernameFromPlayerObject(playerObject: any): string?
	if not playerObject then
		return nil
	end

	if typeof(playerObject.player) == "Instance" and playerObject.player:IsA("Player") then
		return playerObject.player.Name
	end

	if typeof(playerObject.player) == "string" then
		return playerObject.player
	end

	if typeof(playerObject.player) == "table" and playerObject.player.Name then
		return tostring(playerObject.player.Name)
	end

	return nil
end

-- Runs fn in its own thread and gives up after `timeout` seconds.
local function callWithTimeout(fn: () -> any, timeout: number): (boolean, any)
	local done = false
	local ok = false
	local result: any = nil

	task.spawn(function()
		ok, result = pcall(fn)
		done = true
	end)

	local started = os.clock()

	while not done and os.clock() - started < timeout do
		task.wait(0.05)
	end

	if not done then
		return false, "timed out"
	end

	return ok, result
end

local function resolvePlayersRemote(): any
	if getPlayersRemote then
		return getPlayersRemote
	end

	local moduleFolder = ReplicatedStorage:WaitForChild("module", SETTINGS.RemoteResolveTimeout)
	local remotesModule = moduleFolder and moduleFolder:WaitForChild("remotes", SETTINGS.RemoteResolveTimeout)

	if not remotesModule or not remotesModule:IsA("ModuleScript") then
		error("remotes module not found")
	end

	local Remotes = require(remotesModule).default

	local MainNamespace = Remotes.Client:GetNamespace(SETTINGS.RemoteNamespace)
	getPlayersRemote = MainNamespace:Get(SETTINGS.RemoteName)

	return getPlayersRemote
end

-- Returns nil on failure so the caller can keep its previous cache.
local function getPlayerObjects(): { any }?
	local success, result = callWithTimeout(function()
		return resolvePlayersRemote():CallServer()
	end, SETTINGS.RemoteCallTimeout)

	if not success then
		nextRemoteAttempt = os.clock() + 10

		-- Only log when the error changes, not every retry
		local message = tostring(result)

		if message ~= lastRemoteError then
			lastRemoteError = message
			log("Failed to call player remote (retrying every 10s):", message)
		end

		return nil
	end

	if typeof(result) ~= "table" then
		nextRemoteAttempt = os.clock() + 10
		log("Player remote did not return a table.")
		return nil
	end

	lastRemoteError = ""
	return result
end

local function buildPlayersByIngameId(playerObjects: { any }): { [number]: string }
	local map = {}

	for _, playerObject in ipairs(playerObjects) do
		if typeof(playerObject) ~= "table" then
			continue
		end

		local ingameId = tonumber(playerObject.ingame_id)
		local username = getUsernameFromPlayerObject(playerObject)

		if not ingameId or not username then
			continue
		end

		map[ingameId] = username
	end

	return map
end

--// Memory scan (background thread only)

-- The game keeps stale tables from earlier lives/rounds under the same ingame_id,
-- some with an OLD team value. A state table is alive while its root part is still
-- in the world; if it has no such field we cannot tell, so assume alive.
local function isLiveState(object: any): boolean
	local root = rawget(object, "humanoid_root_part")

	if typeof(root) == "Instance" then
		return root.Parent ~= nil
	end

	return true
end

-- Finds the game's per-player tables. The tables themselves are cached, so
-- replicated_team is read live and follows changes without another scan.
local function scanMemory()
	local getgcFunction: any = rawEnv.getgc

	if typeof(getgcFunction) ~= "function" then
		log("getgc is not available in this executor; memory scan disabled.")
		SETTINGS.UseMemoryScan = false
		return
	end

	local ok, err = pcall(function()
		local names: { [number]: string } = {}
		local objects: { [number]: any } = {}
		local localCandidates: { number } = {}

		for _, object in ipairs(getgcFunction(true)) do
			if typeof(object) ~= "table" then
				continue
			end

			local ingameId = rawget(object, "ingame_id")

			if typeof(ingameId) ~= "number" then
				continue
			end

			local player = rawget(object, "player")

			if typeof(player) == "Instance" and player:IsA("Player") then
				names[ingameId] = player.Name

				if player == LocalPlayer then
					table.insert(localCandidates, ingameId)
				end
			end

			if rawget(object, "replicated_team") ~= nil then
				local existing = objects[ingameId]

				-- Several tables can share an id; keep the one that is still alive.
				if existing == nil or (isLiveState(object) and not isLiveState(existing)) then
					objects[ingameId] = object
				end
			end
		end

		-- Our current life is the candidate id that has a live state table.
		local newLocalId: number? = nil

		for _, id in ipairs(localCandidates) do
			local state = objects[id]

			if state ~= nil and isLiveState(state) then
				newLocalId = id
				break
			end
		end

		playersById = names
		teamObjects = objects
		localIngameId = newLocalId
	end)

	if not ok then
		log("Memory scan failed:", err)
	end
end

local function needsData(id: number): boolean
	local state = teamObjects[id]

	return playersById[id] == nil or state == nil or not isLiveState(state)
end

-- Only scans when a character has no (live) data yet, e.g. a new spawn, at most every few seconds.
local function maybeScanMemory()
	local folder = charactersFolder

	if not folder then
		return
	end

	local now = os.clock()

	if now < nextMemoryScan then
		return
	end

	local needScan = false

	for _, character in ipairs(folder:GetChildren()) do
		if not isValidCharacter(character) then
			continue
		end

		local id = tonumber(character.Name)

		if id and needsData(id) and now >= (missingRetryAt[id] or 0) then
			needScan = true
			break
		end
	end

	if not needScan then
		return
	end

	nextMemoryScan = now + SETTINGS.MemoryScanMinInterval
	scanMemory()

	local after = os.clock()

	for _, character in ipairs(folder:GetChildren()) do
		local id = if isValidCharacter(character) then tonumber(character.Name) else nil

		if id and needsData(id) then
			missingRetryAt[id] = after + SETTINGS.MemoryScanMissingRetry
		end
	end
end

--// Team lookup (background thread only)

local function rebuildTeamData()
	local folder = charactersFolder

	if not folder then
		return
	end

	local markerFrame = getMarkerFrame()
	local markersByUsername: { [string]: GuiObject } = if markerFrame then getMarkersByUsername(markerFrame) else {}
	local newTeamData: { [Instance]: TeamInfo } = {}

	localTeamObject = if localIngameId then teamObjects[localIngameId] else nil

	for _, character in ipairs(folder:GetChildren()) do
		if not isValidCharacter(character) then
			continue
		end

		local playerId = tonumber(character.Name)
		local username = playerId and playersById[playerId]

		-- Fallback when the remote is unavailable: the engine's own character link
		if not username then
			local player = Players:GetPlayerFromCharacter(character :: Model)

			if player then
				username = player.Name
			end
		end

		local marker = if username then markersByUsername[username] else nil

		-- Markers are named by DISPLAY name (e.g. "mario" for "mariocalabazapro")
		if username and not marker then
			local player = Players:FindFirstChild(username)

			if player and player:IsA("Player") then
				marker = markersByUsername[player.DisplayName]
			end
		end

		local teamObject = if playerId then teamObjects[playerId] else nil

		-- A stale table must never decide a team
		if teamObject ~= nil and not isLiveState(teamObject) then
			teamObject = nil
		end

		if username or teamObject then
			newTeamData[character] = {
				Username = username or character.Name,
				Marker = marker,
				TeamObject = teamObject,
			}
		end
	end

	-- Work out which replicated_team value is OURS. Several independent checks run on
	-- every refresh and nothing is trusted blindly, because teams can swap between rounds:
	--   1. our own game table (must be alive)
	--   2. the character the camera is inside (first person)
	--   3. HUD markers: the team whose markers are visible
	-- 1 and 2 are authoritative; 3 is used when neither is available. All three are
	-- compared and disagreements are logged.
	local ownValue: any = nil
	local cameraValue: any = nil
	local markerValue: any = nil

	if localTeamObject ~= nil and isLiveState(localTeamObject) then
		ownValue = rawget(localTeamObject, "replicated_team")
	end

	local camera = Workspace.CurrentCamera

	if camera then
		local cameraPosition = camera.CFrame.Position

		for character, info in pairs(newTeamData) do
			local teamObject = info.TeamObject

			if teamObject == nil then
				continue
			end

			local root = character:FindFirstChild("humanoid_root_part", true)

			if root and root:IsA("BasePart") and (root.Position - cameraPosition).Magnitude < 5 then
				cameraValue = rawget(teamObject, "replicated_team")
				break
			end
		end
	end

	do
		local visibleCount: { [any]: number } = {}
		local groups = 0

		for _, info in pairs(newTeamData) do
			local teamObject = info.TeamObject
			local marker = info.Marker

			if teamObject == nil or not marker or marker.Parent == nil then
				continue
			end

			local value = rawget(teamObject, "replicated_team")

			if value == nil then
				continue
			end

			if visibleCount[value] == nil then
				visibleCount[value] = 0
				groups += 1
			end

			if marker.Visible then
				visibleCount[value] += 1
			end
		end

		-- Confident only if exactly one team has visible markers and two teams are present
		local best: any = nil
		local bestCount = 0
		local secondCount = 0

		for value, count in pairs(visibleCount) do
			if count > bestCount then
				secondCount = bestCount
				best = value
				bestCount = count
			elseif count > secondCount then
				secondCount = count
			end
		end

		if groups >= 2 and best ~= nil and bestCount >= 1 and secondCount == 0 then
			markerValue = best
		end
	end

	local detected: any = nil
	local source = ""

	if ownValue ~= nil then
		detected = ownValue
		source = "own object"
	elseif cameraValue ~= nil then
		detected = cameraValue
		source = "camera"
	elseif markerValue ~= nil then
		detected = markerValue
		source = "marker inference"
	end

	-- With no signal (e.g. dead) the last value is kept.
	if detected ~= nil then
		if detected ~= localTeamValue or source ~= localTeamSource then
			log("Local team is", tostring(detected), "via", source)
		end

		localTeamValue = detected
		localTeamSource = source
	end

	local authoritative: any = if ownValue ~= nil then ownValue else cameraValue
	local mismatch = authoritative ~= nil and markerValue ~= nil and authoritative ~= markerValue

	if mismatch ~= lastTeamMismatch then
		lastTeamMismatch = mismatch

		if mismatch then
			log("Team check mismatch: game data says", tostring(authoritative), "but visible markers say", tostring(markerValue))
		end
	end

	teamData = newTeamData
end

local function refreshTeamData()
	if SETTINGS.UseRemote and os.clock() >= nextRemoteAttempt then
		local playerObjects = getPlayerObjects() -- yields, which is fine on this thread

		if killed then
			return
		end

		if playerObjects then
			playersById = buildPlayersByIngameId(playerObjects)
		end
	end

	if SETTINGS.UseMemoryScan then
		maybeScanMemory()
	end

	rebuildTeamData()

	if SETTINGS.Debug then
		local players, teams = 0, 0

		for _ in pairs(playersById) do
			players += 1
		end

		for _ in pairs(teamData) do
			teams += 1
		end

		local summary = players
			.. " player names known, "
			.. teams
			.. " characters tracked, local team "
			.. (if localTeamValue ~= nil then "found via " .. localTeamSource else "NOT found (using marker visibility)")

		if summary ~= lastSummary then
			lastSummary = summary
			log(summary)
		end
	end
end

local function requestTeamRefresh()
	refreshRequested = true
end

--// Live team state (read every frame, no yielding)

-- true = teammate, false = enemy, nil = unknown
local function getIsTeammate(character: Instance): boolean?
	local info = teamData[character]

	if not info then
		return nil
	end

	-- Preferred: the game's own team value, compared with ours (read live)
	local teamObject = info.TeamObject

	if SETTINGS.UseTeamValue and teamObject ~= nil and localTeamValue ~= nil then
		local theirs = rawget(teamObject, "replicated_team")

		if theirs ~= nil then
			return theirs == localTeamValue
		end
	end

	-- Fallback: the HUD marker is only visible for teammates
	local marker = info.Marker

	if marker and marker.Parent ~= nil then
		return marker.Visible == true
	end

	return nil
end

local function getColorFor(isTeammate: boolean?, visible: boolean): Color3
	if isTeammate == nil then
		return if visible then SETTINGS.UnknownVisibleColor else SETTINGS.UnknownColor
	end

	if isTeammate then
		return SETTINGS.TeamColor
	end

	return if visible then SETTINGS.EnemyVisibleColor else SETTINGS.EnemyColor
end

local function getCharacterLabel(character: Instance, isTeammate: boolean?, distance: number): string
	local info = teamData[character]
	local name = info and info.Username or character.Name
	local textParts = {}

	if SETTINGS.ShowName then
		table.insert(textParts, name)
	end

	if SETTINGS.ShowTeamText and isTeammate ~= nil then
		table.insert(textParts, isTeammate and "TEAM" or "ENEMY")
	end

	if SETTINGS.ShowDistance then
		table.insert(textParts, math.floor(distance) .. " studs")
	end

	return table.concat(textParts, " | ")
end

--// Team debug dump (press SETTINGS.DumpKey)

-- Prints a line to the console and keeps it so the whole dump can be copied.
local dumpBuffer: { string } = {}

local function emit(...)
	local parts = {}

	for _, value in ipairs({ ... }) do
		table.insert(parts, tostring(value))
	end

	local line = table.concat(parts, " ")

	print(line)
	table.insert(dumpBuffer, line)
end

local function copyDumpToClipboard()
	local copy: any = rawEnv.setclipboard or rawEnv.toclipboard

	if typeof(copy) ~= "function" then
		log("No clipboard function available in this executor; dump is in the console only.")
		return
	end

	local ok, err = pcall(copy, table.concat(dumpBuffer, "\n"))

	if ok then
		log("Dump copied to clipboard (" .. #dumpBuffer .. " lines).")
	else
		log("Clipboard copy failed:", err)
	end
end

local function dumpTeamDebug()
	emit("[ESP] ---- team dump ----")

	emit(
		"[ESP] local player:",
		LocalPlayer.Name,
		"| ingame id =",
		tostring(localIngameId),
		"| own table found =",
		tostring(localTeamObject ~= nil),
		"| local team value =",
		tostring(localTeamValue),
		"| source =",
		localTeamSource
	)

	local markerFrame = getMarkerFrame()

	if not markerFrame then
		emit("[ESP] no marker frame found")
		return
	end

	emit("[ESP] children of the marker frame:")

	for _, marker in ipairs(markerFrame:GetChildren()) do
		local visible = if marker:IsA("GuiObject") then tostring(marker.Visible) else "n/a"
		emit("[ESP]   marker", marker.Name, "|", marker.ClassName, "| Visible =", visible)
	end

	emit("[ESP] characters:")

	local folder = charactersFolder

	if not folder then
		return
	end

	for _, character in ipairs(folder:GetChildren()) do
		if not isValidCharacter(character) then
			continue
		end

		local playerId = tonumber(character.Name)
		local username = playerId and playersById[playerId]
		local info = teamData[character]
		local theirs = if info and info.TeamObject ~= nil then rawget(info.TeamObject, "replicated_team") else nil

		emit(
			"[ESP]   character",
			character.Name,
			"| username =",
			username or "?",
			"| replicated_team =",
			tostring(theirs),
			"| marker.Visible =",
			if info and info.Marker then tostring(info.Marker.Visible) else "n/a",
			"| classified =",
			tostring(getIsTeammate(character))
		)
	end
end

-- Read-only structure dump, used to find the player-list remote after a game update.
local function dumpValue(name: string, value: any, depth: number, visited: { [any]: boolean }, budget: { number })
	if budget[1] <= 0 then
		return
	end

	budget[1] -= 1

	local indent = string.rep("  ", depth)
	local valueType = typeof(value)

	if valueType == "table" then
		if visited[value] then
			emit("[ESP]" .. indent .. name .. " = <table already shown>")
			return
		end

		visited[value] = true
		emit("[ESP]" .. indent .. name .. " = table")

		if depth >= 5 then
			return
		end

		local count = 0

		for key, child in pairs(value) do
			count += 1

			if count > 40 then
				emit("[ESP]" .. indent .. "  ...")
				break
			end

			dumpValue(tostring(key), child, depth + 1, visited, budget)
		end
	elseif valueType == "Instance" then
		emit("[ESP]" .. indent .. name .. " = Instance " .. (value :: Instance):GetFullName())
	elseif valueType == "function" then
		emit("[ESP]" .. indent .. name .. " = function")
	else
		emit("[ESP]" .. indent .. name .. " = " .. valueType .. " " .. tostring(value))
	end
end

local function dumpDiscovery()
	emit("[ESP] ---- discovery dump ----")

	emit("[ESP] players and their engine Character:")

	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		emit("[ESP]   player", player.Name, "| Character =", if character then character:GetFullName() else "nil")
	end

	local shown = 0

	if charactersFolder then
		for _, character in ipairs(charactersFolder:GetChildren()) do
			if shown >= 2 or not isValidCharacter(character) then
				continue
			end

			shown += 1
			emit("[ESP] character", character.Name, "children:")

			for _, child in ipairs(character:GetChildren()) do
				emit("[ESP]   ", child.Name, "|", child.ClassName)
			end

			for attributeName, attributeValue in pairs(character:GetAttributes()) do
				emit("[ESP]   attribute", attributeName, "=", tostring(attributeValue))
			end
		end
	end

	emit("[ESP] remotes module structure:")

	local ok, err = pcall(function()
		local moduleFolder = ReplicatedStorage:FindFirstChild("module")
		local remotesModule = moduleFolder and moduleFolder:FindFirstChild("remotes")

		if not remotesModule or not remotesModule:IsA("ModuleScript") then
			emit("[ESP]   remotes module not found")
			return
		end

		dumpValue("Remotes", require(remotesModule), 0, {}, { 400 })
	end)

	if not ok then
		emit("[ESP]   dump failed:", err)
	end

	emit("[ESP] ---- end of dump ----")
end

local function shallow(value: any): string
	local valueType = typeof(value)

	if valueType == "table" then
		local parts = {}
		local count = 0

		for key, child in pairs(value) do
			count += 1

			if count > 12 then
				table.insert(parts, "...")
				break
			end

			local childText = if typeof(child) == "Instance"
				then child:GetFullName()
				elseif typeof(child) == "table" then "table"
				else tostring(child)

			table.insert(parts, tostring(key) .. "=" .. childText)
		end

		return "{" .. table.concat(parts, ", ") .. "}"
	elseif valueType == "Instance" then
		return (value :: Instance):GetFullName()
	end

	return tostring(value)
end

-- Second read-only dump: where could the character id -> username link live?
local function dumpExtra()
	emit("[ESP] ---- extra dump ----")

	emit("[ESP] players:")

	for _, player in ipairs(Players:GetPlayers()) do
		local attributes = {}

		for attributeName, attributeValue in pairs(player:GetAttributes()) do
			table.insert(attributes, attributeName .. "=" .. tostring(attributeValue))
		end

		local children = {}

		for _, child in ipairs(player:GetChildren()) do
			table.insert(children, child.Name .. "(" .. child.ClassName .. ")")
		end

		emit(
			"[ESP]   ",
			player.Name,
			"| UserId =",
			player.UserId,
			"| attributes:",
			table.concat(attributes, ","),
			"| children:",
			table.concat(children, ",")
		)
	end

	emit("[ESP] first 3 markers (descendants):")

	local markerFrame = getMarkerFrame()

	if markerFrame then
		local shownMarkers = 0

		for _, marker in ipairs(markerFrame:GetChildren()) do
			if marker.Name == "ESPContainer" or shownMarkers >= 3 then
				continue
			end

			shownMarkers += 1

			local markerInfo = marker.Name
			local markerAttributes = {}

			for attributeName, attributeValue in pairs(marker:GetAttributes()) do
				table.insert(markerAttributes, attributeName .. "=" .. tostring(attributeValue))
			end

			if marker:IsA("GuiObject") then
				markerInfo ..= " | AbsolutePosition=" .. tostring(marker.AbsolutePosition) .. " | Visible=" .. tostring(marker.Visible)
			end

			emit("[ESP]  marker", markerInfo, "| attributes:", table.concat(markerAttributes, ","))

			for _, descendant in ipairs(marker:GetDescendants()) do
				local extra = ""

				if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
					extra ..= " Text=" .. descendant.Text
				end

				if descendant:IsA("GuiObject") then
					extra ..= " BG=" .. tostring(descendant.BackgroundColor3) .. " Visible=" .. tostring(descendant.Visible)
				end

				if descendant:IsA("ImageLabel") then
					extra ..= " Image=" .. descendant.Image
				end

				emit("[ESP]     ", descendant.Name, "|", descendant.ClassName, extra)
			end
		end
	end

	emit("[ESP] remote instances under ReplicatedStorage:")

	local remoteCount = 0

	for _, descendant in ipairs(ReplicatedStorage:GetDescendants()) do
		if descendant:IsA("RemoteFunction") or descendant:IsA("BaseRemoteEvent") then
			remoteCount += 1

			if remoteCount <= 80 then
				emit("[ESP]   ", descendant.ClassName, descendant:GetFullName())
			end
		end
	end

	emit("[ESP]   total remotes:", remoteCount)

	emit("[ESP] remotes Client metatable:")

	pcall(function()
		local remotesModule = ReplicatedStorage:FindFirstChild("module")
		remotesModule = remotesModule and remotesModule:FindFirstChild("remotes")

		if remotesModule and remotesModule:IsA("ModuleScript") then
			local client = require(remotesModule).default.Client
			local metatable = getmetatable(client)

			if typeof(metatable) == "table" then
				dumpValue("metatable", metatable, 0, {}, { 80 })
			else
				emit("[ESP]   no readable metatable:", tostring(metatable))
			end
		end
	end)

	-- Look for a table in memory that maps a character's id to its player.
	local getgcFunction: any = rawEnv.getgc

	if typeof(getgcFunction) ~= "function" then
		emit("[ESP] getgc not available, skipping memory search")
	elseif charactersFolder then
		local targetId: number? = nil

		for _, character in ipairs(charactersFolder:GetChildren()) do
			if isValidCharacter(character) then
				targetId = tonumber(character.Name)
				break
			end
		end

		if targetId then
			emit("[ESP] memory search for character id", targetId)

			local ok, err = pcall(function()
				local hits = 0

				for _, object in ipairs(getgcFunction(true)) do
					if typeof(object) ~= "table" then
						continue
					end

					local keyedValue = rawget(object, targetId)

					if keyedValue == nil then
						keyedValue = rawget(object, tostring(targetId))
					end

					if keyedValue ~= nil then
						hits += 1
						emit("[ESP]   table keyed by id ->", shallow(keyedValue), "| table sample:", shallow(object))
					elseif rawget(object, "ingame_id") == targetId then
						hits += 1
						emit("[ESP]   table with ingame_id ->", shallow(object))
					end

					if hits >= 8 then
						break
					end
				end

				emit("[ESP]   hits:", hits)
			end)

			if not ok then
				emit("[ESP]   memory search failed:", err)
			end
		end
	end

	-- Where does the game keep OUR team? Look for tables that mention the local
	-- player, or one of the team values, other than the per-character state tables.
	if typeof(getgcFunction) == "function" then
		emit("[ESP] tables that reference the local player or a team value:")

		local teamSet: { [any]: boolean } = {}

		for _, object in pairs(teamObjects) do
			local value = rawget(object, "replicated_team")

			if value ~= nil then
				teamSet[value] = true
			end
		end

		local ok, err = pcall(function()
			local localHits = 0
			local teamHits = 0

			for _, object in ipairs(getgcFunction(true)) do
				if typeof(object) ~= "table" or rawget(object, "replicated_team") ~= nil then
					continue
				end

				local refersToLocal = false
				local refersToTeam = false
				local scanned = 0

				for key, value in next, object do
					scanned += 1

					if scanned > 60 then
						break
					end

					if value == LocalPlayer then
						refersToLocal = true
					end

					if teamSet[value] or teamSet[key] then
						refersToTeam = true
					end
				end

				if refersToLocal and localHits < 10 then
					localHits += 1
					emit("[ESP]   references the local player ->", shallow(object))
				end

				if refersToTeam and teamHits < 15 then
					teamHits += 1
					emit("[ESP]   references a team value ->", shallow(object))
				end
			end

			emit("[ESP]   local hits:", localHits, "| team hits:", teamHits)
		end)

		if not ok then
			emit("[ESP]   search failed:", err)
		end
	end

	emit("[ESP] ---- end of extra dump ----")
end

--// ESP UI

local function createContainer(parent: GuiObject): Frame
	local container = Instance.new("Frame")
	container.Name = "ESPContainer"
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.ClipsDescendants = false
	container.Size = UDim2.fromScale(1, 1)
	container.Position = UDim2.fromScale(0, 0)
	container.ZIndex = 999
	container.Parent = parent

	return container
end

local function createEspBox(character: Model)
	if entries[character] then
		return
	end

	-- No container yet; scanCharacters() runs again once one is attached.
	if not espContainer then
		return
	end

	local box = Instance.new("Frame")
	box.Name = character.Name .. "_ESP"
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Visible = false
	box.ZIndex = 1000
	box.Parent = espContainer

	local stroke = Instance.new("UIStroke")
	stroke.Name = "Stroke"
	stroke.Color = SETTINGS.UnknownColor
	stroke.Thickness = SETTINGS.BoxThickness
	stroke.Parent = box

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(0, -22)
	label.Size = UDim2.fromOffset(280, 20)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextColor3 = SETTINGS.UnknownColor
	label.TextStrokeTransparency = 0.4
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.ZIndex = 1001
	label.Parent = box

	entries[character] = {
		Box = box,
		Stroke = stroke,
		Label = label,

		Root = nil,
		NextRootSearch = 0,

		Parts = {},
		NextParts = 0,

		Size = nil,
		Offset = nil,
		WorldCenter = nil,
		NextBounds = 0,

		Visible = false,
		NextVisibility = 0,

		LastText = "",
		LastColor = SETTINGS.UnknownColor,
		LastThickness = SETTINGS.BoxThickness,
		Shown = false,
	}

	log("Added ESP to", character.Name)
end

local function removeEspBox(character: Instance)
	local entry = entries[character :: Model]

	if not entry then
		return
	end

	entry.Box:Destroy()
	entries[character :: Model] = nil
	teamData[character] = nil
end

local function scanCharacters()
	local folder = charactersFolder

	if not folder then
		return
	end

	for _, child in ipairs(folder:GetChildren()) do
		if isValidCharacter(child) then
			createEspBox(child :: Model)
		end
	end
end

-- Destroys every box and the container (used on kill and when the HUD is lost).
local function dropContainer()
	for character in pairs(entries) do
		removeEspBox(character)
	end

	if espContainer then
		espContainer:Destroy()
		espContainer = nil
	end
end

-- Creates the container if it is missing, or re-creates it if the HUD it lived in was destroyed.
local function ensureContainer()
	local container = espContainer

	if container and container.Parent ~= nil and container:IsDescendantOf(PlayerGui) then
		return
	end

	local markerFrame = getMarkerFrame()

	if container then
		log("ESP container lost, re-attaching.")
		dropContainer()
	end

	if not markerFrame then
		return
	end

	espContainer = createContainer(markerFrame)
	scanCharacters()
	requestTeamRefresh()
	log("ESP container attached.")
end

--// Character bounds / screen projection

local function getRootPart(character: Model, entry: Entry, now: number): BasePart?
	local root = entry.Root

	if root and root.Parent ~= nil then
		return root
	end

	entry.Root = nil

	if now < entry.NextRootSearch then
		return nil
	end

	entry.NextRootSearch = now + ROOT_SEARCH_INTERVAL

	-- This game names it humanoid_root_part; keep the standard name as a fallback.
	local found = character:FindFirstChild("humanoid_root_part", true)
		or character:FindFirstChild("HumanoidRootPart", true)

	if found and found:IsA("BasePart") then
		entry.Root = found
		return found
	end

	return nil
end

-- Rebuilds the list of parts that count towards the box (slow cadence).
local function refreshParts(character: Model, entry: Entry, root: BasePart?, now: number)
	entry.NextParts = now + SETTINGS.PartRefreshInterval

	local referencePosition = if root then root.Position else character:GetPivot().Position
	local parts: { BasePart } = {}

	for _, descendant in ipairs(character:GetDescendants()) do
		if not descendant:IsA("BasePart") then
			continue
		end

		local partSize = descendant.Size

		if math.max(partSize.X, partSize.Y, partSize.Z) > SETTINGS.MaxPartDimension then
			continue
		end

		if (descendant.Position - referencePosition).Magnitude > SETTINGS.MaxPartDistanceFromRoot then
			continue
		end

		if SETTINGS.IgnoreInvisibleParts and descendant.Transparency >= 1 then
			continue
		end

		if SETTINGS.IgnoreTools and descendant:FindFirstAncestorOfClass("Tool") then
			continue
		end

		table.insert(parts, descendant)
	end

	entry.Parts = parts
end

-- World-aligned bounds of the cached parts (stable while the character turns).
local function updateBounds(character: Model, entry: Entry, root: BasePart?, now: number)
	entry.NextBounds = now + SETTINGS.BoundsRefreshInterval

	if now >= entry.NextParts then
		refreshParts(character, entry, root, now)
	end

	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	local count = 0

	for _, part in ipairs(entry.Parts) do
		if part.Parent == nil then
			continue
		end

		local cframe = part.CFrame
		local half = part.Size / 2
		local right, up, look = cframe.RightVector, cframe.UpVector, cframe.LookVector
		local position = cframe.Position

		local extentX = math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(look.X) * half.Z
		local extentY = math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(look.Y) * half.Z
		local extentZ = math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(look.Z) * half.Z

		minX = math.min(minX, position.X - extentX)
		minY = math.min(minY, position.Y - extentY)
		minZ = math.min(minZ, position.Z - extentZ)
		maxX = math.max(maxX, position.X + extentX)
		maxY = math.max(maxY, position.Y + extentY)
		maxZ = math.max(maxZ, position.Z + extentZ)
		count += 1
	end

	local size = Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)

	-- Nothing usable, or still absurd: fall back to the fixed size.
	if count == 0 or size.Y <= 0 or size.Y > SETTINGS.MaxCharacterHeightStuds then
		entry.Size = nil
		entry.Offset = nil
		entry.WorldCenter = nil
		return
	end

	local center = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)

	entry.Size = size
	entry.WorldCenter = center
	entry.Offset = if root then center - root.Position else nil
end

local function getCenter(character: Model, entry: Entry, root: BasePart?): Vector3
	if root then
		local offset = entry.Offset
		return if offset then root.Position + offset else root.Position
	end

	return entry.WorldCenter or character:GetPivot().Position
end

-- Returns ok, x, y, width, height (screen space)
local function projectBox(
	center: Vector3,
	size: Vector3,
	camera: Camera
): (boolean, number, number, number, number)
	local pad = SETTINGS.BoxPaddingStuds
	local halfHeight = size.Y / 2 + pad
	local halfWidth = math.min(math.max(size.X, size.Z), size.Y * SETTINGS.MaxWidthToHeightRatio) / 2 + pad

	local up = Vector3.new(0, halfHeight, 0)
	local side = camera.CFrame.RightVector * halfWidth

	local centerScreen = camera:WorldToScreenPoint(center)
	local topScreen = camera:WorldToScreenPoint(center + up)
	local bottomScreen = camera:WorldToScreenPoint(center - up)
	local sideScreen = camera:WorldToScreenPoint(center + side)

	-- If ANY point is behind the camera the projection is mirrored garbage.
	if centerScreen.Z <= 0 or topScreen.Z <= 0 or bottomScreen.Z <= 0 or sideScreen.Z <= 0 then
		return false, 0, 0, 0, 0
	end

	local height = math.abs(bottomScreen.Y - topScreen.Y)

	if height <= 2 then
		return false, 0, 0, 0, 0
	end

	local halfWidthPixels = (Vector2.new(sideScreen.X, sideScreen.Y) - Vector2.new(centerScreen.X, centerScreen.Y)).Magnitude
	local width = halfWidthPixels * 2

	local x = centerScreen.X - halfWidthPixels
	local y = math.min(topScreen.Y, bottomScreen.Y) + SETTINGS.ScreenYOffset

	-- Entirely off screen
	local viewport = camera.ViewportSize

	if x > viewport.X or x + width < 0 or y > viewport.Y or y + height < 0 then
		return false, 0, 0, 0, 0
	end

	return true, x, y, width, height
end

--// Wall check (line of sight from the camera)

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local rayFilterCharacter: Instance? = nil
local rayFilterCamera: Instance? = nil

-- Characters are excluded so other players don't count as cover; the ray
-- stops at the target point so anything behind the target is never hit.
local function updateRayFilter(camera: Camera)
	local localCharacter = LocalPlayer.Character

	if localCharacter == rayFilterCharacter and camera == rayFilterCamera then
		return
	end

	rayFilterCharacter = localCharacter
	rayFilterCamera = camera

	local filter: { Instance } = { camera }

	if localCharacter then
		table.insert(filter, localCharacter)
	end

	if charactersFolder then
		table.insert(filter, charactersFolder)
	end

	rayParams.FilterDescendantsInstances = filter
end

local function hasLineOfSight(origin: Vector3, point: Vector3): boolean
	local currentOrigin = origin

	-- Re-cast through (near) invisible parts a few times, e.g. invisible walls / trigger parts.
	for _ = 1, 3 do
		local direction = point - currentOrigin

		if direction.Magnitude < 0.1 then
			return true
		end

		local result = Workspace:Raycast(currentOrigin, direction, rayParams)

		if not result then
			return true
		end

		if result.Instance.Transparency < SETTINGS.WallCheckIgnoreTransparency then
			return false
		end

		currentOrigin = result.Position + direction.Unit * 0.05
	end

	return false
end

-- True if ANY of several points on the character is visible.
local function computeVisibility(center: Vector3, size: Vector3, camera: Camera): boolean
	local origin = camera.CFrame.Position
	local vertical = Vector3.new(0, size.Y * 0.4, 0)
	local horizontal = camera.CFrame.RightVector * (math.min(math.max(size.X, size.Z), size.Y * SETTINGS.MaxWidthToHeightRatio) * 0.4)

	return hasLineOfSight(origin, center)
		or hasLineOfSight(origin, center + vertical)
		or hasLineOfSight(origin, center - vertical)
		or hasLineOfSight(origin, center + horizontal)
		or hasLineOfSight(origin, center - horizontal)
end

--// ESP update (render step: reads cached data only, never yields)

local function hideEntry(entry: Entry)
	if entry.Shown then
		entry.Shown = false
		entry.Box.Visible = false
	end
end

local function updateCharacterEsp(
	character: Model,
	entry: Entry,
	camera: Camera,
	containerPosition: Vector2,
	now: number
)
	if not character.Parent then
		removeEspBox(character)
		return
	end

	local isTeammate = getIsTeammate(character)

	if isTeammate == true and not SETTINGS.ShowTeamESP then
		hideEntry(entry)
		return
	end

	local root = getRootPart(character, entry, now)

	if now >= entry.NextBounds then
		updateBounds(character, entry, root, now)
	end

	local center = getCenter(character, entry, root)
	local distance = (camera.CFrame.Position - center).Magnitude

	if distance > SETTINGS.MaxDistance then
		hideEntry(entry)
		return
	end

	local size = entry.Size

	if not size then
		local height = SETTINGS.FallbackHeightStuds
		local width = height * SETTINGS.FallbackWidthToHeightRatio
		size = Vector3.new(width, height, width)
	end

	local ok, x, y, width, height = projectBox(center, size :: Vector3, camera)

	if not ok then
		hideEntry(entry)
		return
	end

	local visible = false

	if SETTINGS.WallCheck and isTeammate ~= true then
		if now >= entry.NextVisibility then
			entry.NextVisibility = now + SETTINGS.WallCheckInterval
			entry.Visible = computeVisibility(center, size :: Vector3, camera)
		end

		visible = entry.Visible
	end

	local box = entry.Box

	box.Position = UDim2.fromOffset(x - containerPosition.X, y - containerPosition.Y)
	box.Size = UDim2.fromOffset(width, height)

	if not entry.Shown then
		entry.Shown = true
		box.Visible = true
	end

	local color = getColorFor(isTeammate, visible)

	if entry.LastColor ~= color then
		entry.LastColor = color
		entry.Stroke.Color = color
		entry.Label.TextColor3 = color
	end

	if entry.LastThickness ~= SETTINGS.BoxThickness then
		entry.LastThickness = SETTINGS.BoxThickness
		entry.Stroke.Thickness = SETTINGS.BoxThickness
	end

	local text = getCharacterLabel(character, isTeammate, distance)

	if entry.LastText ~= text then
		entry.LastText = text
		entry.Label.Text = text
	end
end

local function updateAllEsp()
	if killed then
		return
	end

	local camera = Workspace.CurrentCamera
	local container = espContainer

	if not camera or not container then
		return
	end

	updateRayFilter(camera)

	local containerPosition = container.AbsolutePosition
	local now = os.clock()

	for character, entry in pairs(entries) do
		updateCharacterEsp(character, entry, camera, containerPosition, now)
	end
end

--// Background loop: container watchdog + remote/team refresh

local function backgroundLoop()
	local lastRefresh = 0

	while not killed do
		ensureContainer()

		local now = os.clock()
		local sinceRefresh = now - lastRefresh
		local due = sinceRefresh >= SETTINGS.TeamRefreshInterval
		local requested = refreshRequested and sinceRefresh >= MIN_REFRESH_GAP

		if due or requested then
			refreshRequested = false
			refreshTeamData()
			lastRefresh = os.clock()
		end

		task.wait(0.1)
	end
end

--// Cleanup

local function killScript()
	if killed then
		return
	end

	killed = true
	disconnectAll()
	dropContainer()

	table.clear(teamData)
	table.clear(playersById)

	if globalEnv[GLOBAL_KEY] == killScript then
		globalEnv[GLOBAL_KEY] = nil
	end

	log("Killed.")
end

--// Start

local function start()
	local folder = Workspace:WaitForChild(SETTINGS.CharactersFolderName, SETTINGS.WaitTimeout)

	if not folder then
		error("workspace." .. SETTINGS.CharactersFolderName .. " not found")
	end

	charactersFolder = folder

	-- Attaches now if the HUD exists, otherwise the background loop keeps trying.
	ensureContainer()

	table.insert(connections, folder.ChildAdded:Connect(function(child)
		task.wait(0.1)

		if killed or not isValidCharacter(child) then
			return
		end

		createEspBox(child :: Model)
		requestTeamRefresh()
	end))

	table.insert(connections, folder.ChildRemoved:Connect(function(child)
		removeEspBox(child)
	end))

	table.insert(connections, RunService.RenderStepped:Connect(updateAllEsp))

	table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end

		if input.KeyCode == SETTINGS.KillKey then
			killScript()
		elseif input.KeyCode == SETTINGS.DumpKey then
			table.clear(dumpBuffer)
			dumpTeamDebug()
			dumpDiscovery()
			dumpExtra()
			copyDumpToClipboard()
		end
	end))

	task.spawn(backgroundLoop)

	log("Started. Press " .. SETTINGS.KillKey.Name .. " to kill.")
end

globalEnv[GLOBAL_KEY] = killScript

local success, err = pcall(start)

if not success then
	log("Start failed:", err)
	killScript()
end
