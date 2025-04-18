fs = filesystem;
fs.initFileSystem("/dev");

fs.mount("/dev/B7CF43F341A860DB27E5E4A9A199D101/","/")
fs.doFile("/util/vector.lua")
fs.doFile("/util/color.lua")
fs.doFile("/core/net.lua")
fs.doFile("/core/log.lua")
fs.doFile("/core/train.lua")
fs.doFile("/core/tasks.lua")
fs.doFile("/core/handlers.lua")
fs.doFile("/core/state.lua")

gpu = computer.getPCIDevices(classes.GPU_T2_C)[1]
if not gpu then computer.panic("❌ GPU не найден") end

local screens = component.findComponent(classes.Screen)
if #screens == 0 then computer.panic("❌ Экран не найден") end

local screen = component.proxy(screens[1])
gpu:bindScreen(screen)
screenSize = gpu:getScreenSize()

stations = {requesters = {}, providers = {}, depos = {}}
trains = {}
trainDepo = {}
isBusy = {}
task = {}
clients = {}
trainAssignments = {}
stationAssignments = {}

lastUpdateTime = 0
lastProcessTime = 0
lastArrivalTime = 0
lastReleaseTime = 0

updateInterval = 30000
processInterval = 5000
arrivalInterval = 10000
releaseInterval = 15000

log("[INIT] FTN Server запущен. Ожидание клиентов на порту: " .. port)

while true do
    local now = computer.millis()
    local e, _, from, recvPort, cmd, payload = event.pull(0.2)
    if e == "NetworkMessage" and recvPort == port then
        if cmd == "register" then HandleRegister(from, payload) end
        if cmd == "status" then HandleStatusUpdate(from, payload) end
    end
    if now - lastUpdateTime >= updateInterval then UpdateTrainNetwork(); lastUpdateTime = now end
    if now - lastProcessTime >= processInterval then ProcessTasks(); lastProcessTime = now end
    if now - lastArrivalTime >= arrivalInterval then TrackArrivals(); lastArrivalTime = now end
    if now - lastReleaseTime >= releaseInterval then ReleaseTrains(); ResetTrainEmptyCache(); lastReleaseTime = now end
end
