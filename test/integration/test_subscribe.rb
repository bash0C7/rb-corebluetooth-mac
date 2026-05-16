# frozen_string_literal: true

require "test_helper"

class SubscribeTest < Test::Unit::TestCase
  NUS_TX_CHAR = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devices = @central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
    omit "No StackChan-PicoRuby visible." if devices.empty?
    @peripheral = @central.connect(devices.first, timeout: 5.0)
    @peripheral.discover_services
    @peripheral.services.each(&:discover_characteristics)
    @tx = @peripheral.find_characteristic(NUS_TX_CHAR)
    omit "NUS TX characteristic not present (CoreS3 Phase 2 not deployed yet)." unless @tx
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  rescue CoreBluetoothMac::Error
  end

  def test_subscribe_returns_subscription
    sub = @tx.subscribe
    assert_kind_of CoreBluetoothMac::Subscription, sub
    assert_operator sub.subscription_id, :>, 0
    @tx.unsubscribe
  end

  def test_next_value_timeout_returns_nil
    sub = @tx.subscribe
    assert_nil sub.next_value(timeout: 0.2)
    @tx.unsubscribe
  end

  def test_unsubscribe_wakes_pending_next_value
    sub = @tx.subscribe
    th = Thread.new { sub.next_value(timeout: 5.0) }
    sleep 0.1
    @tx.unsubscribe
    # Unsubscribe purges the subscription registry entry; next_value sees the
    # entry as "drained-and-closed" and returns `false` per the v0.2.x contract.
    assert_equal false, th.value
  end
end
