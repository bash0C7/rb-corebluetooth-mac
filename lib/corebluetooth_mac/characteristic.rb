# frozen_string_literal: true

module CoreBluetoothMac
  class Characteristic
    attr_reader :uuid, :properties, :service, :initial_value

    def initialize(service:, uuid:, properties:, initial_value: nil)
      @service = service
      @uuid = uuid
      @properties = properties.is_a?(Set) ? properties : Set.new(properties)
      @properties.freeze unless @properties.frozen?
      @initial_value = if initial_value
                         initial_value.dup.force_encoding(Encoding::ASCII_8BIT).freeze
                       end
    end

    def supports?(prop)
      @properties.include?(prop)
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

    def discover_descriptors(timeout: 5.0)
      arr = central.__call_native(
        :characteristic_discover_descriptors,
        @service.peripheral.identifier, @service.uuid, @uuid, (timeout * 1000).to_i
      )
      @descriptors = arr.map { |h| Descriptor.new(characteristic: self, uuid: h["uuid"]) }
    end

    def descriptors
      @descriptors || raise(Error.new("call discover_descriptors first", domain: :discovery))
    end

    private

    def central
      @service.peripheral.central
    end
  end
end
