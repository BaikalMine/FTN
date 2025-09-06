-- =========================
--  FTN Server (optimized)
-- =========================

local port = 99

-- Станции и сущности
local stations = { requesters = {}, providers = {}, depos = {} }
local trains = {}                -- hash -> train proxy
local trainDepo = {}             -- hash -> depo station
local clients = {}               -- sender -> {registered, id, role}

-- Индексы назначений
local trainAssignments = {}      -- trainHash -> requesterSid
local stationAssignments = {}    -- requesterSid -> set(trainHash -> true)

-- Статусы занятости
local isBusy = {}                -- обратная совместимость (станция/поезд -> obj/bool)
local busyTrains = {}            -- set(trainHash -> true)
local busyStations = {}          -- set(stationSid -> true)

-- Кеши
local trainEmptyCache = {}       -- trainHash -> bool
local proxyCache = {}            -- stationId -> station proxy
local providersByKey = {}        -- "type:resource" -> { [providerId] = entry }
local bestProviderCache = {}     -- key -> { id=..., amount=..., ts=... }
local groupedProviders = {}      -- оставлен для совместимости, можно не использовать

-- Быстрый доступ к часто используемым функциям
local pairs, ipairs = pairs, ipairs
local tinsert, tremove = table.insert, table.remove
local floor, abs = math.floor, math.abs

-- Сеть
local net = computer.getPCIDevices(classes.NetworkCard)[1]
if not net then error("No network card found") end
net:open(port)
event.listen(net)

-- GPU / экран
local gpu = computer.getPCIDevices(classes.GPU_T2_C)[1]
if not gpu then computer.panic("GPU not found") end
local screens = component.findComponent(classes.Screen)
if #screens == 0 then computer.panic("Screen not found") end
local screen = component.proxy(screens[1])
gpu:bindScreen(screen)
local screenSize = gpu:getScreenSize()

-- -------------------------
--     ЛОГИ (троттлинг)
-- -------------------------
local logLines = {}
local maxLogLines = 25
local logDirty = false
local lastLogFlush = 0
local logFlushInterval = 150 -- мс

local function getTimestamp()
  local ms = computer.millis()
  local sec = floor(ms / 1000)
  local h = floor(sec / 3600) % 24
  local m = floor(sec / 60) % 60
  local s = sec % 60
  if h < 10 then h = "0"..h end
  if m < 10 then m = "0"..m end
  if s < 10 then s = "0"..s end
  return tostring(h) .. ":" .. tostring(m) .. ":" .. tostring(s)
end

local function drawLogsNow()
  gpu:drawRect({x=0,y=0}, screenSize, {r=0,g=0,b=0,a=1}, nil, 0)
  local y = 0
  for i = 1, #logLines do
    gpu:drawText({x=10, y=y}, logLines[i], 20, {r=1,g=1,b=1,a=1}, false)
    y = y + 30
  end
  gpu:flush()
end

local function redrawLogsThrottled(now)
  if not logDirty then return end
  if now - lastLogFlush >= logFlushInterval then
    drawLogsNow()
    lastLogFlush = now
    logDirty = false
  end
end

local function log(msg)
  local line = getTimestamp() .. " | " .. msg
  tinsert(logLines, line)
  if #logLines > maxLogLines then tremove(logLines, 1) end
  logDirty = true
end

log("FTN Server started. Waiting clients at port: " .. port)

-- -------------------------
--     УТИЛИТЫ / КЕШИ
-- -------------------------
local function getStationByID(id)
  local cached = proxyCache[id]
  if cached then return cached end
  local ok, obj = pcall(component.proxy, id)
  if ok and obj and obj.getHash then
    proxyCache[id] = obj
    return obj
  end
  return nil
end

local function clearTimeTable(train)
  local tt = train:getTimeTable()
  if not tt then return end
  while tt.numStops > 0 do
    tt:removeStop(0)
  end
  tt:setCurrentStop(0)
end

local function trainIsEmpty(train)
  local h = train.hash
  local c = trainEmptyCache[h]
  if c ~= nil then return c end
  for _, vehicle in pairs(train:getVehicles()) do
    local inv = vehicle:getInventories()[1]
    if inv and inv.itemCount > 0 then
      trainEmptyCache[h] = false
      return false
    end
  end
  trainEmptyCache[h] = true
  return true
