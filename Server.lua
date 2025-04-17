local port = 99
local stations = {requesters = {}, providers = {}, depos = {}}
local trains = {}
local trainDepo = {}
local isBusy = {}
local task = {}
local clients = {}
local trainAssignments = {}
local stationAssignments = {}

local trainEmptyCache = {}
local proxyCache = {}

local net = computer.getPCIDevices(classes.NetworkCard)[1]
if not net then error("No network card found") end

computer.promote()

net:open(port)
event.listen(net)

-- 📦 Утилиты: вектор и цвет
Vector2d = {}
function Vector2d.new(x, y)
	return { x = math.floor(x), y = math.floor(y) }
end

Color = {
	WHITE = { r = 1.0, g = 1.0, b = 1.0, a = 1.0 },
	GREY  = { r = 0.75, g = 0.75, b = 0.75, a = 1.0 },
	BLACK = { r = 0.0, g = 0.0, b = 0.0, a = 1.0 },
	GREEN = { r = 0.0, g = 1.0, b = 0.0, a = 1.0 },
	RED   = { r = 1.0, g = 0.0, b = 0.0, a = 1.0 },
}

-- 🖥️ Инициализация GPU и экрана
local gpu = computer.getPCIDevices(classes.GPU_T2_C)[1]
if not gpu then computer.panic("❌ GPU не найден") end

local screens = component.findComponent(classes.Screen)
if #screens == 0 then computer.panic("❌ Экран не найден") end

local screen = component.proxy(screens[1])
gpu:bindScreen(screen)
local screenSize = gpu:getScreenSize()

-- 🧾 Хранилище логов
local logLines = {}
local maxLogLines = 25

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

log("[INIT] 🚆 FTN Server запущен. Ожидание клиентов на порту: " .. port)

-- 🔁 Кэшированное получение станции
function getStationByID(id)
	if proxyCache[id] then return proxyCache[id] end
	local ok, obj = pcall(component.proxy, id)
	if ok and obj and obj.getHash then
		proxyCache[id] = obj
		return obj
	end
	return nil
end

-- 🔁 Очистка расписания
function clearTimeTable(train)
	local tt = train:getTimeTable()
	while tt.numStops > 0 do
		tt:removeStop(0)
	end
	tt:setCurrentStop(0)
end

-- 📦 Кэшированная проверка на пустой поезд
function trainIsEmpty(train)
	if trainEmptyCache[train.hash] ~= nil then
		return trainEmptyCache[train.hash]
	end
	for _, vehicle in pairs(train:getVehicles()) do
		local inv = vehicle:getInventories()[1]
		if inv and inv.itemCount > 0 then
			trainEmptyCache[train.hash] = false
			return false
		end
	end
	trainEmptyCache[train.hash] = true
	return true
end

-- 🧹 Очистка trainEmptyCache
function resetTrainEmptyCache()
	for k in pairs(trainEmptyCache) do
		trainEmptyCache[k] = nil
	end
end

-- 🛤️ Добавление станции в расписание
function addStop(train, station, index, definition, duration, isRule)
	if not station or type(station) ~= "userdata" or not station.getHash then
		log("[ERROR] ❌ addStop получил некорректный station! Тип: " .. tostring(type(station)))
		return
	end
	train:getTimeTable():addStop(index, station, {
		definition = definition,
		duration = duration,
		isDurationAndRule = isRule
	})
end

-- 📏 Быстрый расчёт расстояния
local function distSqr(a, b)
	local dx = a.x - b.x
	local dy = a.y - b.y
	local dz = a.z - b.z
	return dx*dx + dy*dy + dz*dz
end

-- 🛠️ Интервальные таймеры
local lastUpdateTime = 0
local lastProcessTime = 0
local lastRestoreTime = 0
local lastArrivalTime = 0
local lastReleaseTime = 0

-- интервалы в миллисекундах
local updateInterval = 30000
local processInterval = 5000
local restoreInterval = 60000
local arrivalInterval = 10000
local releaseInterval = 15000

