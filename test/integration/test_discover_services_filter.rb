# frozen_string_literal: true

require "test_helper"

class TestDiscoverServicesFilter < Test::Unit::TestCase
  GAP_SERVICE_SHORT = "1800"
  GAP_SERVICE_FULL  = "00001800-0000-1000-8000-00805f9b34fb"

  def setup
    HardwareGuard.skip_unless_hardware!(self)
  end

  # discover_services(services: "1800") should never return MORE services than
  # the unfiltered call, and when it returns any, every UUID must equal the GAP
  # service UUID (case-insensitive, accepting either short or canonical form).
  def test_filter_returns_only_requested_service
    central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devs = central.scan(timeout: 8.0)
    omit "no peripherals" if devs.empty?
    p = central.connect(devs.first, timeout: 5.0)

    # Baseline: unfiltered discovery.
    p.discover_services(timeout: 5.0)
    unfiltered_count = p.services.size

    # Filtered discovery for the GAP service only.
    p.discover_services(services: GAP_SERVICE_SHORT, timeout: 5.0)
    filtered = p.services

    assert filtered.size <= unfiltered_count,
      "filter must not return more services than unfiltered (#{filtered.size} > #{unfiltered_count})"

    omit "GAP service not advertised by peripheral" if filtered.empty?

    assert_equal 1, filtered.size, "filter should return at most one service for a single UUID"
    uuid = filtered.first.uuid.to_s
    assert(
      uuid.casecmp?(GAP_SERVICE_SHORT) || uuid.casecmp?(GAP_SERVICE_FULL),
      "expected GAP UUID (#{GAP_SERVICE_SHORT} or #{GAP_SERVICE_FULL}), got #{uuid.inspect}"
    )
  ensure
    central&.close
  end
end
