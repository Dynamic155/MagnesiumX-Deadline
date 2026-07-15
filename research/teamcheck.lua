local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local function getPlayerMarkerGui(): ScreenGui?
	for _, gui in ipairs(PlayerGui:GetChildren()) do
		if not gui:IsA("ScreenGui") then
			continue
		end

		if string.sub(gui.Name, 1, 1) ~= "{" then
			continue
		end

		local frame = gui:FindFirstChild("Frame")

		if not frame then
			continue
		end

		return gui
	end

	return nil
end

local function getMarkersByUsername(markerFrame: Instance): { [string]: Instance }
	local markersByUsername = {}

	for _, marker in ipairs(markerFrame:GetChildren()) do
		markersByUsername[marker.Name] = marker
	end

	return markersByUsername
end

local function getUsernameFromPlayerObject(playerObject): string?
	if not playerObject then
		return nil
	end

	-- Handles:
	-- playerObject.player = Player instance
	if typeof(playerObject.player) == "Instance" and playerObject.player:IsA("Player") then
		return playerObject.player.Name
	end

	-- Handles:
	-- playerObject.player = "Username"
	if typeof(playerObject.player) == "string" then
		return playerObject.player
	end

	return nil
end

local function getPlayerObjectsByIngameId(playerObjects): { [number]: string }
	local playersById = {}

	for _, playerObject in ipairs(playerObjects) do
		local ingameId = tonumber(playerObject.ingame_id)
		local username = getUsernameFromPlayerObject(playerObject)

		if not ingameId then
			continue
		end

		if not username then
			continue
		end

		playersById[ingameId] = username
	end

	return playersById
end

local function getPlayerObjects()
	local remotesModule = ReplicatedStorage:WaitForChild("module"):WaitForChild("remotes")
	local Remotes = require(remotesModule).default

	local MainNamespace = Remotes.Client:GetNamespace("447425.4364725505")
	local GetPlayersRemote = MainNamespace:Get("308821.47331327957")

	local success, result = pcall(function()
		return GetPlayersRemote:CallServer()
	end)

	if not success then
		warn("[PlayerMarker] Failed to get player objects:", result)
		return {}
	end

	if typeof(result) ~= "table" then
		warn("[PlayerMarker] PlayerObjects was not a table.")
		return {}
	end

	return result
end

local function handleCharacter(characterModel: Instance, playersById: { [number]: string }, markersByUsername: { [string]: Instance })
	local playerId = tonumber(characterModel.Name)

	if not playerId then
		return
	end

	local username = playersById[playerId]

	if not username then
		warn("[PlayerMarker] No username found for character ID:", playerId)
		return
	end

	local marker = markersByUsername[username]

	if not marker then
		warn("[PlayerMarker] No marker found for username:", username)
		return
	end

	if marker.Visible then
		print(username, "is on our team")
		-- ON OUR TEAM
		return
	end

	print(username, "is on enemy team")
	-- ENEMY TEAM
end

local function main()
	local markerGui = getPlayerMarkerGui()

	if not markerGui then
		warn("[PlayerMarker] Could not find marker GUI.")
		return
	end

	local markerFrame = markerGui:FindFirstChild("Frame")

	if not markerFrame then
		warn("[PlayerMarker] Marker GUI has no Frame.")
		return
	end

	local charactersFolder = Workspace:FindFirstChild("characters")

	if not charactersFolder then
		warn("[PlayerMarker] Could not find workspace.characters.")
		return
	end

	local markersByUsername = getMarkersByUsername(markerFrame)
	local playerObjects = getPlayerObjects()
	local playersById = getPlayerObjectsByIngameId(playerObjects)

	for _, characterModel in ipairs(charactersFolder:GetChildren()) do
		handleCharacter(characterModel, playersById, markersByUsername)
	end
end

main()
