--!strict

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local SETTINGS = {
	-- Character models are inside workspace.characters
	CharactersFolder = Workspace:WaitForChild("characters"),

	-- Kill key
	KillKey = Enum.KeyCode.PageDown,
 
	-- Only add ESP to models named like "12345"
	OnlyNumericNames = true,

	-- Fixed ESP size settings
	CharacterBoxHeightStuds = 6,
	WidthToHeightRatio = 0.5,
	BottomOffsetStuds = -3,

	-- Adjust if box is slightly too high/low
	ScreenYOffset = 0,

	-- Team colors
	TeamColor = Color3.fromRGB(111, 184, 194),
	EnemyColor = Color3.fromRGB(126, 108, 190),
	UnknownColor = Color3.fromRGB(255, 255, 255),

	BoxThickness = 2,

	ShowName = true,
	ShowDistance = true,
	ShowTeamText = false,
	ShowTeamESP = false,

	MaxDistance = 2000,

	-- Refreshes team data from the remote every X seconds
	TeamRefreshInterval = 1,

	Debug = true,
}

type TeamInfo = {
	Username: string,
	IsTeammate: boolean,
	Color: Color3,
	Marker: GuiObject?,
}

local espContainer: Frame? = nil
local espFrames: { [Instance]: Frame } = {}
local teamData: { [Instance]: TeamInfo } = {}

local connections: { RBXScriptConnection } = {}
local killed = false
local lastTeamRefresh = 0

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

local function getMarkerGui(): ScreenGui?
	for _, gui in ipairs(PlayerGui:GetChildren()) do
		if not gui:IsA("ScreenGui") then
			continue
		end

		if string.sub(gui.Name, 1, 1) ~= "{" then
			continue
		end

		if not gui:FindFirstChild("Frame") then
			continue
		end

		return gui
	end

	return nil
end

local function getMarkerFrame(): GuiObject?
	local markerGui = getMarkerGui()

	if not markerGui then
		return nil
	end

	local frame = markerGui:FindFirstChild("Frame")

	if not frame or not frame:IsA("GuiObject") then
		return nil
	end

	return frame
end

local function waitForMarkerFrame(timeout: number): GuiObject?
	local started = os.clock()

	while os.clock() - started < timeout do
		if killed then
			return nil
		end

		local frame = getMarkerFrame()

		if frame then
			return frame
		end

		task.wait(0.25)
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

local function getPlayerObjects(): { any }
	local success, result = pcall(function()
		local remotesModule = ReplicatedStorage:WaitForChild("module"):WaitForChild("remotes")
		local Remotes = require(remotesModule).default

		local MainNamespace = Remotes.Client:GetNamespace("447425.4364725505")
		local GetPlayersRemote = MainNamespace:Get("308821.47331327957")

		return GetPlayersRemote:CallServer()
	end)

	if not success then
		log("Failed to call player remote:", result)
		return {}
	end

	if typeof(result) ~= "table" then
		log("Player remote did not return a table.")
		return {}
	end

	return result
end

local function getPlayersByIngameId(): { [number]: string }
	local playersById = {}
	local playerObjects = getPlayerObjects()

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

--// Team lookup

local function refreshTeamData()
	local markerFrame = getMarkerFrame()

	if not markerFrame then
		log("Could not find marker frame for team data.")
		return
	end

	local markersByUsername = getMarkersByUsername(markerFrame)
	local playersById = getPlayersByIngameId()
	local newTeamData = {}

	for _, character in ipairs(SETTINGS.CharactersFolder:GetChildren()) do
		if not isValidCharacter(character) then
			continue
		end

		local playerId = tonumber(character.Name)

		if not playerId then
			continue
		end

		local username = playersById[playerId]

		if not username then
			continue
		end

		local marker = markersByUsername[username]

		if not marker then
			continue
		end

		local isTeammate = marker.Visible == true
		local color = isTeammate and SETTINGS.TeamColor or SETTINGS.EnemyColor

		newTeamData[character] = {
			Username = username,
			IsTeammate = isTeammate,
			Color = color,
			Marker = marker,
		}
	end

	teamData = newTeamData
end

local function getCharacterColor(character: Instance): Color3
	local info = teamData[character]

	if not info then
		return SETTINGS.UnknownColor
	end

	return info.Color
end

local function getCharacterLabel(character: Instance, distance: number): string
	local info = teamData[character]
	local name = info and info.Username or character.Name
	local textParts = {}

	if SETTINGS.ShowName then
		table.insert(textParts, name)
	end

	if SETTINGS.ShowTeamText and info then
		table.insert(textParts, info.IsTeammate and "TEAM" or "ENEMY")
	end

	if SETTINGS.ShowDistance then
		table.insert(textParts, math.floor(distance) .. " studs")
	end

	return table.concat(textParts, " | ")
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
	if espFrames[character] then
		return
	end

	if not espContainer then
		log("Cannot create ESP box because container does not exist.")
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
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.4
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.ZIndex = 1001
	label.Parent = box

	espFrames[character] = box
	log("Added ESP to", character.Name)
end

