# frozen_string_literal: true

require_relative "../test_helper"

# Unit tests for the closed-vs-timeout contract of
# `CoreBluetoothMac::Subscription#next_value`.
#
# Contract (v0.2.x):
#   * String — notification payload
#   * nil    — timeout (entry exists, no value within window)
#   * false  — entry is closed/drained (terminal); use this to break loops
#
# The C bridge returns the symbol `:closed` for the terminal state and the
# Ruby wrapper translates that to `false`. We exercise both layers here
# without requiring real BLE hardware: an unregistered (or never-allocated)
# subscription id is treated by the Swift `CBMSubscriptionRegistry.dequeue`
# as "closed" (no entry → `(nil, closed: true)`), which surfaces the same
# code path that an `unsubscribe`/`purgeAll` produces.
class TestSubscriptionClosed < Test::Unit::TestCase
  # Pick an id that's astronomically unlikely to collide with a real
  # registered subscription (`idCounter` starts at 0 and increments).
  UNREGISTERED_SUB_ID = (1 << 60)

  def test_ffi_returns_closed_symbol_for_unknown_subscription
    # Direct FFI call: skips the Ruby wrapper so we can pin the symbol contract.
    r = CoreBluetoothMac.__subscription_next_value(
      0,                    # central_id (unused by current FFI)
      UNREGISTERED_SUB_ID,
      0                     # timeout_ms — closed branch wins before any wait
    )
    assert_equal :closed, r,
      "C bridge must surface drained-and-closed as `:closed` (got #{r.inspect})"
  end

  def test_next_value_returns_false_when_subscription_closed
    sub = CoreBluetoothMac::Subscription.new(
      central_id: 0,
      subscription_id: UNREGISTERED_SUB_ID
    )
    # Tight timeout — closed path short-circuits before any wait anyway, but
    # we keep this small so the test stays fast even if behavior regresses.
    r = sub.next_value(timeout: 0.0)
    assert_equal false, r,
      "Subscription#next_value must translate :closed to false (got #{r.inspect})"
  end

  def test_close_is_idempotent_for_unknown_subscription
    # Closing an unknown id must not raise; registry treats it as a no-op.
    assert_nothing_raised do
      CoreBluetoothMac.__subscription_close(0, UNREGISTERED_SUB_ID)
    end
  end
end
