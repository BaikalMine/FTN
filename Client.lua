-- FTN Client: стабильная версия с поддержкой учёта стаков и умной отправкой статуса

-- Конфигурация
local STATION_UUID = ""
local stationRole = "requester" -- "provider", "requester", "depo"
local port = 99
local priority = nil
local requestAmount = nil
local resource = "Нефть"

local promote = false

-- Сеть
local net = computer.getPCIDevices(classes.NetworkCard)[1]
assert(net, "No network card found")

if promote and stationRole ~= "depo" then
	computer.promote()
end

net:open(port)
event.listen(net)

-- Экран
local gpu = computer.getPCIDevices(classes.GPU_T2_C)[1]
assert(gpu, "GPU не найден")
local screen = computer.getPCIDevices(classes.FINComputerScreen)[1]
assert(screen, "Экран не найден")
gpu:bindScreen(screen)
local screenSize = gpu:getScreenSize()

-- Логирование
local logLines = {}
local maxLogLines = 5

local function log(msg)
	local timestamp = string.format("%02d:%02d:%02d",
		math.floor(computer.millis() / 3600000) % 24,
		math.floor(computer.millis() / 60000) % 60,
		math.floor(computer.millis() / 1000) % 60
	)
	table.insert(logLines, timestamp .. " | " .. msg)
	if #logLines > maxLogLines then table.remove(logLines, 1) end
	gpu:drawRect({x = 0, y = 0}, screenSize, {r = 0, g = 0, b = 0, a = 1}, nil, 0)
	for i, line in ipairs(logLines) do
		gpu:drawText({x = 10, y = (i - 1) * 30}, line, 20, {r = 1, g = 1, b = 1, a = 1}, false)
	end
	gpu:flush()
end

-- Получение станции
local station = component.proxy(STATION_UUID)
assert(station, "Станция по UUID не найдена")

-- Платформы
local platforms = {}
do
	local all = station:getAllConnectedPlatforms()
	for i = 2, #all do
		platforms[#platforms + 1] = all[i]
	end
end

-- Тип ресурса
local resType = "item"
if #platforms > 0 and platforms[1]:getInventories()[1] and platforms[1]:getInventories()[1].size == 1 then
	resType = "fluid"
end

-- Подсчёт
local function countStacks(resourceName)
	local total = 0
	for _, platform in ipairs(platforms) do
		local inv = platform:getInventories()[1]
		if inv then
			local itemCount = inv.itemCount or 0
			if resType == "fluid" then
				local stack = inv:getStack(0)
				if not stack or not stack.item or not stack.item.name or stack.item.type.name:lower() == resourceName then
					total = total + math.floor(itemCount / 1000)
				end
			else
				for i = 0, inv.size - 1 do
					local stack = inv:getStack(i)
					if stack and stack.item and stack.item.type and stack.item.type.name:lower() == resourceName then
						total = total + 1
					end
				end
			end
		end
	end
	return total
end

local function getFree(resourceName)
	local cap = resType == "fluid" and 2400 or 48
	return #platforms * cap - countStacks(resourceName)
end

-- Статус
local function sendStatus()
	local resourceName = tostring(resource or "-"):lower()
	local id = station.id
	local amount = 0

	if stationRole == "provider" then
		amount = countStacks(resourceName)
	elseif stationRole == "requester" then
		amount = getFree(resourceName)
	end

	local msg = "updateStatus|" .. id .. "|" .. stationRole .. "|" .. resourceName .. "|" .. amount .. "|" .. resType
	net:broadcast(port, "status", msg)

	if stationRole ~= "depo" then
		log(stationRole .. ": " .. amount .. (resType == "fluid" and " м³" or " стаков"))
	end
end

-- Регистрация
local function register()
	local id, name, loc = station.id, station.name, station.location
	local payload = table.concat({
		stationRole,
		id,
		name,
		math.floor(loc.x),
		math.floor(loc.y),
		math.floor(loc.z),
		tostring(requestAmount or 0),
		tostring(priority or 0),
		tostring(resource or "-"):lower(),
		"0"
	}, "|")
	net:broadcast(port, "register", payload)
end

-- Обработка сообщений
local function handleMessage(_, _, from, portNum, cmd, payload)
	if cmd == "assignTrain" then
		log("Назначен поезд: " .. payload)
	elseif cmd == "requestRegister" then
		register()
	elseif cmd == "registerOK" then
		log("Зарегистрирован: " .. station.name)
	elseif cmd == "requestStatus" then
		if stationRole == "provider" then sendStatus() end
	end
end

-- Основной цикл
local lastRegisterTime = 0
while true do
	local now = computer.millis()
	local e, _, from, portNum, cmd, payload = event.pull(1)

	if e == "NetworkMessage" and portNum == port then
		handleMessage(_, _, from, portNum, cmd, payload)
	end

	if now - lastRegisterTime >= 30000 then
		register()
		lastRegisterTime = now
	end

	if stationRole == "requester" and now % 30000 < 1000 then
		sendStatus()
	end
end