function restoreActiveTrains(targetDepo)
	if not targetDepo then return end

	local name = targetDepo.name
	local platforms = component.findComponent(classes.TrainPlatform)
	if #platforms == 0 then return end

	local graph = component.proxy(platforms[1]):getTrackGraph()
	local trainList = graph:getTrains()

	for _, train in pairs(trainList) do
		local hash = train.hash
		local trainName = train:getName()

		if trains[hash] or isBusy[hash] then goto continue end

		local tt = train:getTimeTable()
		if not tt or tt.numStops == 0 then goto continue end

		for i = 0, tt.numStops - 1 do
			local stop = tt:getStop(i)
			if stop and stop.station and stop.station.name == name then
				trains[hash] = train
				trainDepo[hash] = targetDepo
				isBusy[hash] = true
				isBusy[targetDepo.id or targetDepo.hash] = train

				log("[RESTORE] ✅ Восстановлен поезд " .. trainName .. " для депо " .. name)

				-- 🔎 ищем requester в расписании
				local requester = nil
				for j = 0, tt.numStops - 1 do
					local s = tt:getStop(j)
					if s and s.station and stations.requesters[s.station.id or s.station.hash] then
						requester = s.station
						break
					end
				end

				if requester then
					local sid = requester.id or requester.hash
					local entry = stations.requesters[sid]
					if entry then
						table.insert(task, {
							station = requester,
							clientAddress = "restored",
							priority = entry.priority or 0,
							resource = entry.resource or "-",
							resType = entry.type or "item",
							assignedTrain = hash,
							waitLogged = true
						})
						stationAssignments[sid] = stationAssignments[sid] or {}
						stationAssignments[sid][hash] = true
						trainAssignments[hash] = sid

						log("[TASK RESTORE] 🚂 Восстановлена задача для " .. requester.name .. " поездом " .. trainName)
					end
				end

				return
			end
		end

		::continue::
	end

	log("[RESTORE] ❓ Поезд для депо " .. name .. " не найден")
end

function trainNearStation(train, station, maxDist)
	local maxDistSqr = (maxDist or 100)^2
	local pos = train:getFirst().location
	local sPos = station.location
	if pos and sPos then
		local dx = pos.x - sPos.x
		local dy = pos.y - sPos.y
		local dz = pos.z - sPos.z
		local distSqr = dx*dx + dy*dy + dz*dz
		return distSqr < maxDistSqr
	end
	return false
end

