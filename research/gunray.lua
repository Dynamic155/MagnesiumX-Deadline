local Debris = game:GetService("Debris")
local UserInputService = game:GetService("UserInputService")

local function DrawRay(origin, destination, color)
	local direction = destination - origin
	local distance = direction.Magnitude

	local rayPart = Instance.new("Part")
	rayPart.Anchored = true
	rayPart.CanCollide = false
	rayPart.CanTouch = false
	rayPart.CanQuery = false
	rayPart.Material = Enum.Material.Neon
	rayPart.Transparency = 0.93
	rayPart.Color = color or Color3.fromRGB(0, 255, 255)
	rayPart.Size = Vector3.new(0.05, 0.05, distance)
	rayPart.CFrame = CFrame.lookAt(origin, destination) * CFrame.new(0, 0, -distance / 2)

	rayPart.Parent = workspace
	Debris:AddItem(rayPart, 0.02)
end

local function main(deltaTime)
	local ignoreItems = workspace.ignore:GetChildren()
	
    local viewModels = {}
	for _, obj in pairs(ignoreItems) do
		if obj.Name:match("^viewmodel_") then
			table.insert(viewModels, obj)
		end
	end

    local equipedModel;
	for _, model in pairs(viewModels) do
		local rootPart = model.root_part
        if rootPart.Position.Magnitude < 1000000000 then -- out of view
            equipedModel = model
            break
        end
	end

    local rootPart = equipedModel.root_part
    local origin = rootPart.Position
	local direction = rootPart.CFrame.LookVector * 500
    local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	local ignoreList = {}

	for _, v in workspace.map:GetDescendants() do
		table.insert(ignoreList, v)
	end

	for _, v in equipedModel:GetDescendants() do
		table.insert(ignoreList, v)
	end
	raycastParams.FilterDescendantsInstances = ignoreList

	local result: Ray = workspace:Raycast(origin, direction, raycastParams)

	DrawRay(origin, origin + direction)
    print(result)
end

local HeartbeatConnect
HeartbeatConnect = game:GetService("RunService").Heartbeat:Connect(function(deltaTime)
	local success, result = pcall(main, deltaTime)

	if not success then
		warn("Error caught:", result)
		HeartbeatConnect:Disconnect()
		HeartbeatConnect = nil
	end
end)

local function killScript()
    warn("Killing ")
    HeartbeatConnect:Disconnect()
    HeartbeatConnect = nil
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if input.KeyCode == Enum.KeyCode.PageDown then
        killScript()
    end
end)