# frozen_string_literal: true

module CoreBluetoothMac
  DiscoveredDevice = Data.define(
    :identifier,
    :name,
    :rssi,
    :tx_power_level,
    :connectable,
    :service_uuids,
    :service_data,
    :manufacturer_data,
    :solicited_service_uuids,
    :overflow_service_uuids,
    :central_id,
  )
end
