TrainEmptyCache = {}

function TrainIsEmpty(train)
	if TrainEmptyCache[train.hash] ~= nil then
		return TrainEmptyCache[train.hash]
	end
	for _, vehicle in pairs(train:getVehicles()) do
		local inv = vehicle:getInventories()[1]
		if inv and inv.itemCount > 0 then
			TrainEmptyCache[train.hash] = false
			return false
		end
	end
	TrainEmptyCache[train.hash] = true
	return true
end

function ResetTrainEmptyCache()
	for k in pairs(TrainEmptyCache) do
		TrainEmptyCache[k] = nil
	end
end

function ClearTimeTable(train)
	local tt = train:getTimeTable()
	while tt.numStops > 0 do
		tt:removeStop(0)
	end
	tt:setCurrentStop(0)
end

function AddStop(train, station, index, definition, duration, isRule)
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

function TrainNearStation(train, station, maxDist)
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

function RestoreActiveTrains(targetDepo)
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

function UpdateTrainNetwork()
	local platforms = component.findComponent(classes.TrainPlatform)
	if #platforms == 0 then return end
	local graph = component.proxy(platforms[1]):getTrackGraph()
	local trainList = graph:getTrains()
	for _, train in pairs(trainList) do
		if not trains[train.hash] and TrainIsEmpty(train) then
			trains[train.hash] = train
		end
	end
end
