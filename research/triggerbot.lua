local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local virtualInputManager = game:GetService("VirtualInputManager")

-- settings
local reactionTime = 0.2
_G.Ray = true
-- debug rays
local function DrawRay(origin, destination, color)
	if _G.Ray == true then
			
		local direction = destination - origin
		local distance = direction.Magnitude

		local rayPart = Instance.new("Part")
		rayPart.Anchored = true
		rayPart.CanCollide = false
		rayPart.Material = Enum.Material.Neon
		rayPart.Color = color or Color3.fromRGB(255, 0, 0)
		rayPart.Size = Vector3.new(0.05, 0.05, distance)
		rayPart.CFrame = CFrame.lookAt(origin, destination) * CFrame.new(0, 0, -distance / 2)

		rayPart.Parent = workspace
		Debris:AddItem(rayPart, 1)
	end
end


local function IsHitbox(inst)
	return inst
		and inst:IsA("BasePart")
		and inst.Name:lower():find("hitbox")
end

-- owner character from part
local function GetCharacterFromPart(part)
	if not part then return nil end
	return part:FindFirstAncestorWhichIsA("Model")
end

-- local char
local function GetLocalCharacter()
	return workspace.characters:FindFirstChild("StarterCharacter")
end

-- ray
local function IsVisible()
	local character = GetLocalCharacter()
	if not character then return nil end

	local head = character:FindFirstChild("head")
	if not head then return nil end

	local origin = head.Position
	local direction = head.CFrame.LookVector * 500

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	local ignoreList = {}

	-- instance filters
	for _, v in workspace.map:GetDescendants() do
		table.insert(ignoreList, v)
	end
	for _, v in character:GetDescendants() do
		table.insert(ignoreList, v)
	end
	raycastParams.FilterDescendantsInstances = ignoreList

	
	local result: Ray = workspace:Raycast(origin, direction, raycastParams)

	DrawRay(origin, origin + direction, Color3.fromRGB(0, 255, 0))

	return result
end

-- MAIN LOOP
while task.wait(reactionTime) do
	local result = IsVisible()

	if result and result.Instance then
		local hit = result.Instance

		if IsHitbox(hit) then
			local character = GetCharacterFromPart(hit)

			-- ignore local player
			if character and character ~= GetLocalCharacter() then
				if hit.Color then
					hit.Transparency = 0.5
					hit.Color = Color3.fromRGB(255, 0, 0)
				end
				print("Hitbox hit:", hit:GetFullName())
				virtualInputManager:SendMouseButtonEvent(0, 0, 0, true, game, 0)   -- mouse down
			end
		end
	end
end