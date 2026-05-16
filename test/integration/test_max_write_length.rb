# frozen_string_literal: true

require "test_helper"

class MaxWriteLengthTest < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devs = @central.scan(timeout: 8.0)
    omit "no peripherals" if devs.empty?
    @peripheral = @central.connect(devs.first, timeout: 5.0)
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  ensure
    @central = nil
  end

  def test_with_response_returns_positive_integer
    n = @peripheral.max_write_length(response: true)
    assert_kind_of Integer, n
    assert_operator n, :>, 0
  end

  def test_without_response_returns_positive_integer
    n = @peripheral.max_write_length(response: false)
    assert_kind_of Integer, n
    assert_operator n, :>, 0
  end
end
