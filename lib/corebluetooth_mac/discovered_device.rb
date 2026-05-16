# frozen_string_literal: true

module CoreBluetoothMac
  DiscoveredDevice = Data.define(
    :identifier,
    :name,
    :rssi,
    :tx_power_level,         # Integer (dBm) or nil
    :connectable,            # true | false | nil (key absent)
    :service_uuids,          # [String] lowercase UUID, default []
    :service_data,           # { String => String (binary, ASCII-8BIT) }, default {}
    :manufacturer_data,      # String (binary, ASCII-8BIT) or nil
    :solicited_service_uuids, # [String], default []
    :overflow_service_uuids,  # [String], default []
    :central_id,
  )
end
