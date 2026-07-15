local FogEffect

local function disableFog()
	local atmosphere = game.Lighting:FindFirstChild("preset_atmosphere")

	if atmosphere then
		FogEffect = atmosphere:Clone()
		atmosphere:Destroy()
	end
end

local function enableFog()
	if FogEffect and not game.Lighting:FindFirstChild("preset_atmosphere") then
		FogEffect.Parent = game.Lighting
	end
end