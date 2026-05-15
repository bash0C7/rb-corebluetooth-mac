# frozen_string_literal: true

require "test_helper"

class ScanTest < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
  end

  def test_scan_returns_array
    result = @central.scan(timeout: 1.0)
    assert_kind_of Array, result
  end

  def test_scan_finds_stackchan_picoruby
    result = @central.scan(name: "StackChan-PicoRuby", timeout: 8.0)
    assert_operator result.size, :>=, 1,
      "Expected ≥1 StackChan-PicoRuby. Is CoreS3 advertising? `rake r2p2:reset` opens a 60s window."
    dev = result.first
    assert_kind_of CoreBluetoothMac::DiscoveredDevice, dev
    assert_equal "StackChan-PicoRuby", dev.name
    assert_match(/\A[0-9A-Fa-f-]+\z/, dev.identifier)
  end
end
