logLines = {}
maxLogLines = 25
lastRedrawTime = 0
redrawInterval = 1000 -- миллисекунд (1 секунда)

function getTimestamp()
	local ms = computer.millis()
	local sec = math.floor(ms / 1000)
	local h = math.floor(sec / 3600) % 24
	local m = math.floor(sec / 60) % 60
	local s = sec % 60
	return string.format("%02d:%02d:%02d", h, m, s)
end

function redrawLogs(force)
	local now = computer.millis()
	if force or (now - lastRedrawTime >= redrawInterval) then
		gpu:drawRect(Vector2d.new(0, 0), screenSize, Color.BLACK, nil, 0)
		for i, line in ipairs(logLines) do
			gpu:drawText(Vector2d.new(10, (i - 1) * 30), line, 20, Color.WHITE, false)
		end
		gpu:flush()
		lastRedrawTime = now
	end
end

function log(msg)
	local timestamp = getTimestamp()
	local line = timestamp .. " | " .. msg
	table.insert(logLines, line)
	if #logLines > maxLogLines then
		table.remove(logLines, 1)
	end
	redrawLogs(false)
end