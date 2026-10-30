# frozen_string_literal: true

require_relative "swift_mkmf"

SwiftGem::Mkmf.create_swift_makefile(
  "corebluetooth_mac/corebluetooth_mac",
  package: "CoreBluetoothMac",
  source_dir: __dir__
)
