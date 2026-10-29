# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "corebluetooth_mac"

require "test-unit"

module HardwareGuard
  def self.skip_unless_hardware!(test)
    return if ENV["BLE_HW"] == "1"
    test.omit "Set BLE_HW=1 on a Mac with Bluetooth on and permitted"
  end

  def self.central_or_omit(test)
    CoreBluetoothMac::Central.new(state_timeout: 5.0)
  rescue CoreBluetoothMac::Error => e
    test.omit "Bluetooth adapter unavailable: [#{e.domain}] #{e.message}"
  end

  def self.target(test, central)
    name = ENV["BLE_TARGET_NAME"]
    test.omit "Set BLE_TARGET_NAME to the advertised name of a peripheral you own" if name.nil? || name.empty?
    device = central.scan(timeout: 8.0)
                    .select { |d| d.name == name || d.name&.start_with?(name) }
                    .max_by(&:rssi)
    test.omit "no peripheral named #{name.inspect} advertising" unless device
    device
  end
end