function processTasks()
	local availableTrains = {}
	for hash, train in pairs(trains) do
		if isBusy[hash] then goto continue end
		if not trainIsEmpty(train) then goto continue end

		local tt = train:getTimeTable()
		if not tt then goto continue end

		local stop = tt:getStop(0)
		if not stop or not stop.station then goto continue end
		if not stop.station.location then goto continue end

		local station = stop.station
		local matchedId = nil
		for id, entry in pairs(stations.depos) do
			if entry == station or (type(entry) == "table" and entry.station == station) then
				matchedId = id
				break
			end
		end
		if not matchedId then goto continue end
		if not trainNearStation(train, station, 100) then goto continue end

		table.insert(availableTrains, {
			hash = hash,
			train = train,
			depo = station,
			pos = station.location
		})

		::continue::
	end

	for i = #task, 1, -1 do
		local t = task[i]
		if t.assignedTrain or not t.station then goto next_task end

		local matchedId = nil
		for id, entry in pairs(stations.requesters) do
			if entry.station == t.station or entry == t.station then
				matchedId = id
				break
			end
		end
		if not matchedId then goto next_task end

		local active = 0
		if stationAssignments[matchedId] then
			for _ in pairs(stationAssignments[matchedId]) do active = active + 1 end
		end
		local maxTasks = (t.priority == 2 and 3) or (t.priority == 1 and 2) or 1
		if active >= maxTasks then t.waitLogged = true goto next_task end

		local key = t.resType .. ":" .. t.resource:lower()
		local providers = groupedProviders[key] or {}
		local bestProvider, maxAmount = nil, -1
		for _, entry in ipairs(providers) do
			if entry and entry.station then
				local amount = tonumber(entry.available)
				if type(amount) == "number" then
					local enoughRes = (t.resType == "fluid" and amount >= 6400)
					              or (t.resType == "item" and amount >= 128)
					local ignoreLimit = t.priority > 0
					if (ignoreLimit or enoughRes) and amount > maxAmount then
						bestProvider = entry.station
						maxAmount = amount
					end
				end
			end
		end
		if not bestProvider then goto next_task end

		local bestTrain, bestTrainIndex, bestDist = nil, nil, nil
		for idx, entry in ipairs(availableTrains) do
			local dx = entry.pos.x - t.station.location.x
			local dy = entry.pos.y - t.station.location.y
			local dz = entry.pos.z - t.station.location.z
			local dist = dx * dx + dy * dy + dz * dz
			if not bestDist or dist < bestDist then
				bestTrain = entry.train
				bestTrainIndex = idx
				bestDist = dist
			end
		end
		if not bestTrain then goto next_task end

		local depo = availableTrains[bestTrainIndex].depo
		local tt = bestTrain:getTimeTable()
		if not tt then goto next_task end

		while tt.numStops > 0 do tt:removeStop(0) end
		tt:setCurrentStop(0)
		tt:addStop(0, bestProvider, { definition = 0, duration = 15, isDurationAndRule = false })
		tt:addStop(1, t.station,    { definition = 1, duration = 15, isDurationAndRule = true  })
		tt:addStop(2, depo,         { definition = 0, duration = 15, isDurationAndRule = false })

		isBusy[bestTrain.hash] = true
		isBusy[depo] = bestTrain
		stationAssignments[matchedId] = stationAssignments[matchedId] or {}
		stationAssignments[matchedId][bestTrain.hash] = true
		trainAssignments[bestTrain.hash] = matchedId
		t.assignedTrain = bestTrain.hash

		table.remove(availableTrains, bestTrainIndex)

		local tag = (t.priority == 2 and "[CRITICAL] ") or (t.priority == 1 and "[HIGH] ") or ""
		log("[TASK] " .. tag .. "Назначен поезд " .. bestTrain:getName() ..
			": " .. bestProvider.name .. " → " .. t.station.name .. " → " .. depo.name)

		::next_task::
	end
end

function trackArrivals()
	for _, train in pairs(trains) do
		if train and train.hash and train.getTimeTable then
			local hash = train.hash
			if isBusy[hash] then
				local tt = train:getTimeTable()
				if tt and tt.getCurrentStop and tt.getStop then
					local index = tt:getCurrentStop()
					if index >= 0 and index < tt.numStops then
						local stop = tt:getStop(index)
						if stop and stop.station and not isBusy[stop.station.id] then
							log("[ARRIVAL] Поезд " .. train:getName() .. " прибыл на " .. stop.station.name)
							isBusy[stop.station.id] = train
						end
					end
				end
			end
		end
	end
end

