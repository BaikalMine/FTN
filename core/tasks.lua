local groupedProviders = {}

function RebuildGroupedProviders()
	groupedProviders = {}
	for id, entry in pairs(stations.providers) do
		if entry and entry.resource and entry.type then
			local key = entry.type .. ":" .. entry.resource:lower()
			groupedProviders[key] = groupedProviders[key] or {}
			table.insert(groupedProviders[key], entry)
		end
	end
end

function ProcessTasks()
	local availableTrains = {}

	-- Собираем свободные поезда
	for hash, train in pairs(trains) do
		if isBusy[hash] then goto continue end
		if not TrainIsEmpty(train) then goto continue end

		local tt = train:getTimeTable()
		if not tt then goto continue end

		local stop = tt:getStop(0)
		if not stop or not stop.station then goto continue end
		if not stop.station.location then goto continue end

		local station = stop.station
		local matchedId = GetDepoByStation(station)
		if not matchedId then goto continue end
		if not TrainNearStation(train, station, 100) then goto continue end

		table.insert(availableTrains, {
			hash = hash,
			train = train,
			depo = station,
			pos = station.location
		})

		::continue::
	end

	-- Обработка задач
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
		if active >= maxTasks then
			t.waitLogged = true
			goto next_task
		end

		local key = t.resType .. ":" .. t.resource:lower()
		local providers = groupedProviders[key] or {}

		local bestProvider, maxAmount = nil, -1
		for _, entry in ipairs(providers) do
			if entry and entry.station then
				local amount = tonumber(entry.available)
				if type(amount) == "number" then
					entry.assignedTrains = entry.assignedTrains or 0

					local trainCapacity = GetTrainCapacity(t.resType)
					local availableForNewTrain = amount - (entry.assignedTrains * trainCapacity)

					local ignoreLimit = t.priority > 0
					local enoughRes = availableForNewTrain >= trainCapacity

					if (ignoreLimit or enoughRes) and amount > maxAmount then
						bestProvider = entry
						maxAmount = amount
					end
				end
			end
		end

		if not bestProvider then goto next_task end

		-- Сортируем поезда по расстоянию
		table.sort(availableTrains, function(a, b)
			local dx1 = a.pos.x - t.station.location.x
			local dy1 = a.pos.y - t.station.location.y
			local dz1 = a.pos.z - t.station.location.z
			local dist1 = dx1 * dx1 + dy1 * dy1 + dz1 * dz1

			local dx2 = b.pos.x - t.station.location.x
			local dy2 = b.pos.y - t.station.location.y
			local dz2 = b.pos.z - t.station.location.z
			local dist2 = dx2 * dx2 + dy2 * dy2 + dz2 * dz2

			return dist1 < dist2
		end)

		local bestTrainEntry = availableTrains[1]
		if not bestTrainEntry then goto next_task end

		local bestTrain = bestTrainEntry.train
		local depo = bestTrainEntry.depo

		local tt = bestTrain:getTimeTable()
		if not tt then goto next_task end

		while tt.numStops > 0 do tt:removeStop(0) end
		tt:setCurrentStop(0)
		tt:addStop(0, bestProvider.station, { definition = 0, duration = 15, isDurationAndRule = false })
		tt:addStop(1, t.station,             { definition = 1, duration = 15, isDurationAndRule = true  })
		tt:addStop(2, depo,                   { definition = 0, duration = 15, isDurationAndRule = false })

		isBusy[bestTrain.hash] = true
		isBusy[depo] = bestTrain
		stationAssignments[matchedId] = stationAssignments[matchedId] or {}
		stationAssignments[matchedId][bestTrain.hash] = true
		stationAssignmentsByTrain[bestTrain.hash] = matchedId
		trainAssignments[bestTrain.hash] = matchedId
		t.assignedTrain = bestTrain.hash
		t.providerStation = bestProvider.station

		bestProvider.assignedTrains = (bestProvider.assignedTrains or 0) + 1

		table.remove(availableTrains, 1)

		local tag = (t.priority == 2 and "[CRITICAL] ") or (t.priority == 1 and "[HIGH] ") or ""
		log("[TASK] " .. tag .. "Назначен поезд " .. bestTrain:getName() ..
			": " .. bestProvider.station.name .. " → " .. t.station.name .. " → " .. depo.name)

		::next_task::
	end
end
