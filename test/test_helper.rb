# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "test/unit"
require "corebluetooth_mac"

module HardwareGuard
  def self.skip_unless_hardware!(test)
    return if ENV["BLE_HW"] == "1"
    test.omit "Set BLE_HW=1 with a CoreS3 advertising StackChan-PicoRuby nearby"
  end
end
