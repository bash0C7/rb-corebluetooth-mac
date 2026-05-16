# frozen_string_literal: true

module CoreBluetoothMac
  class Descriptor
    attr_reader :uuid, :characteristic, :value

    def initialize(characteristic:, uuid:, value: nil)
      @characteristic = characteristic
      @uuid = uuid
      @value = value
    end

    def read(timeout: 5.0)
      @value = characteristic.service.peripheral.central.__call_native(
        :descriptor_read,
        characteristic.service.peripheral.identifier,
        characteristic.service.uuid,
        characteristic.uuid,
        @uuid,
        (timeout * 1000).to_i
      )
    end

    def write(data, timeout: 5.0)
      characteristic.service.peripheral.central.__call_native(
        :descriptor_write,
        characteristic.service.peripheral.identifier,
        characteristic.service.uuid,
        characteristic.uuid,
        @uuid,
        data.to_s.b,
        (timeout * 1000).to_i
      )
      @value = data.to_s.b
      true
    end
  end
end
