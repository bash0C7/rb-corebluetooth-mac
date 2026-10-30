# frozen_string_literal: true

require_relative "../test_helper"

class TestErrorClass < Test::Unit::TestCase
  def test_initialize_with_domain_only
    e = CoreBluetoothMac::Error.new("oops", domain: :timeout)
    assert_equal :timeout, e.domain
    assert_nil e.code
    assert_nil e.code_name
    assert_equal "oops", e.message
  end

  def test_initialize_with_cb_domain_carries_code
    e = CoreBluetoothMac::Error.new("conn timeout", domain: :cb, code: 6, code_name: :connection_timeout)
    assert_equal :cb, e.domain
    assert_equal 6, e.code
    assert_equal :connection_timeout, e.code_name
  end

  def test_old_subclasses_removed
    refute defined?(CoreBluetoothMac::TimeoutError)
    refute defined?(CoreBluetoothMac::ClosedError)
    refute defined?(CoreBluetoothMac::ConnectionError)
    refute defined?(CoreBluetoothMac::DiscoveryError)
  end

  def test_inherits_from_standard_error
    assert_operator CoreBluetoothMac::Error, :<, StandardError
  end
end
