# frozen_string_literal: true

require_relative "../lib/corebluetooth_mac"

central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
puts "Scanning for 'StackChan-PicoRuby' for 8s…"
central.scan(name: "StackChan-PicoRuby", timeout: 8.0).each do |d|
  puts "  #{d.identifier}  rssi=#{d.rssi}  name=#{d.name}"
end
