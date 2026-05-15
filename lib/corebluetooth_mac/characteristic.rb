# frozen_string_literal: true

module CoreBluetoothMac
  class Characteristic
    attr_reader :uuid, :properties, :service

    def initialize(service:, uuid:, properties:)
      @service = service
      @uuid = uuid
      @properties = properties.frozen? ? properties : properties.freeze
    end

    def readable?
      @properties.include?(:read)
    end

    def writable?
      @properties.include?(:write) || @properties.include?(:write_without_response)
    end

    def notify?
      @properties.include?(:notify) || @properties.include?(:indicate)
    end

    def read(timeout: 5.0)
      central.__call_native(
        :characteristic_read,
        @service.peripheral.identifier, @service.uuid, @uuid,
        (timeout * 1000).to_i
      )
    end

    def write(data, response: true, timeout: 5.0)
      central.__call_native(
        :characteristic_write,
        @service.peripheral.identifier, @service.uuid, @uuid,
        data, response ? 1 : 0, response ? (timeout * 1000).to_i : 0
      )
    end

    def write_without_response(data)
      write(data, response: false, timeout: 0)
    end

    def subscribe
      sub_id = central.__call_native(
        :characteristic_subscribe,
        @service.peripheral.identifier, @service.uuid, @uuid
      )
      Subscription.new(central_id: central.central_id, subscription_id: sub_id)
    end

    def unsubscribe
      central.__call_native(
        :characteristic_unsubscribe,
        @service.peripheral.identifier, @service.uuid, @uuid
      )
    end

    private

    def central
      @service.peripheral.central
    end
  end
end
