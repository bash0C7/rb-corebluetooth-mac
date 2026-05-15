# frozen_string_literal: true

module CoreBluetoothMac
  class Service
    attr_reader :uuid, :peripheral

    def initialize(peripheral:, uuid:)
      @peripheral = peripheral
      @uuid = uuid
      @characteristics = nil
    end

    def discover_characteristics(timeout: 5.0)
      arr = @peripheral.central.__call_native(
        :service_discover_characteristics,
        @peripheral.identifier, @uuid, (timeout * 1000).to_i
      )
      @characteristics = arr.map do |h|
        Characteristic.new(
          service: self,
          uuid: h["uuid"],
          properties: h["properties"].map(&:to_sym).to_set
        )
      end
      self
    end

    def characteristics
      @characteristics || raise(ClosedError, "call discover_characteristics first")
    end

    def characteristics_loaded?
      !@characteristics.nil?
    end

    def find_characteristic(uuid)
      target = uuid.downcase
      characteristics.find { |c| c.uuid.casecmp?(target) }
    end
  end
end
