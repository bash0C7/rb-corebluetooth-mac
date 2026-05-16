# frozen_string_literal: true

require "test_helper"

class ReadRssiTest < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devices = @central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
    omit "No StackChan-PicoRuby visible; rake r2p2:reset on CoreS3 first." if devices.empty?
    @peripheral = @central.connect(devices.first, timeout: 5.0)
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  ensure
    @central = nil
  end

  def test_read_rssi_returns_integer_in_range
    rssi = @peripheral.read_rssi(timeout: 5.0)
    assert_kind_of Integer, rssi
    assert_operator rssi, :<=, 0
    assert_operator rssi, :>=, -127
  end
end