function releaseTrains()
	for _, train in pairs(trains) do
		if not isBusy[train.hash] then goto continue end

		local tt = train:getTimeTable()
		if not tt then
			log("[WARN] Поезд " .. train:getName() .. " не имеет расписания")
			goto continue
		end

		local index = tt:getCurrentStop()

		-- 🚦 Поезд уезжает со станции → удаляем предыдущую
		if index > 0 and tt.numStops > 1 then
			local prevStop = tt:getStop(0)
			if prevStop and prevStop.station then
				local sid = prevStop.station.id or prevStop.station.hash
				log("[MOVE] Поезд " .. train:getName() .. " покидает станцию " .. prevStop.station.name)
				tt:removeStop(0)
				tt:setCurrentStop(index - 1)
				isBusy[sid] = nil

				-- 🗑️ Удаляем задачу, если покинутая станция была requester
				if stations.requesters[sid] then
					for i = #task, 1, -1 do
						local t = task[i]
						if t.assignedTrain == train.hash then
							log("[TASK RELEASE] Удаляем задачу после выхода с requester: " .. train:getName())
							table.remove(task, i)
							break
						end
					end
				end
			end

		-- 🛑 Завершение задачи в депо
		elseif tt.numStops == 1 then
			local stop = tt:getStop(0)
			if stop and stop.station then
				local sid = stop.station.id or stop.station.hash
				local isDepo = stations.depos[sid] ~= nil

				if isDepo and trainNearStation(train, stop.station, 100) then
					log("[COMPLETE] Поезд " .. train:getName() .. " завершил задачу и прибыл в депо")

					isBusy[train.hash] = nil
					isBusy[sid] = nil
					trainEmptyCache[train.hash] = nil

					if stationAssignments[sid] then
						stationAssignments[sid][train.hash] = nil
						if next(stationAssignments[sid]) == nil then
							stationAssignments[sid] = nil
						end
					end

					for i = #task, 1, -1 do
						local t = task[i]
						if t.assignedTrain == train.hash then
							log("[TASK FINALIZE] Удаляем задачу, выполненную поездом " .. train:getName())
							table.remove(task, i)
						end
					end
				end
			end
		end

		-- 🔄 Удаление через индекс trainAssignments
		local sid = trainAssignments[train.hash]
		if sid and stationAssignments[sid] then
			stationAssignments[sid][train.hash] = nil
			if next(stationAssignments[sid]) == nil then
				stationAssignments[sid] = nil
			end
			log("[CLEANUP] Удалён поезд " .. train:getName() .. " из stationAssignments станции " .. sid)
		end
		trainAssignments[train.hash] = nil

		::continue::
	end
end

local function rebuildGroupedProviders()
	groupedProviders = {}
	for id, entry in pairs(stations.providers) do
		if entry and entry.resource and entry.type then
			local key = entry.type .. ":" .. entry.resource:lower()
			groupedProviders[key] = groupedProviders[key] or {}
			table.insert(groupedProviders[key], entry)
		end
	end
end

function handleRegister(from, payload)
	local role, id, name, x, y, z, amount, priority, resource =
		payload:match("([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)")
	if not id or id == "" then return end

	priority = tonumber(priority) or 0
	resource = tostring(resource or "-"):lower()

	local alreadyRegistered = clients[from] and clients[from].id == id and clients[from].role == role
	if alreadyRegistered then return end

	if clients[from] and not alreadyRegistered then
		log("[RE-REGISTER] 🔄 Клиент " .. tostring(from) .. " уже зарегистрирован как другой. Запрос повторной регистрации.")
		net:send(from, port, "requestRegister", "")
		return
	end

	local proxyStation = getStationByID(id)
	if not proxyStation then
		log("[ERROR] ❌ Не удалось получить station по ID: " .. id)
		net:send(from, port, "requestRegister", "")
		return
	end

	local entry = {
		id = id,
		name = name,
		location = {x = tonumber(x), y = tonumber(y), z = tonumber(z)},
		station = proxyStation,
		resource = resource,
		priority = priority,
		type = "item",
		available = 0,
		freeAmount = 0
	}

    if role == "provider" then
        stations.providers[id] = entry
        rebuildGroupedProviders()
	elseif role == "requester" then
		stations.requesters[id] = entry
	elseif role == "depo" then
		stations.depos[id] = proxyStation
		restoreActiveTrains(proxyStation)
	else
		log("[WARN] ❗ Неизвестная роль: " .. role)
		return
	end

	if not clients[from] then
		log("[REGISTER] " .. role .. ": " .. name .. " (" .. id .. ")")
	end

	clients[from] = {
		registered = true,
		id = id,
		role = role
	}
	net:send(from, port, "registerOK", "")
end

