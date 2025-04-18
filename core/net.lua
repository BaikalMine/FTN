net = computer.getPCIDevices(classes.NetworkCard)[1]
if not net then error("No network card found") end

port = 99
net:open(port)
event.listen(net)

computer.promote()
