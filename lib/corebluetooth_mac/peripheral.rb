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

    def discover_services(timeout: 5.0)
      uuids = @central.__call_native(
        :peripheral_discover_services, @identifier, (timeout * 1000).to_i
      )
      @services = uuids.map { |u| Service.new(peripheral: self, uuid: u) }
      self
    end

    def services
      @services || raise(ClosedError, "call discover_services first")
    end

    def find_service(uuid)
      target = uuid.downcase
      services.find { |s| s.uuid.casecmp?(target) }
    end

    def find_characteristic(uuid)
      target = uuid.downcase
      (services || []).each do |svc|
        next unless svc.characteristics_loaded?
        ch = svc.characteristics.find { |c| c.uuid.casecmp?(target) }
        return ch if ch
      end
      nil
    end
  end
end