local function removeEspBox(character: Instance)
	local box = espFrames[character]

	if not box then
		return
	end

	box:Destroy()
	espFrames[character] = nil
	teamData[character] = nil
end

local function scanCharacters()
	for _, child in ipairs(SETTINGS.CharactersFolder:GetChildren()) do
		if not isValidCharacter(child) then
			continue
		end

		createEspBox(child)
	end
end

--// Character position / screen projection

local function getCharacterPosition(character: Model): Vector3?
	local rootPart = character:FindFirstChild("HumanoidRootPart", true)

	if rootPart and rootPart:IsA("BasePart") then
		return rootPart.Position
	end

	local success, pivot = pcall(function()
		return character:GetPivot()
	end)

	if success then
		return pivot.Position
	end

	return nil
end

local function getFixedScreenBox(characterPosition: Vector3, camera: Camera)
	local bottomWorld = characterPosition + Vector3.new(0, SETTINGS.BottomOffsetStuds, 0)
	local topWorld = bottomWorld + Vector3.new(0, SETTINGS.CharacterBoxHeightStuds, 0)

	local bottomScreen, bottomVisible = camera:WorldToScreenPoint(bottomWorld)
	local topScreen, topVisible = camera:WorldToScreenPoint(topWorld)

	if bottomScreen.Z <= 0 and topScreen.Z <= 0 then
		return nil
	end

	if not bottomVisible and not topVisible then
		return nil
	end

	local height = math.abs(bottomScreen.Y - topScreen.Y)

	if height <= 2 then
		return nil
	end

	local width = height * SETTINGS.WidthToHeightRatio
	local centerX = (bottomScreen.X + topScreen.X) / 2
	local topY = math.min(bottomScreen.Y, topScreen.Y)

	local x = centerX - width / 2
	local y = topY + SETTINGS.ScreenYOffset

	return x, y, width, height
end

--// ESP update

local function updateCharacterEsp(character: Model, box: Frame)
	if killed then
		return
	end

	if not character.Parent then
		removeEspBox(character)
		return
	end

	local camera = Workspace.CurrentCamera

	if not camera or not espContainer then
		box.Visible = false
		return
	end

	local characterPosition = getCharacterPosition(character)

	if not characterPosition then
		box.Visible = false
		return
	end

	local distance = (camera.CFrame.Position - characterPosition).Magnitude

	if distance > SETTINGS.MaxDistance then
		box.Visible = false
		return
	end

	local x, y, width, height = getFixedScreenBox(characterPosition, camera)

	if not x or not y or not width or not height then
		box.Visible = false
		return
	end

	local containerPosition = espContainer.AbsolutePosition
	local color = getCharacterColor(character)

	if SETTINGS.ShowTeamESP == false and color == SETTINGS.TeamColor then
		box.Visible = false
		return
	end

	box.Visible = true
	box.Position = UDim2.fromOffset(x - containerPosition.X, y - containerPosition.Y)
	box.Size = UDim2.fromOffset(width, height)

	local stroke = box:FindFirstChild("Stroke")

	if stroke and stroke:IsA("UIStroke") then
		stroke.Color = color
		stroke.Thickness = SETTINGS.BoxThickness
	end

	local label = box:FindFirstChild("Label")

	if label and label:IsA("TextLabel") then
		label.Text = getCharacterLabel(character, distance)
		label.TextColor3 = color
	end
end

local function updateAllEsp()
	if killed then
		return
	end

	if os.clock() - lastTeamRefresh >= SETTINGS.TeamRefreshInterval then
		lastTeamRefresh = os.clock()
		refreshTeamData()
	end

	for character, box in pairs(espFrames) do
		if not character:IsA("Model") then
			removeEspBox(character)
			continue
		end

		updateCharacterEsp(character, box)
	end
end

--// Cleanup

local function killScript()
	if killed then
		return
	end

	killed = true
	disconnectAll()

	for character in pairs(espFrames) do
		removeEspBox(character)
	end

	if espContainer then
		espContainer:Destroy()
		espContainer = nil
	end

	log("Killed.")
end

--// Start

local function start()
	local markerFrame = waitForMarkerFrame(15)

	if not markerFrame then
		log("Could not find marker GUI Frame.")
		return
	end

	espContainer = createContainer(markerFrame)

	refreshTeamData()
	scanCharacters()

	table.insert(connections, SETTINGS.CharactersFolder.ChildAdded:Connect(function(child)
		task.wait(0.1)

		if killed then
			return
		end

		if not isValidCharacter(child) then
			return
		end

		createEspBox(child)
		refreshTeamData()
	end))

	table.insert(connections, SETTINGS.CharactersFolder.ChildRemoved:Connect(function(child)
		removeEspBox(child)
		refreshTeamData()
	end))

	table.insert(connections, RunService.RenderStepped:Connect(updateAllEsp))

	table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end

		if input.KeyCode == SETTINGS.KillKey then
			killScript()
		end
	end))

	log("Started. Press PageDown to kill.")
end

local success, err = pcall(start)

if not success then
	log("Start failed:", err)
	killScript()
end