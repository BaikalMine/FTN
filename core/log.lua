logLines = {}
maxLogLines = 25

function getTimestamp()
	local ms = computer.millis()
	local sec = math.floor(ms / 1000)
	local h = math.floor(sec / 3600) % 24
	local m = math.floor(sec / 60) % 60
	local s = sec % 60
	return string.format("%02d:%02d:%02d", h, m, s)
end

function redrawLogs()
	gpu:drawRect(Vector2d.new(0, 0), screenSize, Color.BLACK, nil, 0)
	for i, line in ipairs(logLines) do
		gpu:drawText(Vector2d.new(10, (i - 1) * 30), line, 20, Color.WHITE, false)
	end
	gpu:flush()
end

function log(msg, color)
	color = color or Color.WHITE
	local timestamp = getTimestamp()
	local line = timestamp .. " | " .. msg
	table.insert(logLines, line)
	if #logLines > maxLogLines then table.remove(logLines, 1) end
	redrawLogs()
end
