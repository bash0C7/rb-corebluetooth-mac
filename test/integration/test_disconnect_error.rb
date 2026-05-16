# frozen_string_literal: true

require "test_helper"

class TestDisconnectError < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
  end

  def test_clean_disconnect_has_nil_error
    central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devs = central.scan(timeout: 8.0)
    omit "no peripherals" if devs.empty?
    p = central.connect(devs.first, timeout: 5.0)
    central.disconnect(p)
    sleep 0.2  # give delegate callback time to fire
    assert_nil p.last_disconnect_error
  ensure
    central&.close
  end
end
