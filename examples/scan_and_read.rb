# frozen_string_literal: true

require_relative "../lib/corebluetooth_mac"

GAP_SERVICE       = "00001800-0000-1000-8000-00805f9b34fb"
DEVICE_NAME_CHAR  = "00002a00-0000-1000-8000-00805f9b34fb"

central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
puts "Scanning…"
devs = central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
abort "Not found. `rake r2p2:reset` on CoreS3 to reopen its 60s window." if devs.empty?

dev = devs.first
puts "Found #{dev.identifier} rssi=#{dev.rssi}"
p = central.connect(dev, timeout: 5.0)
puts "Connected. State=#{p.state}"

p.discover_services
gap = p.find_service(GAP_SERVICE) || abort("GAP service missing")
gap.discover_characteristics
ch = gap.find_characteristic(DEVICE_NAME_CHAR) || abort("Device Name characteristic missing")
puts "Device Name = #{ch.read(timeout: 5.0).force_encoding('UTF-8').inspect}"

central.disconnect(p)
puts "Disconnected. State=#{p.state}"
