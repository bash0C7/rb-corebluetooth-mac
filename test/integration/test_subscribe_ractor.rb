# frozen_string_literal: true

require "test_helper"

class SubscribeRactorTest < Test::Unit::TestCase
  NUS_TX_CHAR = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devices = @central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
    omit "No StackChan-PicoRuby visible." if devices.empty?
    @peripheral = @central.connect(devices.first, timeout: 5.0)
    @peripheral.discover_services
    @peripheral.services.each(&:discover_characteristics)
    @tx = @peripheral.find_characteristic(NUS_TX_CHAR)
    omit "NUS TX characteristic not present." unless @tx
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  rescue CoreBluetoothMac::Error
  end

  def test_subscription_crosses_ractor_boundary
    sub = @tx.subscribe
    assert Ractor.shareable?(sub)

    pump = Ractor.new(sub) do |s|
      data = s.next_value(timeout: 0.3)
      data  # may be nil if no notification arrives within window — accept either
    end
    result = pump.take
    assert(result.nil? || result.is_a?(String))
    @tx.unsubscribe
  end
end
