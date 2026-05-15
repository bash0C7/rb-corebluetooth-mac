# frozen_string_literal: true

module CoreBluetoothMac
  DiscoveredDevice = Data.define(:central_id, :identifier, :name, :rssi)
end
