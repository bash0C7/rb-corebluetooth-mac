# frozen_string_literal: true

require "test_helper"

class DiscoverTest < Test::Unit::TestCase
  GAP_SERVICE_UUID = "00001800-0000-1000-8000-00805f9b34fb"
  DEVICE_NAME_CHAR_UUID = "00002a00-0000-1000-8000-00805f9b34fb"

  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devices = @central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
    omit "No StackChan-PicoRuby visible." if devices.empty?
    @peripheral = @central.connect(devices.first, timeout: 5.0)
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  rescue CoreBluetoothMac::Error
  end

  def gap_service
    @peripheral.discover_services(timeout: 5.0)
    @peripheral.find_service(GAP_SERVICE_UUID) || omit("CoreBluetooth did not report the GAP service")
  end

  def test_discover_services_includes_GAP
    assert_equal GAP_SERVICE_UUID, CoreBluetoothMac.uuid_key(gap_service.uuid)
  end

  def test_discover_characteristics_includes_DeviceName
    gap = gap_service
    gap.discover_characteristics(timeout: 5.0)
    ch = gap.find_characteristic(DEVICE_NAME_CHAR_UUID)
    refute_nil ch, "Device Name characteristic missing"
    assert ch.supports?(:read)
  end
end
