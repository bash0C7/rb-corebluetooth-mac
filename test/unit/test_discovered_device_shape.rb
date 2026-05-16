# frozen_string_literal: true

require "test_helper"

class TestDiscoveredDeviceShape < Test::Unit::TestCase
  def test_data_define_members
    expected = [:identifier, :name, :rssi, :tx_power_level, :connectable,
                :service_uuids, :service_data, :manufacturer_data,
                :solicited_service_uuids, :overflow_service_uuids, :central_id]
    assert_equal expected, CoreBluetoothMac::DiscoveredDevice.members
  end

  def test_construct_with_defaults
    d = CoreBluetoothMac::DiscoveredDevice.new(
      identifier: "abc", name: nil, rssi: -50,
      tx_power_level: nil, connectable: nil,
      service_uuids: [], service_data: {}, manufacturer_data: nil,
      solicited_service_uuids: [], overflow_service_uuids: [],
      central_id: "central-1",
    )
    assert_equal "abc", d.identifier
    assert_equal [], d.service_uuids
  end

  def test_no_old_4_field_shape
    # Sanity: ensure we removed the v0.2.0 4-field shape
    refute_equal 4, CoreBluetoothMac::DiscoveredDevice.members.size
  end
end
