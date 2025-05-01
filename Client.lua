-- FTN Client: стабильная версия с поддержкой учёта стаков и умной отправкой статуса

-- Конфигурация
local STATION_UUID = ""
local stationRole = "requester" -- "provider", "requester", "depo"
local port = 99
local priority = nil
local requestAmount = nil
local resource = "Нефть"

local promote = false

-- Компоненты
local net = computer.getPCIDevices(classes.NetworkCard)[1]
assert(net, "No network card found")

if promote and stationRole ~= "depo" then
	computer.promote()
end

net:open(port)
event.listen(net)

function log(_) end

local station = component.proxy(STATION_UUID)
assert(station, "Станция по UUID не найдена")

-- Время и кеш
local lastRegisterTime = 0
local lastStatusTime = 0
local lastForceTime = 0
local cacheLifetime = 5000
local lastInventoryTime = -cacheLifetime

-- Прочие переменные
local firstRegistered = false
local cachedPlatforms = nil
local inventoryCache = {}
local itemCountCache = {}
local lastStatus = {}

-- Получаем платформы (1 раз)
local function getStationPlatforms()
	if not cachedPlatforms then
		cachedPlatforms = {}
		local all = station:getAllConnectedPlatforms()
		for i = 2, #all do
			cachedPlatforms[#cachedPlatforms + 1] = all[i]
		end
	end
	return cachedPlatforms
end

-- Определяем тип ресурса
local resType = "item"
do
	local platforms = getStationPlatforms()
	if #platforms > 0 then
		local inv = platforms[1]:getInventories()[1]
		if inv and inv.size == 1 then
			resType = "fluid"
		end
	end
end

-- Подсчёт количества стаков ресурса с кешем и проверкой itemCount
local function countStacks(resourceName, now, platforms)
	local totalStacks = 0
	if now - lastInventoryTime > cacheLifetime then
		inventoryCache = {}
		itemCountCache = {}

		for _, platform in ipairs(platforms) do
			local inv = platform:getInventories()[1]
			if inv then
				local count = 0
				local cachedCount = itemCountCache[platform]
				local currentItemCount = inv.itemCount or 0

				if cachedCount ~= currentItemCount then
					itemCountCache[platform] = currentItemCount

					if resType == "fluid" and inv.size == 1 then
						local stack = inv:getStack(0)
						if not stack or not stack.item or not stack.item.name or stack.item.type.name:lower() == resourceName then
							count = math.floor(currentItemCount / 1000)
						end
					elseif resType == "item" and inv.size > 1 then
						local counted = {}
						for i = 0, inv.size - 1 do
							local stack = inv:getStack(i)
							if stack and stack.item and stack.item.type and not counted[i] then
								if stack.item.type.name:lower() == resourceName then
									count = count + 1
									counted[i] = true
								end
							end
						end
					end
				else
					count = inventoryCache[platform] or 0
				end

				inventoryCache[platform] = count
				totalStacks = totalStacks + count
			end
		end
		lastInventoryTime = now
	else
		for _, count in pairs(inventoryCache) do
			totalStacks = totalStacks + count
		end
	end
	return totalStacks
end

-- Получаем свободное место
local function getFree(resourceName, now, platforms)
	local capacityPer = resType == "fluid" and 2400 or 48
	local totalCapacity = #platforms * capacityPer
	local currentAmount = countStacks(resourceName, now, platforms)
	return totalCapacity - currentAmount, currentAmount
end

-- Регистрация станции
local function register()
	local id, name, loc = station.id, station.name, station.location
	local payload = table.concat({
		stationRole,
		id,
		name,
		tostring(math.floor(loc.x)),
		tostring(math.floor(loc.y)),
		tostring(math.floor(loc.z)),
		tostring(requestAmount or 0),
		tostring(priority or 0),
		tostring(resource or "-"):lower(),
		"0"
	}, "|")
	net:broadcast(port, "register", payload)
end

-- Отправка статуса
local function sendStatus(now)
	if stationRole == "depo" then return end

	local id = station.id
	local resourceName = tostring(resource or "-"):lower()
	local trainCap = (resType == "fluid" and 6400) or 128

	local platforms = getStationPlatforms()
	local amount, current = 0, 0

	if stationRole == "requester" then
		local free; free, current = getFree(resourceName, now, platforms)
		if (priority == nil or priority == 0) and free < trainCap then return end
		amount = math.floor(free * 100 + 0.5) / 100
	elseif stationRole == "provider" then
		current = countStacks(resourceName, now, platforms)
		if (priority == nil or priority == 0) and current < trainCap then return end
		amount = math.floor(current * 100 + 0.5) / 100
	end

	local forceSend = false
	if stationRole == "provider" then
		local prev = lastStatus.amount or 0
		local diff = math.abs(amount - prev)
		if prev == 0 or (diff / prev >= 0.3) or amount >= (#platforms * (resType == "fluid" and 2.4 or 48)) then
			forceSend = true
		end
	elseif stationRole == "requester" then
		forceSend = now - lastForceTime >= 60000
	end

	if not forceSend and lastStatus.amount == amount
		and lastStatus.resource == resourceName
		and lastStatus.resType == resType
		and lastStatus.role == stationRole then
		return
	end

	local msg = "updateStatus|" .. id .. "|" .. stationRole .. "|" .. resourceName .. "|" .. tostring(amount) .. "|" .. resType
	net:broadcast(port, "status", msg)

	lastStatus = {
		amount = amount,
		resource = resourceName,
		resType = resType,
		role = stationRole
	}
	
	lastForceTime = now

	if stationRole == "requester" then
		log("Запрос: может принять " .. amount .. (resType == "fluid" and " м³" or " стаков"))
	elseif stationRole == "provider" then
		log("Поставка: доступно " .. amount .. (resType == "fluid" and " м³" or " стаков"))
	end
end

-- Обработка входящих сообщений
local function handleMessage(_, _, from, portNum, cmd, payload)
	if cmd == "assignTrain" then
		log("Назначен поезд: " .. payload)
	elseif cmd == "requestRegister" then
		log("Сервер запросил повторную регистрацию")
	elseif cmd == "registerOK" and not firstRegistered then
		local tag = (priority == 2 and "[CRITICAL] ") or (priority == 1 and "[HIGH] ") or ""
		log("" .. tag .. "Регистрация: " .. station.name .. " (" .. stationRole .. ")")
		firstRegistered = true
	end
end

-- Запуск
register()
while true do
	local now = computer.millis()

	local e, _, from, portNum, cmd, payload = event.pull(0.1)

	if e == "NetworkMessage" and portNum == port then
		handleMessage(_, _, from, portNum, cmd, payload)
	end
	
	if now - lastRegisterTime >= 30000 then
		register()
		lastRegisterTime = now
	end

	if stationRole == "provider" and now - lastStatusTime >= 15000 then
		sendStatus(now)
		lastStatusTime = now
	elseif stationRole == "requester" and now - lastStatusTime >= 30000 then
		sendStatus(now)
		lastStatusTime = now
	end
end
