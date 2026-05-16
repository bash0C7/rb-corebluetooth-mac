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
      # C bridge parses the JSON envelope and returns the unwrapped data array.
      raw = @native.scan(name, services_json, (timeout * 1000).to_i)
      raw.map do |h|
        DiscoveredDevice.new(
          identifier: h["identifier"],
          name: h["name"],
          rssi: h["rssi"],
          tx_power_level: h["tx_power_level"],
          connectable: h["connectable"],
          service_uuids: (h["service_uuids"] || []).freeze,
          service_data: build_service_data(h["service_data"]),
          manufacturer_data: unhex(h["manufacturer_data"]),
          solicited_service_uuids: (h["solicited_service_uuids"] || []).freeze,
          overflow_service_uuids: (h["overflow_service_uuids"] || []).freeze,
          central_id: central_id,
        )
      end
    end

    def connect(device, timeout: 5.0)
      @native.connect(device.identifier, (timeout * 1000).to_i)
      Peripheral.new(central: self, identifier: device.identifier)
    end

    def disconnect(peripheral)
      @native.disconnect(peripheral.identifier)
      nil
    end

    def close
      # Future task: explicit invalidation; relying on GC for now.
      nil
    end

    def __call_native(op, *args)
      case op
      when :peripheral_state
        @native.peripheral_state(*args)
      when :peripheral_last_disconnect_error
        @native.peripheral_last_disconnect_error(*args)
      when :peripheral_read_rssi
        @native.peripheral_read_rssi(*args)
      when :peripheral_max_write_length
        @native.peripheral_max_write_length(*args)
      when :peripheral_discover_services
        # args: (identifier, services_filter_json_or_nil, timeout_ms)
        # C bridge returns the already-parsed array of `{uuid, is_primary}` hashes.
        @native.discover_services(*args)
      when :service_discover_characteristics
        # C bridge returns the already-parsed array of characteristic hashes.
        @native.discover_characteristics(*args)
      when :service_discover_included_services
        # C bridge returns the already-parsed array of {uuid, is_primary} hashes.
        @native.discover_included_services(*args)
      when :characteristic_read
        @native.characteristic_read(*args)
      when :characteristic_write
        @native.characteristic_write(*args)
      when :characteristic_subscribe
        @native.characteristic_subscribe(args[0], args[1], args[2], 5000)  # 5s default subscribe timeout
      when :characteristic_unsubscribe
        @native.characteristic_unsubscribe(args[0], args[1], args[2], 5000)
      when :characteristic_discover_descriptors
        # args: (identifier, service_uuid, char_uuid, timeout_ms)
        @native.characteristic_discover_descriptors(*args)
      when :descriptor_read
        # args: (identifier, service_uuid, char_uuid, desc_uuid, timeout_ms)
        @native.descriptor_read(*args)
      when :descriptor_write
        # args: (identifier, service_uuid, char_uuid, desc_uuid, data, timeout_ms)
        @native.descriptor_write(*args)
      else
        raise ArgumentError, "unknown native op: #{op}"
      end
    end

    private

    # Decode a hex string (e.g. "0a1b2c") into a binary ASCII-8BIT String.
    # Returns nil for nil input. Used for `manufacturer_data` and each value
    # of `service_data` (which arrive from Swift as lowercase hex).
    # The result is frozen so DiscoveredDevice instances stay Ractor.shareable
    # when populated with non-empty ad-data.
    def unhex(h)
      return nil if h.nil?
      [h].pack("H*").force_encoding(Encoding::ASCII_8BIT).freeze
    end

    def build_service_data(raw)
      return {}.freeze if raw.nil? || raw.empty?
      out = {}
      raw.each { |uuid, hex| out[uuid] = unhex(hex) }
      out.freeze
    end
  end
end
