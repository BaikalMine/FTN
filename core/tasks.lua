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
	for hash, train in pairs(trains) do
		if isBusy[hash] then goto continue end
		if not TrainIsEmpty(train) then goto continue end

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
		if not TrainNearStation(train, station, 100) then goto continue end

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
