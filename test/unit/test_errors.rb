# frozen_string_literal: true

require "test_helper"

class ErrorsTest < Test::Unit::TestCase
  def test_Error_inherits_StandardError
    assert_operator CoreBluetoothMac::Error, :<, StandardError
  end

  def test_StateError_inherits_Error
    assert_operator CoreBluetoothMac::StateError, :<, CoreBluetoothMac::Error
  end

  def test_PermissionError_inherits_StateError
    assert_operator CoreBluetoothMac::PermissionError, :<, CoreBluetoothMac::StateError
  end

  def test_TimeoutError_inherits_Error
    assert_operator CoreBluetoothMac::TimeoutError, :<, CoreBluetoothMac::Error
  end

  def test_ConnectionError_inherits_Error
    assert_operator CoreBluetoothMac::ConnectionError, :<, CoreBluetoothMac::Error
  end

  def test_DiscoveryError_inherits_Error
    assert_operator CoreBluetoothMac::DiscoveryError, :<, CoreBluetoothMac::Error
  end

  def test_IOError_inherits_Error
    assert_operator CoreBluetoothMac::IOError, :<, CoreBluetoothMac::Error
  end

  def test_ClosedError_inherits_Error
    assert_operator CoreBluetoothMac::ClosedError, :<, CoreBluetoothMac::Error
  end
end

class CentralErrorBridgeTest < Test::Unit::TestCase
  # Verify the constants the C bridge looks up exist with the expected names.
  # The hardware behaviour itself is exercised in integration tests.
  CoreBluetoothMac.constants(false).each do |c|
    klass = CoreBluetoothMac.const_get(c)
    next unless klass.is_a?(Class) && klass < StandardError
    define_method("test_#{c}_is_raisable") do
      assert_raise(klass) { raise klass, "boom" }
    end
  end
end
