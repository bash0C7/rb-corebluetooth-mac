# frozen_string_literal: true

require_relative "../lib/corebluetooth_mac"

NUS_TX_CHAR = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
devs = central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
abort "no peripheral" if devs.empty?
p = central.connect(devs.first, timeout: 5.0)
p.discover_services
p.services.each(&:discover_characteristics)
tx = p.find_characteristic(NUS_TX_CHAR) || abort("NUS TX missing")

sub = tx.subscribe
puts "Subscribed (id=#{sub.subscription_id}). Pumping in Ractor for 10s…"

pump = Ractor.new(sub) do |s|
  results = []
  10.times do
    v = s.next_value(timeout: 1.0)
    break if v.nil?
    results << v
    Ractor.yield v.bytes.inspect
  end
  results.size
end

10.times do
  begin
    msg = pump.take
    puts "RX: #{msg}"
  rescue Ractor::ClosedError
    break
  end
end

tx.unsubscribe
central.disconnect(p)
puts "Done."
