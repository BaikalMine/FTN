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

function GetDepoByStation(station)
	for id, depo in pairs(stations.depos) do
		if depo == station or (type(depo) == "table" and depo.station == station) then
			return id
		end
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
		log("[WARN] Статус от неизвестной станции: " .. tostring(id))
		net:send(from, port, "requestRegister", "")
		return
	end

	local newHash = amount .. "|" .. resource .. "|" .. resType

	if entry.lastStatusHash == newHash then
		return
	end

	entry.lastStatusHash = newHash

	if role == "requester" then
		entry.freeAmount = amount
	elseif role == "provider" then
		entry.available = amount
		RebuildGroupedProviders()
	end

	entry.resource = resource
	entry.type = resType

	if role == "requester" then
		for _, t in ipairs(task) do
			if t.station.id == id then
				t.resType = resType
				break
			end
		end

		local trainCapacity = GetTrainCapacity(resType)
		local priority = entry.priority or 0

		local assignedTasks = 0
		if stationAssignments[id] then
			for _ in pairs(stationAssignments[id]) do assignedTasks = assignedTasks + 1 end
		end

		local maxTasks = (priority == 2 and 3) or (priority == 1 and 2) or 1
		local neededTasks = 0

		log(string.format("[STATUS] %s (%s): %s %s, свободно: %.2f, приоритет: %d, назначено: %d",
			entry.station.name, role, amount, resType, entry.freeAmount or 0, priority, assignedTasks))

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
			log(string.format("[TASK CREATE] Станция %s: создано %d задач (нужно %d, уже %d)",
				entry.station.name, toCreate, neededTasks, assignedTasks))

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