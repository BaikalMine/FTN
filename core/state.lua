function TrackArrivals()
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
							if TrainNearStation(train, stop.station, 100) then
								log("[ARRIVAL] Поезд " .. train:getName() .. " прибыл на станцию " .. stop.station.name)
								isBusy[stop.station.id] = train
							end
						end
					end
				end
			end
		end
	end
end

function ReleaseTrains()
	for _, train in pairs(trains) do
		if not isBusy[train.hash] then goto continue end

		local tt = train:getTimeTable()
		if not tt then
			log("[WARN] Поезд " .. train:getName() .. " не имеет расписания")
			goto continue
		end

		local index = tt:getCurrentStop()

		if index > 0 and tt.numStops > 1 then
			local prevStop = tt:getStop(0)
			if prevStop and prevStop.station and TrainNearStation(train, prevStop.station, 100) then
				local sid = prevStop.station.id or prevStop.station.hash
				log("[MOVE] Поезд " .. train:getName() .. " покидает станцию " .. prevStop.station.name)
				tt:removeStop(0)
				tt:setCurrentStop(index - 1)
				isBusy[sid] = nil

				if stations.requesters[sid] then
					for i = #task, 1, -1 do
						local t = task[i]
						if t.assignedTrain == train.hash then
							log("[TASK RELEASE] Удаляем задачу после выхода с requester: " .. train:getName())
							if t.providerStation then
								local providerEntry = stations.providers[t.providerStation.id]
								if providerEntry then
									providerEntry.assignedTrains = math.max(0, (providerEntry.assignedTrains or 1) - 1)
								end
							end
							table.remove(task, i)
							break
						end
					end
				end
			end

		elseif tt.numStops == 1 then
			local stop = tt:getStop(0)
			if stop and stop.station and TrainNearStation(train, stop.station, 100) then
				local sid = stop.station.id or stop.station.hash
				local isDepo = stations.depos[sid] ~= nil

				if isDepo then
					log("[COMPLETE] Поезд " .. train:getName() .. " завершил задачу и прибыл в депо")

					isBusy[train.hash] = nil
					isBusy[sid] = nil
					TrainEmptyCache[train.hash] = nil

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
							if t.providerStation then
								local providerEntry = stations.providers[t.providerStation.id]
								if providerEntry then
									providerEntry.assignedTrains = math.max(0, (providerEntry.assignedTrains or 1) - 1)
								end
							end
							table.remove(task, i)
							break
						end
					end
				end
			end
		end

		-- Освобождаем поезд через кэш
		local sid = stationAssignmentsByTrain[train.hash]
		if sid then
			if stationAssignments[sid] then
				stationAssignments[sid][train.hash] = nil
				if next(stationAssignments[sid]) == nil then
					stationAssignments[sid] = nil
				end
			end
			stationAssignmentsByTrain[train.hash] = nil
			log("[CLEANUP] Удалён поезд " .. train:getName() .. " из stationAssignments станции " .. sid)
		end

		trainAssignments[train.hash] = nil

		::continue::
	end
end
