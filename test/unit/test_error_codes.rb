require_relative "../test_helper"

class TestErrorCodes < Test::Unit::TestCase
  def test_cb_lookup
    assert_equal :connection_timeout, CoreBluetoothMac::ErrorCodes.cb_name(6)
    assert_equal :peripheral_disconnected, CoreBluetoothMac::ErrorCodes.cb_name(7)
    assert_equal :unknown, CoreBluetoothMac::ErrorCodes.cb_name(0)
  end

  def test_cb_lookup_unknown_code_returns_nil
    assert_nil CoreBluetoothMac::ErrorCodes.cb_name(9999)
  end

  def test_att_lookup
    assert_equal :read_not_permitted, CoreBluetoothMac::ErrorCodes.att_name(0x02)
    assert_equal :write_not_permitted, CoreBluetoothMac::ErrorCodes.att_name(0x03)
    assert_equal :attribute_not_found, CoreBluetoothMac::ErrorCodes.att_name(0x0A)
  end

  def test_att_lookup_unknown
    assert_nil CoreBluetoothMac::ErrorCodes.att_name(0xFF)
  end
end
