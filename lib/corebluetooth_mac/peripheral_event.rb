# frozen_string_literal: true

module CoreBluetoothMac
  # Value objects for asynchronous peripheral events drained via
  # `Peripheral#poll_events`. Each subtype is a `Data.define` so instances are
  # Ractor-shareable (all fields are immutable strings / arrays / Error / nil).
  #
  # Tags emitted by the Swift bridge (snake_case) map 1:1 to these classes:
  #   "name_updated"          → NameUpdated(name: String)
  #   "services_invalidated"  → ServicesInvalidated(uuids: [String])
  #   "disconnected"          → Disconnected(error: CoreBluetoothMac::Error | nil)
  module PeripheralEvent
    NameUpdated         = Data.define(:name)
    ServicesInvalidated = Data.define(:uuids)
    Disconnected        = Data.define(:error)  # CoreBluetoothMac::Error or nil
  end
end
