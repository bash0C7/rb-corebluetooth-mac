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

  def test_discover_services_includes_GAP
    @peripheral.discover_services(timeout: 5.0)
    uuids = @peripheral.services.map(&:uuid)
    assert_includes uuids, GAP_SERVICE_UUID
  end

  def test_discover_characteristics_includes_DeviceName
    @peripheral.discover_services
    gap = @peripheral.find_service(GAP_SERVICE_UUID)
    refute_nil gap, "Generic Access service missing"
    gap.discover_characteristics(timeout: 5.0)
    uuids = gap.characteristics.map(&:uuid)
    assert_includes uuids, DEVICE_NAME_CHAR_UUID
    ch = gap.find_characteristic(DEVICE_NAME_CHAR_UUID)
    assert ch.readable?
  end
end
