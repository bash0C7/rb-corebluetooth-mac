# frozen_string_literal: true

module CoreBluetoothMac
  class Service
    attr_reader :uuid, :peripheral, :is_primary, :included_service_uuids

    def initialize(peripheral:, uuid:, is_primary:)
      @peripheral = peripheral
      @uuid = uuid
      @is_primary = is_primary
      @characteristics = nil
      @included_service_uuids = []
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
          properties: h["properties"].map(&:to_sym).to_set,
          initial_value: h["initial_value"] && [h["initial_value"]].pack("H*")
        )
      end
      self
    end

    def discover_included_services(timeout: 5.0)
      arr = @peripheral.central.__call_native(
        :service_discover_included_services,
        @peripheral.identifier, @uuid, (timeout * 1000).to_i
      )
      @included_service_uuids = arr.map { |h| h["uuid"] }
      arr.map do |h|
        Service.new(peripheral: @peripheral, uuid: h["uuid"], is_primary: h["is_primary"])
      end
    end

    def characteristics
      @characteristics || raise(Error.new("call discover_characteristics first", domain: :closed))
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
