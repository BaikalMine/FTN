proxyCache = {}

function GetStationByID(id)
	if proxyCache[id] then return proxyCache[id] end
	local ok, obj = pcall(component.proxy, id)
	if ok and obj and obj.getHash then
		proxyCache[id] = obj
		return obj
	end
	return nil
end

function HandleRegister(from, payload)
	local role, id, name, x, y, z, amount, priority, resource =
		payload:match("([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)")
	if not id or id == "" then return end

	priority = tonumber(priority) or 0
	resource = tostring(resource or "-"):lower()

	local alreadyRegistered = clients[from] and clients[from].id == id and clients[from].role == role
	if alreadyRegistered then return end

	if clients[from] and not alreadyRegistered then
		log("[RE-REGISTER] Клиент " .. tostring(from) .. " уже зарегистрирован как другой. Запрос повторной регистрации.")
		net:send(from, port, "requestRegister", "")
		return
	end

	local proxyStation = GetStationByID(id)
	if not proxyStation then
		log("[ERROR] Не удалось получить station по ID: " .. id)
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
		RebuildGroupedProviders()
	elseif role == "requester" then
		stations.requesters[id] = entry
	elseif role == "depo" then
		stations.depos[id] = proxyStation
		RestoreActiveTrains(proxyStation)
	else
		log("[WARN] Неизвестная роль: " .. role)
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

function HandleStatusUpdate(from, payload)
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
        RebuildGroupedProviders()
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

log(("[STATUS] %s (%s): %s, свободно: %.2f, приоритет: %d, уже назначено: %d"):format(
	entry.station.name, role, resType, entry.freeAmount or 0, priority, assignedTasks
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
