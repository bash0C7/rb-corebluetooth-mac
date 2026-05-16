# frozen_string_literal: true

require "test_helper"

class TestScanAdvertisementData < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
  end

  def test_scan_returns_at_least_one_advertised_field
    devs = @central.scan(timeout: 5.0)
    omit "no peripherals visible" if devs.empty?
    sample = devs.first
    enriched = !sample.service_uuids.empty? ||
               !sample.manufacturer_data.nil? ||
               !sample.tx_power_level.nil? ||
               !sample.connectable.nil?
    assert enriched, "Expected at least one ad-data field populated, got: #{sample.inspect}"
  ensure
    @central&.close
  end
end
