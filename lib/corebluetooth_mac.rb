# frozen_string_literal: true

require "json"

module CoreBluetoothMac
  BASE_UUID_SUFFIX = "-0000-1000-8000-00805f9b34fb"

  def self.uuid_key(uuid)
    u = uuid.downcase
    case u.size
    when 4 then "0000#{u}#{BASE_UUID_SUFFIX}"
    when 8 then "#{u}#{BASE_UUID_SUFFIX}"
    else u
    end
  end
end

require_relative "corebluetooth_mac/version"
require_relative "corebluetooth_mac/errors"
require_relative "corebluetooth_mac/error_codes"

require_relative "corebluetooth_mac/discovered_device"
require_relative "corebluetooth_mac/subscription"
require_relative "corebluetooth_mac/service"
require_relative "corebluetooth_mac/characteristic"
require_relative "corebluetooth_mac/descriptor"
require_relative "corebluetooth_mac/peripheral_event"
require_relative "corebluetooth_mac/peripheral"
require_relative "corebluetooth_mac/corebluetooth_mac"
require_relative "corebluetooth_mac/central"
