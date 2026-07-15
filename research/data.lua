local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local localUI = LocalPlayer.PlayerGui:GetChildren()
local NULL_POS = Vector2.new(25597, 14109) -- this is what the game considers off screen
local RunService = game:GetService("RunService")

local function getPlayerMarkerGUI(): Instance
	for _, gui in pairs(localUI) do
		-- check if ui name doesnt starts with {
		if string.sub(gui.Name, 1, 1) ~= "{" then
			continue
		end

		-- search for the marker ui
		local kiddos = gui:GetChildren()
		local MarkerUI;
		for _, child in pairs(kiddos) do
			if child.Name == "Frame" then
				return gui
			end
		end
	end
end

-- Get player markers based on there username
local MarkerUI = getPlayerMarkerGUI()
local Markers = MarkerUI["Frame"]:GetChildren()

-- Get player positions based on there ingame_ids
local characterModels = workspace.characters:GetChildren()

-- Get the player usernames with there ingame_ids
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.module.remotes).default
local MainNamespace = Remotes.Client:GetNamespace("447425.4364725505")
local GetPlayersRemote = MainNamespace:Get("308821.47331327957")
local PlayerObjects = GetPlayersRemote:CallServer() -- {{ player: "name", ingame_id: number }}

for _, playerMarker in pairs(Markers) do
	local markerScreenPos = playerMarker["AbsolutePosition"]
	if markerScreenPos ~= NULL_POS then
		print(markerScreenPos)
	end
end

for _, char in pairs(characterModels) do
	local HRP = char.humanoid_root_part
	print(char.name, HRP.CFrame.Position)
end

for _, playerObject in PlayerObjects do
	print(playerObject.player, playerObject.ingame_id)
end

function main()
	for _, playerMarker in pairs(Markers) do
		local markerScreenPos = playerMarker.Position

	end
end

local HeartbeatConnect
HeartbeatConnect = game:GetService("RunService").Heartbeat:Connect(function(deltaTime)
	local success, result = pcall(main)

	if not success then
		warn("Error caught:", result)
		
		HeartbeatConnect:Disconnect()
		HeartbeatConnect = nil
	end
end)