end

local function trainNearStation(train, station, maxDist)
  local maxDistSqr = (maxDist or 100)
  maxDistSqr = maxDistSqr * maxDistSqr
  local pos = train:getFirst().location
  local sPos = station.location
  if pos and sPos then
    local dx = pos.x - sPos.x
    local dy = pos.y - sPos.y
    local dz = pos.z - sPos.z
    local d2 = dx*dx + dy*dy + dz*dz
    return d2 < maxDistSqr
  end
  return false
end

-- -------------------------
--   Индексация провайдеров
-- -------------------------
local BEST_TTL = 2000 -- мс

local function addProviderToIndexes(entry)
  local key = entry.type .. ":" .. entry.resource
  groupedProviders[key] = groupedProviders[key] or {}
  tinsert(groupedProviders[key], entry) -- можно потом убрать, если не нужно

  providersByKey[key] = providersByKey[key] or {}
  providersByKey[key][entry.id] = entry
  bestProviderCache[key] = nil
end

local function removeProviderFromIndexes(entry)
  local key = entry.type .. ":" .. entry.resource
  if providersByKey[key] then
    providersByKey[key][entry.id] = nil
    if not next(providersByKey[key]) then providersByKey[key] = nil end
  end
  bestProviderCache[key] = nil
end

local function getBestProviderForKey(key, now)
  local cache = bestProviderCache[key]
  if cache and (now - cache.ts) <= BEST_TTL then
    return cache.id, cache.amount
  end
  local map = providersByKey[key]
  if not map then return nil, nil end
  local bestId, bestAmt = nil, -1
  for pid, entry in pairs(map) do
    local a = tonumber(entry.available) or 0
    if a > bestAmt then bestAmt, bestId = a, pid end
  end
  if bestId then
    bestProviderCache[key] = { id = bestId, amount = bestAmt, ts = now }
  end
  return bestId, bestAmt
end