function handleStatusUpdate(from, payload)
	local id, role, resource, amount, resType =
		payload:match("updateStatus|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)")

	amount = tonumber(amount) or 0
	resource = tostring(resource or "-"):lower()
	resType = tostring(resType or "item")

	local entry = nil
	if role == "requester" then
		entry = stations.requesters[id]
	elseif role == "provider" then
		entry = stations.providers[id]
	elseif role == "depo" then
		return
	end

	if not entry then
		log("[WARN] ❓ Статус от неизвестной станции: " .. tostring(id))
		net:send(from, port, "requestRegister", "")
		return
	end

	-- 💾 Сохраняем новое состояние станции
	if role == "requester" then
		entry.freeAmount = amount
	elseif role == "provider" then
		entry.available = amount
        rebuildGroupedProviders()
	end

	entry.resource = resource
	entry.type = resType

	-- 🔁 Обновляем тип ресурса в уже созданных задачах
	for _, t in ipairs(task) do
		if t.station.id == id then
			t.resType = resType
			break
		end
	end

	-- 📦 Создание задач — только для requester
	if role == "requester" then
		local trainCapacity = (resType == "fluid" and 6400) or 128
		local priority = entry.priority or 0


	-- 🔁 Пропускаем, если статус не изменился и станция не поставщик (снижает лаги)
	if role ~= "provider"
		and entry.lastAmount == amount
		and entry.lastResType == resType then
		return
	end
		entry.lastAmount = amount
		entry.lastResType = resType

		-- 📊 Считаем все активные задачи для станции
local assignedTasks = 0
for _, t in ipairs(task) do
	if t.station.id == id then
		assignedTasks = assignedTasks + 1
	end
end

local maxTasks = (priority == 2 and 3) or (priority == 1 and 2) or 1
local neededTasks = 0

log(("[STATUS] %s (%s): %s %s, свободно: %.2f, приоритет: %d, уже назначено: %d"):format(
	entry.station.name, role, amount, resType, entry.freeAmount or 0, priority, assignedTasks
))

if priority > 0 then
	local fullTrains = math.floor(amount / trainCapacity)
	if fullTrains == 0 then
		neededTasks = 1
	else
		neededTasks = maxTasks
	end
else
	if amount >= trainCapacity then
		neededTasks = 1
	end
end

local toCreate = neededTasks - assignedTasks

if toCreate > 0 then
	log(("[TASK CREATE] Станция %s: создано %d задач (нужно %d, уже %d)"):format(
		entry.station.name, toCreate, neededTasks, assignedTasks
	))
	for i = 1, toCreate do
		table.insert(task, {
			station = entry.station,
			clientAddress = from,
			priority = priority,
			resource = resource,
			resType = resType
		})
	end
end
	end
end

function updateTrainNetwork()
	local platforms = component.findComponent(classes.TrainPlatform)
	if #platforms == 0 then return end
	local graph = component.proxy(platforms[1]):getTrackGraph()
	local trainList = graph:getTrains()
	for _, train in pairs(trainList) do
		if not trains[train.hash] and trainIsEmpty(train) then
			trains[train.hash] = train
		end
	end
end

-- 🔁 Главный цикл
local updateTimer = 0
local restoredTrains = false

while true do
	local now = computer.millis()

	local e, _, from, recvPort, cmd, payload = event.pull(0.2)
	if e == "NetworkMessage" and recvPort == port then
		if cmd == "register" then handleRegister(from, payload) end
		if cmd == "status" then handleStatusUpdate(from, payload) end
	end

	if now - lastUpdateTime >= updateInterval then
		updateTrainNetwork()
		lastUpdateTime = now
	end

	if now - lastProcessTime >= processInterval then
		processTasks()
		lastProcessTime = now
	end

	if now - lastArrivalTime >= arrivalInterval then
		trackArrivals()
		lastArrivalTime = now
	end

	if now - lastReleaseTime >= releaseInterval then
		releaseTrains()
		resetTrainEmptyCache()
		lastReleaseTime = now
	end
end
