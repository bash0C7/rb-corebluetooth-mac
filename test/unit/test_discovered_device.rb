# frozen_string_literal: true

require "test_helper"

class DiscoveredDeviceTest < Test::Unit::TestCase
  def setup
    @dev = CoreBluetoothMac::DiscoveredDevice.new(
      central_id: 1, identifier: "ABCD", name: "StackChan-PicoRuby", rssi: -42
    )
  end

  def test_has_accessors
    assert_equal 1, @dev.central_id
    assert_equal "ABCD", @dev.identifier
    assert_equal "StackChan-PicoRuby", @dev.name
    assert_equal(-42, @dev.rssi)
  end

  def test_equal_when_all_fields_equal
    other = CoreBluetoothMac::DiscoveredDevice.new(
      central_id: 1, identifier: "ABCD", name: "StackChan-PicoRuby", rssi: -42
    )
    assert_equal @dev, other
  end

  def test_not_equal_when_identifier_differs
    other = CoreBluetoothMac::DiscoveredDevice.new(
      central_id: 1, identifier: "WXYZ", name: "StackChan-PicoRuby", rssi: -42
    )
    refute_equal @dev, other
  end

  def test_is_ractor_shareable
    assert Ractor.shareable?(@dev), "DiscoveredDevice must be Ractor.shareable?"
  end
end
