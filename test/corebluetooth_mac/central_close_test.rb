# frozen_string_literal: true

require "test_helper"

class TestCentralClose < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
  end

  def test_close_is_idempotent
    central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    assert_nothing_raised { central.close }
    assert_nothing_raised { central.close }
  end

  def test_scan_after_close_raises
    central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    central.close
    err = assert_raise CoreBluetoothMac::Error do
      central.scan(timeout: 1.0)
    end
    assert_equal :closed, err.domain
  end

  def test_poll_events_unknown_identifier_raises
    central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    fake = CoreBluetoothMac::Peripheral.new(
      central: central,
      identifier: "00000000-0000-0000-0000-000000000000"
    )
    err = assert_raise CoreBluetoothMac::Error do
      fake.poll_events(timeout: 0.0)
    end
    assert_equal :validation, err.domain
  ensure
    central&.close
  end

  def test_poll_events_after_close_raises
    central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    fake = CoreBluetoothMac::Peripheral.new(
      central: central,
      identifier: "00000000-0000-0000-0000-000000000000"
    )
    central.close
    err = assert_raise CoreBluetoothMac::Error do
      fake.poll_events(timeout: 0.0)
    end
    assert_equal :closed, err.domain
  end
end
