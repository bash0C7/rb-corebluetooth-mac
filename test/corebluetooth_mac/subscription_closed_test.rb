# frozen_string_literal: true

require "test_helper"

class TestSubscriptionClosed < Test::Unit::TestCase
  UNREGISTERED_SUB_ID = (1 << 60)

  def test_ffi_returns_closed_symbol_for_unknown_subscription
    r = CoreBluetoothMac.__subscription_next_value(0, UNREGISTERED_SUB_ID, 0)
    assert_equal :closed, r,
      "C bridge must surface drained-and-closed as `:closed` (got #{r.inspect})"
  end

  def test_next_value_returns_false_when_subscription_closed
    sub = CoreBluetoothMac::Subscription.new(
      central_id: 0,
      subscription_id: UNREGISTERED_SUB_ID
    )
    r = sub.next_value(timeout: 0.0)
    assert_equal false, r,
      "Subscription#next_value must translate :closed to false (got #{r.inspect})"
  end

  def test_next_value_runs_inside_a_ractor
    sub = CoreBluetoothMac::Subscription.new(central_id: 0, subscription_id: UNREGISTERED_SUB_ID)
    assert_equal false, Ractor.new(sub) { |s| s.next_value(timeout: 0.0) }.value
  end

  def test_close_is_idempotent_for_unknown_subscription
    assert_nothing_raised do
      CoreBluetoothMac.__subscription_close(0, UNREGISTERED_SUB_ID)
    end
  end
end
