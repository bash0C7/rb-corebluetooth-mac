# frozen_string_literal: true

require "test_helper"

class ReadGAPDeviceNameTest < Test::Unit::TestCase
  GAP_SERVICE_UUID      = "00001800-0000-1000-8000-00805f9b34fb"
  DEVICE_NAME_CHAR_UUID = "00002a00-0000-1000-8000-00805f9b34fb"
  EXPECTED_NAME         = "StackChan-PicoRuby"

  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devices = @central.scan(name: EXPECTED_NAME, timeout: 8.0)
    omit "No #{EXPECTED_NAME} visible." if devices.empty?
    @peripheral = @central.connect(devices.first, timeout: 5.0)
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  rescue CoreBluetoothMac::Error
  end

  def test_phase1_success_criterion
    @peripheral.discover_services
    gap = @peripheral.find_service(GAP_SERVICE_UUID)
    refute_nil gap
    gap.discover_characteristics
    ch = gap.find_characteristic(DEVICE_NAME_CHAR_UUID)
    refute_nil ch
    bytes = ch.read(timeout: 5.0)
    assert_equal Encoding::ASCII_8BIT, bytes.encoding
    assert_equal EXPECTED_NAME, bytes.force_encoding("UTF-8")
  end
end
