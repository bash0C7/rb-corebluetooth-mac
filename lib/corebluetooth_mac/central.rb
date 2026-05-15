# frozen_string_literal: true

module CoreBluetoothMac
  class Central
    def initialize(state_timeout: 3.0)
      @native = Native.new((state_timeout * 1000).to_i)
    end

    def central_id
      @native.central_id
    end

    def scan(name: nil, services: nil, timeout: 5.0)
      # Empty `services: []` would serialize as "[]" and CoreBluetooth treats
      # an empty service-filter array as "match nothing", silently returning
      # zero peripherals. Normalize empty/nil to nil so Swift skips the filter.
      arr = services ? Array(services) : []
      services_json = arr.empty? ? nil : JSON.dump(arr)
      raw = @native.scan(name, services_json, (timeout * 1000).to_i)
      JSON.parse(raw).map do |h|
        DiscoveredDevice.new(
          central_id: central_id,
          identifier: h["identifier"],
          name: h["name"],
          rssi: h["rssi"]
        )
      end
    end
  end
end
