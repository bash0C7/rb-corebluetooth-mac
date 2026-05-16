# frozen_string_literal: true

require_relative "../test_helper"

class DiscoverDescriptorsTest < Test::Unit::TestCase
  def setup
    HardwareGuard.skip_unless_hardware!(self)
    @central = CoreBluetoothMac::Central.new(state_timeout: 5.0)
    devs = @central.scan(timeout: 8.0)
    omit "no peripherals" if devs.empty?
    @peripheral = @central.connect(devs.first, timeout: 5.0)
    @peripheral.discover_services
    @peripheral.services.each(&:discover_characteristics)
  end

  def teardown
    @central&.disconnect(@peripheral) if @peripheral
  ensure
    @central = nil
  end

  def test_discover_descriptors_returns_array
    notify_ch = @peripheral.services.flat_map { |s| s.characteristics }.find { |c| c.supports?(:notify) }
    omit "no notify characteristic available" if notify_ch.nil?
    notify_ch.subscribe
    notify_ch.discover_descriptors(timeout: 5.0)
    assert_kind_of Array, notify_ch.descriptors
    notify_ch.descriptors.each { |d| assert_kind_of CoreBluetoothMac::Descriptor, d }
  ensure
    notify_ch&.unsubscribe if notify_ch
  end
end
