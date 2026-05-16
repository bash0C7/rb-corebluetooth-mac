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
      @services || raise(Error.new("call discover_services first", domain: :closed))
    end

    def find_service(uuid)
      target = uuid.downcase
      services.find { |s| s.uuid.casecmp?(target) }
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
