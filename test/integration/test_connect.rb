# frozen_string_literal: true

require "test_helper"

class ConnectTest < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devices = @central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
    omit "No StackChan-PicoRuby visible; rake r2p2:reset on CoreS3 first." if devices.empty?
    @device = devices.first
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  rescue CoreBluetoothMac::Error
    # Already disconnected.
  end

  def test_connect_returns_Peripheral
    @peripheral = @central.connect(@device, timeout: 5.0)
    assert_kind_of CoreBluetoothMac::Peripheral, @peripheral
    assert_equal @device.identifier, @peripheral.identifier
  end

  def test_state_is_connected
    @peripheral = @central.connect(@device, timeout: 5.0)
    assert_equal :connected, @peripheral.state
  end

  def test_disconnect_then_state_is_disconnected
    @peripheral = @central.connect(@device, timeout: 5.0)
    @central.disconnect(@peripheral)
    # CoreBluetooth disconnect is async; poll briefly.
    deadline = Time.now + 2.0
    until @peripheral.state == :disconnected || Time.now > deadline
      sleep 0.05
    end
    assert_equal :disconnected, @peripheral.state
  end
end
