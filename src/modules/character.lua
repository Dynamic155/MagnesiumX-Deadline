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