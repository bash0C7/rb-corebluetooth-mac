# frozen_string_literal: true

require "test_helper"

class TestPeripheralEvents < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
  end

  def test_poll_events_drains_disconnect
    central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    p = central.connect(HardwareGuard.target(self, central), timeout: 5.0)
    central.disconnect(p)
    ev = p.poll_events(timeout: 5.0)
    assert_kind_of CoreBluetoothMac::PeripheralEvent::Disconnected, ev
    assert_nil ev.error, "clean disconnect should carry nil error"
  ensure
    central&.close
  end
end
