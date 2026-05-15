# frozen_string_literal: true
require "swift_gem/mkmf"

SwiftGem::Mkmf.create_swift_makefile(
  "corebluetooth_mac/corebluetooth_mac",
  package: "CoreBluetoothMac",
  source_dir: __dir__
)
