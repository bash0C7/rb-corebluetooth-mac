# frozen_string_literal: true

require "test_helper"

class TestPeripheralEvents < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
  end

  # Drains a `disconnected` event after an explicit central.disconnect.
  # Verifies the Swift event queue → C bridge → Ruby Data plumbing end-to-end.
  def test_poll_events_drains_disconnect
    central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devs = central.scan(timeout: 8.0)
    omit "no peripherals" if devs.empty?
    p = central.connect(devs.first, timeout: 5.0)
    central.disconnect(p)
    ev = p.poll_events(timeout: 5.0)
    assert_kind_of CoreBluetoothMac::PeripheralEvent::Disconnected, ev
  ensure
    central&.close
  end
end
