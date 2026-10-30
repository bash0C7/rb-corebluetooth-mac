# frozen_string_literal: true

require "test_helper"

class SubscriptionValueTest < Test::Unit::TestCase
  def setup
    @sub = CoreBluetoothMac::Subscription.new(central_id: 1, subscription_id: 42)
  end

  def test_has_accessors
    assert_equal 1, @sub.central_id
    assert_equal 42, @sub.subscription_id
  end

  def test_equal_when_fields_equal
    other = CoreBluetoothMac::Subscription.new(central_id: 1, subscription_id: 42)
    assert_equal @sub, other
  end

  def test_is_ractor_shareable
    assert Ractor.shareable?(@sub), "Subscription must be Ractor.shareable?"
  end
end
