# frozen_string_literal: true

require "test_helper"

class TestDiscoverIncludedServices < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
  end

  def test_discover_included_services_returns_array
    central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devs = central.scan(timeout: 8.0)
    omit "no peripherals" if devs.empty?
    p = central.connect(devs.first, timeout: 5.0)
    p.discover_services
    svc = p.services.first
    included = svc.discover_included_services(timeout: 5.0)
    assert_kind_of Array, included
    included.each { |s| assert_kind_of CoreBluetoothMac::Service, s }
  ensure
    central&.close
  end
end
