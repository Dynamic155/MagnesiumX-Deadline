function screenSpaceLine(pointA: Vector2, pointB: Vector2): Instance
    local line = Instance.new("Frame")

    line.Name = "line"
    line.BackgroundTransparency = 0
    line.BorderSizePixel = 0
    line.Visible = true

    local dx = pointB.X - pointA.X
    local dy = pointB.Y - pointA.Y

    local distance = math.sqrt(dx * dx + dy * dy)
    local angle = math.atan2(dy, dx)

    local midpoint = Vector2.new(
        (pointA.X + pointB.X) / 2,
        (pointA.Y + pointB.Y) / 2
    )

    line.AnchorPoint = Vector2.new(0.5, 0.5)
    line.Size = UDim2.fromOffset(distance, 1)
    line.Position = UDim2.fromOffset(midpoint.X, midpoint.Y)
    line.Rotation = math.deg(angle)

    return line
end