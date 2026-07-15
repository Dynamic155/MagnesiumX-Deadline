local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local gui = player:WaitForChild("PlayerGui"):WaitForChild("ScreenGui")

gui.IgnoreGuiInset = true

local NEAR_PLANE_DISTANCE = 0.1

--// Utility
local function projectToScreen(pos: Vector3)
	local screenPoint, onScreen = camera:WorldToViewportPoint(pos)
	return Vector2.new(screenPoint.X, screenPoint.Y), onScreen
end

local function clipLineAgainstCamera(posA: Vector3, posB: Vector3)
	local camCF = camera.CFrame

	local localA = camCF:PointToObjectSpace(posA)
	local localB = camCF:PointToObjectSpace(posB)

	local nearZ = -NEAR_PLANE_DISTANCE

	local aInFront = localA.Z <= nearZ
	local bInFront = localB.Z <= nearZ

	if not aInFront and not bInFront then
		return nil, nil
	end

	local newA = localA
	local newB = localB

	if not aInFront and bInFront then
		local t = (nearZ - localA.Z) / (localB.Z - localA.Z)
		newA = localA:Lerp(localB, t)
	end

	if aInFront and not bInFront then
		local t = (nearZ - localA.Z) / (localB.Z - localA.Z)
		newB = localA:Lerp(localB, t)
	end

	return camCF:PointToWorldSpace(newA), camCF:PointToWorldSpace(newB)
end

local function updateLine2D(frame, pointA: Vector2, pointB: Vector2)
	local dx = pointB.X - pointA.X
	local dy = pointB.Y - pointA.Y

	local distance = math.sqrt(dx * dx + dy * dy)
	local angle = math.atan2(dy, dx)

	frame.Size = UDim2.fromOffset(distance, 2)
	frame.Position = UDim2.fromOffset(
		(pointA.X + pointB.X) / 2,
		(pointA.Y + pointB.Y) / 2
	)
	frame.Rotation = math.deg(angle)
	frame.Visible = true
end

--// Parts
local rig = workspace:WaitForChild("Rig")
local parts = {}

for _, part in ipairs(rig:GetChildren()) do
	if part:IsA("BasePart") then
		table.insert(parts, part)
	end
end

--// Frame pool (one per part)
local lines = {}

for _, part in ipairs(parts) do
	local frame = Instance.new("Frame")
	frame.Name = "Line"
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = Color3.new(1, 1, 1)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Visible = false
	frame.Parent = gui

	lines[part] = frame
end

--// Axis selection (stable)
local function getAxis(part)
	local size = part.Size

	if size.X > size.Y and size.X > size.Z then
		return part.CFrame.RightVector, size.X
	elseif size.Y > size.Z then
		return part.CFrame.UpVector, size.Y
	else
		return part.CFrame.LookVector, size.Z
	end
end

--// Render loop
RunService.RenderStepped:Connect(function()
	for _, part in ipairs(parts) do
		local line = lines[part]
		if not line then continue end

		local axis, maxSize = getAxis(part)

		local half = maxSize / 2
		local pointA = part.Position + axis * half
		local pointB = part.Position - axis * half

		local clippedA, clippedB = clipLineAgainstCamera(pointA, pointB)
		if not clippedA or not clippedB then
			line.Visible = false
			continue
		end

		local a2d, aOn = projectToScreen(clippedA)
		local b2d, bOn = projectToScreen(clippedB)

		if not (aOn or bOn) then
			line.Visible = false
			continue
		end

		updateLine2D(line, a2d, b2d)
	end
end)