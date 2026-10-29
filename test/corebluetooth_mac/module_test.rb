# frozen_string_literal: true

require "test_helper"

class ModuleTest < Test::Unit::TestCase
  def test_VERSION_is_a_string
    assert_kind_of String, CoreBluetoothMac::VERSION
  end

  def test_VERSION_is_semver
    assert_match(/\A\d+\.\d+\.\d+(\.[a-z]\w*)?\z/, CoreBluetoothMac::VERSION)
  end

  def test_VERSION_is_0_2_1
    assert_equal "0.2.1", CoreBluetoothMac::VERSION
  end
end

class NativeBridgeTest < Test::Unit::TestCase
  def test_hello_module_function_present
    assert_respond_to CoreBluetoothMac, :__hello
  end

  def test_Native_alloc_creates_object
    assert defined?(CoreBluetoothMac::Native)
  end
end