-- -------------------------
--   ВОССТАНОВЛЕНИЕ ПОЕЗДОВ
-- -------------------------
local function restoreActiveTrains(targetDepo)
  if not targetDepo then return end
  local name = targetDepo.name

  local platforms = component.findComponent(classes.TrainPlatform)
  if #platforms == 0 then return end

  local graph = component.proxy(platforms[1]):getTrackGraph()
  local trainList = graph:getTrains()

  for _, train in pairs(trainList) do
    local hash = train.hash
    local trainName = train:getName()

    if trains[hash] or isBusy[hash] or busyTrains[hash] then goto continue end

    local tt = train:getTimeTable()
    if not tt or tt.numStops == 0 then goto continue end

    -- Если в расписании есть депо targetDepo — считаем поезд «наш»
    for i = 0, tt.numStops - 1 do
      local stop = tt:getStop(i)
      if stop and stop.station and stop.station.name == name then
        trains[hash] = train
        trainDepo[hash] = targetDepo
        isBusy[hash] = true
        busyTrains[hash] = true
        isBusy[targetDepo.id or targetDepo.hash] = train
        busyStations[targetDepo.id or targetDepo.hash] = true
        log("[RESTORE] Train " .. trainName .. " restored for depo " .. name)

        -- Попробуем найти requester в расписании
        local requester = nil
        for j = 0, tt.numStops - 1 do
          local s = tt:getStop(j)
          if s and s.station then
            local sid = s.station.id or s.station.hash
            if stations.requesters[sid] then
              requester = s.station
              break
            end
          end
        end

        if requester then
          local sid = requester.id or requester.hash
          local entry = stations.requesters[sid]
          if entry then
            tinsert(task, {
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
            log("[TASK RESTORE] Task restored for " .. requester.name .. " by train " .. trainName)
          end
        end
        return
      end
    end

    ::continue::
  end

  log("[RESTORE] Train for depo " .. name .. " not found")
end

-- -------------------------
--   РЕГИСТРАЦИЯ / СТАТУСЫ
-- -------------------------
local function handleRegister(from, payload)
  local role, id, name, x, y, z, amount, priority, resource =
    payload:match("([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)")
  if not id or id == "" then return end

  priority = tonumber(priority) or 0
  local res = tostring(resource or "-"):lower()

  local alreadyRegistered = clients[from] and clients[from].id == id and clients[from].role == role
  if alreadyRegistered then return end

  if clients[from] and not alreadyRegistered then
    log("[RE-REGISTER] Sender " .. tostring(from) .. " already registered as another client. Request re-register.")
    net:send(from, port, "requestRegister", "")
    return
  end

  local proxyStation = getStationByID(id)
  if not proxyStation then
    log("[ERROR] Cannot proxy station by id: " .. id)
    net:send(from, port, "requestRegister", "")
    return
  end

  local entry = {
    id = id,
    sid = id,
    name = name,
    location = { x = tonumber(x), y = tonumber(y), z = tonumber(z) },
    station = proxyStation,
    resource = res,
    priority = priority,
    type = "item",
    available = 0,
    freeAmount = 0,
    lastAmount = nil,
    lastResType = nil,
  }

  if role == "provider" then
    stations.providers[id] = entry
    addProviderToIndexes(entry)
  elseif role == "requester" then
    stations.requesters[id] = entry
  elseif role == "depo" then
    stations.depos[id] = proxyStation
    restoreActiveTrains(proxyStation)
  else
    log("[WARN] Unknown role: " .. tostring(role))
    return
  end

  if not clients[from] then
    log("[REGISTER] " .. role .. ": " .. name .. " (" .. id .. ")")
  end

  clients[from] = { registered = true, id = id, role = role }
  net:send(from, port, "registerOK", "")
end

local function handleStatusUpdate(from, payload)
  local id, role, resource, amount, resType =
    payload:match("updateStatus|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)")

  local amt = tonumber(amount) or 0
  local res = tostring(resource or "-"):lower()
  local rtype = tostring(resType or "item")

  local entry
  if role == "requester" then
    entry = stations.requesters[id]
  elseif role == "provider" then
    entry = stations.providers[id]
  elseif role == "depo" then
    return
  end

  if not entry then
    log("[WARN] Status from unknown station: " .. tostring(id))
    net:send(from, port, "requestRegister", "")
    return
  end

  -- Нормализуем ресурс/тип
  entry.resource = res
  entry.type = rtype

  -- Правильная логика обновления last* и раннего выхода
  if role ~= "provider" then
    if entry.lastAmount == amt and entry.lastResType == rtype then
      return
    end
    entry.lastAmount = amt
    entry.lastResType = rtype
  else
    entry.lastAmount = amt
    entry.lastResType = rtype
  end

  if role == "provider" then
    entry.available = amt
    bestProviderCache[rtype .. ":" .. res] = nil
    return
  end

  if role == "requester" then
    entry.freeAmount = amt

    local trainCapacity = (rtype == "fluid" and 6400) or 128
    local priority = entry.priority or 0

    -- Считаем активные задачи для станции
    local assignedTasks = 0
    for _, t in ipairs(task) do
      if t.station and (t.station.id == id or t.station.hash == id) then
        assignedTasks = assignedTasks + 1
      end
    end

    local maxTasks = (priority == 2 and 3) or (priority == 1 and 2) or 1
    local neededTasks = 0

    log(("[STATUS] %s (%s): %s %s, free: %.2f, prio: %d, assigned: %d")
      :format(entry.station.name, role, tostring(amt), rtype, entry.freeAmount or 0, priority, assignedTasks))

    if priority > 0 then
      local fullTrains = floor(amt / trainCapacity)
      if fullTrains == 0 then
        neededTasks = 1
      else
        neededTasks = maxTasks
      end
    else
      if amt >= trainCapacity then
        neededTasks = 1
      end
    end

    local toCreate = neededTasks - assignedTasks
    if toCreate > 0 then
      log(("[TASK CREATE] Station %s: creating %d (need %d, have %d)")
        :format(entry.station.name, toCreate, neededTasks, assignedTasks))
      for i = 1, toCreate do
        tinsert(task, {
          station = entry.station,
          clientAddress = from,
          priority = priority,
          resource = res,
          resType = rtype
        })
      end
    end
  end
end

-- -------------------------
--     ОБНОВЛЕНИЕ ПОЕЗДОВ
-- -------------------------
local availableTrains = {} -- trainHash -> { train=..., depo=..., pos=... }

local function isDepoStation(station)
  if not station then return false end
  local sid = station.id or station.hash
  return stations.depos[sid] ~= nil
end

local function updateTrainNetwork()
  local platforms = component.findComponent(classes.TrainPlatform)
  if #platforms == 0 then return end
  local graph = component.proxy(platforms[1]):getTrackGraph()
  local trainList = graph:getTrains()

  for _, train in pairs(trainList) do
    local h = train.hash
    if not trains[h] then
      trains[h] = train
    end
    if not busyTrains[h] and trainIsEmpty(train) then
      local tt = train:getTimeTable()
      if tt and tt.numStops > 0 then
        local stop0 = tt:getStop(0)
        if stop0 and stop0.station and isDepoStation(stop0.station) then
          availableTrains[h] = {
            train = train,
            depo = stop0.station,
            pos = stop0.station.location
          }
        end
      end
    end
  end
end

-- -------------------------
--        ПЛАНИРОВЩИК
-- -------------------------
local function processTasks()
  -- Подготовка кандидатов уже сделана в updateTrainNetwork()
  for i = #task, 1, -1 do
    local t = task[i]
    if t.assignedTrain or not t.station then goto next_task end

    -- Проверка активных назначений по приоритету
    local matchedId = t.station.id or t.station.hash
    local active = 0
    if stationAssignments[matchedId] then
      for _ in pairs(stationAssignments[matchedId]) do active = active + 1 end
    end
    local maxTasks = (t.priority == 2 and 3) or (t.priority == 1 and 2) or 1
    if active >= maxTasks then
      t.waitLogged = true
      goto next_task
    end

    -- Лучший провайдер по ключу
    local key = t.resType .. ":" .. t.resource
    local bestId, maxAmount = getBestProviderForKey(key, computer.millis())
    local bestProviderEntry = bestId and stations.providers[bestId] or nil
    local bestProvider = bestProviderEntry and bestProviderEntry.station or nil
    if not bestProvider then goto next_task end

    -- Выбор ближайшего доступного поезда-кандидата
    local bestTrain, bestTrainHash, bestTrainDist, bestTrainDepo
    local tx, ty, tz = t.station.location.x, t.station.location.y, t.station.location.z
    for h, info in pairs(availableTrains) do
      local entry = info
      local train = entry.train
      local pos = entry.pos
      if train and pos and not busyTrains[h] then
        local dx, dy, dz = pos.x - tx, pos.y - ty, pos.z - tz
        local dist = dx*dx + dy*dy + dz*dz
        if not bestTrainDist or dist < bestTrainDist then
          bestTrainDist = dist
          bestTrain = train
          bestTrainHash = h
          bestTrainDepo = entry.depo
        end
      end
    end
    if not bestTrain then goto next_task end

    local tt = bestTrain:getTimeTable()
    if not tt then goto next_task end

    -- Устанавливаем маршрут: provider -> requester -> depo
    clearTimeTable(bestTrain)
    tt:addStop(0, bestProvider, { definition = 0, duration = 15, isDurationAndRule = false })
    tt:addStop(1, t.station,    { definition = 1, duration = 15, isDurationAndRule = true })
    tt:addStop(2, bestTrainDepo,{ definition = 0, duration = 15, isDurationAndRule = false })

    busyTrains[bestTrainHash] = true
    isBusy[bestTrainHash] = true
    isBusy[bestTrainDepo] = bestTrain
    local rid = matchedId
    stationAssignments[rid] = stationAssignments[rid] or {}
    stationAssignments[rid][bestTrainHash] = true
    trainAssignments[bestTrainHash] = rid
    t.assignedTrain = bestTrainHash

    -- Убираем из пула доступных
    availableTrains[bestTrainHash] = nil

    local tag = (t.priority == 2 and "[CRITICAL] ") or (t.priority == 1 and "[HIGH] ") or ""
    log("[TASK] " .. tag .. "Train " .. bestTrain:getName() ..
        ": " .. bestProvider.name .. " -> " .. t.station.name .. " -> " .. bestTrainDepo.name)

    ::next_task::
  end
end

-- -------------------------
--       ПРИБЫТИЯ
-- -------------------------
local function trackArrivals()
  for _, train in pairs(trains) do
    if train and train.hash and train.getTimeTable then
      local hash = train.hash
      if busyTrains[hash] then
        local tt = train:getTimeTable()
        if tt and tt.getCurrentStop and tt.getStop then
          local index = tt:getCurrentStop()
          if index >= 0 and index < tt.numStops then
            local stop = tt:getStop(index)
            if stop and stop.station then
              local sid = stop.station.id or stop.station.hash
              if not busyStations[sid] then
                log("[ARRIVAL] Train " .. train:getName() .. " arrived at " .. stop.station.name)
                busyStations[sid] = true
                isBusy[sid] = train
              end
            end
          end
        end
      end
    end
  end
end

-- -------------------------
--      РЕЛИЗ ПОЕЗДОВ
-- -------------------------
local function releaseTrains()
  for _, train in pairs(trains) do
    local th = train.hash
    if not busyTrains[th] then goto continue end

    local tt = train:getTimeTable()
    if not tt then
      log("[WARN] Train " .. train:getName() .. " has no timetable")
      goto continue
    end

    local index = tt:getCurrentStop()

    -- Поезд уезжает со станции -> удаляем предыдущую
    if index > 0 and tt.numStops > 1 then
      local prevStop = tt:getStop(0)
      if prevStop and prevStop.station then
        local sid = prevStop.station.id or prevStop.station.hash
        log("[MOVE] Train " .. train:getName() .. " leaves station " .. prevStop.station.name)
        tt:removeStop(0)
        tt:setCurrentStop(index - 1)
        busyStations[sid] = nil
        isBusy[sid] = nil

        -- Удаляем задачу, если станция была requester
        if stations.requesters[sid] then
          for i = #task, 1, -1 do
            local t = task[i]
            if t.assignedTrain == th then
              log("[TASK RELEASE] Remove task after leaving requester: " .. train:getName())
              tremove(task, i)
              break
            end
          end
        end
      end

    -- Завершение задачи в депо (последняя остановка)
    elseif tt.numStops == 1 then
      local stop = tt:getStop(0)
      if stop and stop.station then
        local sid = stop.station.id or stop.station.hash
        local isDepo = stations.depos[sid] ~= nil
        if isDepo and trainNearStation(train, stop.station, 100) then
          log("[COMPLETE] Train " .. train:getName() .. " finished and arrived to depo")

          busyTrains[th] = nil
          isBusy[th] = nil
          busyStations[sid] = nil
          isBusy[sid] = nil

          -- Инвалидация пустоты только для этого поезда
          trainEmptyCache[th] = nil

          -- Очистка назначений
          local rid = trainAssignments[th]
          if rid and stationAssignments[rid] then
            stationAssignments[rid][th] = nil
            if not next(stationAssignments[rid]) then
              stationAssignments[rid] = nil
            end
          end
          trainAssignments[th] = nil

          -- Удаляем завершённые задачи
          for i = #task, 1, -1 do
            local t = task[i]
            if t.assignedTrain == th then
              log("[TASK FINALIZE] Remove completed task of " .. train:getName())
              tremove(task, i)
            end
          end
        end
      end
    end

    -- Доп. очистка индексов
    do
      local sid = trainAssignments[th]
      if sid and stationAssignments[sid] then
        stationAssignments[sid][th] = nil
        if not next(stationAssignments[sid]) then
          stationAssignments[sid] = nil
        end
        log("[CLEANUP] Unlinked train " .. train:getName() .. " from stationAssignments[" .. tostring(sid) .. "]")
      end
      trainAssignments[th] = nil
    end

    ::continue::
  end
end

-- -------------------------
--        ГЛАВНЫЙ ЦИКЛ
-- -------------------------
local lastUpdateTime  = 0
local lastProcessTime = 0
local lastArrivalTime = 0
local lastReleaseTime = 0

-- интервалы
local updateInterval  = 40000
local processInterval = 7000
local arrivalInterval = 12000
local releaseInterval = 15000

while true do
  local now = computer.millis()

  -- сеть
  local e, _, from, recvPort, cmd, payload = event.pull(0.2)
  if e == "NetworkMessage" and recvPort == port then
    if cmd == "register" then handleRegister(from, payload) end
    if cmd == "status"   then handleStatusUpdate(from, payload) end
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
    lastReleaseTime = now
  end

  -- троттлинг перерисовки логов
  redrawLogsThrottled(now)
end
