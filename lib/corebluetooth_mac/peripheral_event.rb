# frozen_string_literal: true

module CoreBluetoothMac
  module PeripheralEvent
    NameUpdated         = Data.define(:name)
    ServicesInvalidated = Data.define(:uuids)
    Disconnected        = Data.define(:error)
  end
end
