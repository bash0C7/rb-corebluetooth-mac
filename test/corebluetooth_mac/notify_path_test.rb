# frozen_string_literal: true

require "test_helper"

class NotifyPathTest < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
    service_uuid = ENV["BLE_TARGET_SERVICE"]
    omit "Set BLE_TARGET_SERVICE to the service UUID test/support/virtual_peripheral.swift prints" if service_uuid.nil? || service_uuid.empty?
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    device = @central.scan(services: service_uuid, timeout: 8.0).max_by(&:rssi)
    omit "no peripheral advertising service #{service_uuid}" unless device
    @peripheral = @central.connect(device, timeout: 5.0)
    @peripheral.discover_services(services: service_uuid, timeout: 5.0)
    service = @peripheral.find_service(service_uuid).discover_characteristics
    @notify = service.characteristics.find { _1.supports?(:notify) }
    @rw = service.characteristics.find { _1.supports?(:write) }
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  ensure
    @central&.close
  end

  def test_write_then_read_returns_the_written_bytes
    data = Random.bytes(8)
    @rw.write(data, response: true)
    assert_equal data, @rw.read
  end

  def test_notifications_carry_consecutive_sequence_payloads
    sub = @notify.subscribe
    values = Array.new(10) { sub.next_value(timeout: 2.0) }
    first = values.first.unpack("CCN").last
    assert_equal Array.new(10) { payload(first + _1) }, values
  ensure
    @notify.unsubscribe
  end

  def test_interrupt_while_subscribed_returns_at_once_and_session_stays_usable
    sub = @notify.subscribe
    th = Thread.new do
      Thread.current.report_on_exception = false
      loop { sub.next_value(timeout: 10.0) }
    end
    sleep 0.5
    started = now
    th.raise(Interrupt)
    assert_raise(Interrupt) { th.value }
    assert_operator now - started, :<, 1.0
    assert_kind_of String, sub.next_value(timeout: 2.0)
    data = Random.bytes(4)
    @rw.write(data, response: true)
    assert_equal data, @rw.read
  ensure
    @notify.unsubscribe
  end

  def test_unsubscribe_closes_the_subscription
    sub = @notify.subscribe
    assert_kind_of String, sub.next_value(timeout: 2.0)
    @notify.unsubscribe
    assert_equal false, sub.next_value(timeout: 0.5)
  end

  def test_calls_after_disconnect_raise_connection_errors
    @central.disconnect(@peripheral)
    deadline = now + 5.0
    sleep 0.05 until @peripheral.state == :disconnected || now > deadline
    assert_equal :disconnected, @peripheral.state
    [-> { @rw.read }, -> { @rw.write("x") }, -> { @notify.subscribe }, -> { @notify.unsubscribe }].each do |call|
      assert_equal :connection, assert_raise(CoreBluetoothMac::Error, &call).domain
    end
  end

  private

  def payload(seq)
    [0xA5, 0x5A, seq].pack("CCN")
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
