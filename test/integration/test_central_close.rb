# frozen_string_literal: true

require "test_helper"

# Central#close real teardown semantics.
#
# These tests instantiate a real CBCentralManager (the close path lives in the
# native bridge), so they ride BLE_HW=1 — without the adapter present
# `Central.new` would itself fail. The tests are not "hardware peripheral"
# dependent; they only need the local adapter.
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

  # Unknown identifier on poll_events must raise a validation error so callers
  # can distinguish "no event yet" (timeout) from "wrong identifier".
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
