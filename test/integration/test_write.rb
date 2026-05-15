# frozen_string_literal: true

require "test_helper"

class WriteTest < Test::Unit::TestCase
  NUS_RX_CHAR = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"

  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devices = @central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
    omit "No StackChan-PicoRuby visible." if devices.empty?
    @peripheral = @central.connect(devices.first, timeout: 5.0)
    @peripheral.discover_services
    @peripheral.services.each(&:discover_characteristics)
    @rx = @peripheral.find_characteristic(NUS_RX_CHAR)
    omit "NUS RX characteristic not present (CoreS3 Phase 2 not deployed yet)." unless @rx
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  rescue CoreBluetoothMac::Error
  end

  def test_write_with_response
    @rx.write("ping\n", response: true, timeout: 5.0)
    pass "write completed without raising"
  end

  def test_write_without_response
    @rx.write_without_response("hi\n")
    pass "write_without_response returned cleanly"
  end
end
