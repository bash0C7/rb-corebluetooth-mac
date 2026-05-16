# frozen_string_literal: true

require_relative "../test_helper"

class TestJsonEnvelope < Test::Unit::TestCase
  def test_scan_timeout_zero_returns_empty_or_timeout_error
    central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    result = central.scan(timeout: 0.0)
    assert_kind_of Array, result
  rescue CoreBluetoothMac::Error => e
    assert_includes [:timeout, :closed], e.domain
  ensure
    central&.close rescue nil
  end
end
