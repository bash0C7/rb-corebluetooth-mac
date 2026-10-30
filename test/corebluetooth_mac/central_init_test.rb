# frozen_string_literal: true

require "test_helper"

class CentralInitTest < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
  end

  def test_new_returns_central_with_id
    central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    assert_kind_of Integer, central.central_id
    assert_operator central.central_id, :>, 0
  end
end
