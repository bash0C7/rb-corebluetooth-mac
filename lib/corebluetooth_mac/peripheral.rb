# frozen_string_literal: true

module CoreBluetoothMac
  class Peripheral
    attr_reader :identifier, :central

    def initialize(central:, identifier:)
      @central = central
      @identifier = identifier
      @services = nil
    end

    def state
      @central.__call_native(:peripheral_state, @identifier)
    end

    def last_disconnect_error
      h = @central.__call_native(:peripheral_last_disconnect_error, @identifier)
      return nil if h.nil?
      Error.new(h["message"], domain: h["domain"].to_sym, code: h["code"], code_name: h["code_name"]&.to_sym)
    end

    # services: nil | String | [String]
    #   nil      → discover all services (CB default behaviour)
    #   String   → single UUID filter
    #   [String] → multi-UUID filter; empty array is treated as nil
    def discover_services(services: nil, timeout: 5.0)
      filter_json =
        case services
        when nil
          nil
        when String
          JSON.dump([services])
        when Array
          services.empty? ? nil : JSON.dump(services)
        else
          raise Error.new(
            "services must be nil, a UUID String, or an Array of UUID Strings",
            domain: :validation
          )
        end
      arr = @central.__call_native(
        :peripheral_discover_services, @identifier, filter_json, (timeout * 1000).to_i
      )
      @services = arr.map do |h|
        Service.new(peripheral: self, uuid: h["uuid"], is_primary: h["is_primary"])
      end
      self
    end

    def services
      @services || raise(Error.new("call discover_services first", domain: :discovery))
    end

    def find_service(uuid)
      target = uuid.downcase
      services.find { |s| s.uuid.casecmp?(target) }
    end

    def read_rssi(timeout: 5.0)
      @central.__call_native(:peripheral_read_rssi, @identifier, (timeout * 1000).to_i)
    end

    def max_write_length(response: true)
      @central.__call_native(:peripheral_max_write_length, @identifier, response ? 1 : 0)
    end

    # Drain one event from the per-peripheral event queue. Returns nil if no
    # event arrived within `timeout` seconds. Otherwise returns a
    # `CoreBluetoothMac::PeripheralEvent::*` Data instance.
    #
    # Events:
    #   NameUpdated(name:)            — peripheralDidUpdateName:
    #   ServicesInvalidated(uuids:)   — peripheral:didModifyServices:
    #   Disconnected(error:)          — centralManager:didDisconnectPeripheral:error:
    #
    # The queue is cumulative across polls; callers loop to drain.
    def poll_events(timeout: 0.0)
      json = @central.__call_native(:peripheral_poll_events, @identifier, (timeout * 1000).to_i)
      # `__call_native` returns the envelope `data` field, so `json` is either
      # nil (timeout / unknown peripheral) or `{"tag"=>..., "payload"=>...}`.
      return nil if json.nil?
      case json["tag"]
      when "name_updated"
        PeripheralEvent::NameUpdated.new(name: json["payload"]["name"])
      when "services_invalidated"
        PeripheralEvent::ServicesInvalidated.new(uuids: json["payload"]["uuids"])
      when "disconnected"
        err_payload = json["payload"]["error"]
        err = err_payload && Error.new(
          err_payload["message"],
          domain: err_payload["domain"].to_sym,
          code: err_payload["code"],
          code_name: err_payload["code_name"]&.to_sym
        )
        PeripheralEvent::Disconnected.new(error: err)
      else
        raise Error.new("unknown peripheral event tag: #{json["tag"].inspect}", domain: :validation)
      end
    end

    def find_characteristic(uuid)
      target = uuid.downcase
      (@services || []).each do |svc|
        next unless svc.characteristics_loaded?
        ch = svc.characteristics.find { |c| c.uuid.casecmp?(target) }
        return ch if ch
      end
      nil
    end
  end
end
