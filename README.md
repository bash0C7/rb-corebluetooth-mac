# rb-corebluetooth-mac

Apple CoreBluetooth (BLE central) for Ruby on macOS via Swift native extension.

## Requirements

- macOS 13+ (Bluetooth permission prompt requires this; `OSAllocatedUnfairLock` in the Swift extension requires macOS 13)
- Ruby ≥ 3.2 (development pins 4.0.3 via `.ruby-version`)
- Swift 6.3+ (recommended installer: [swiftly](https://www.swift.org/install/macos/))
- A Bluetooth-capable Mac with permission granted to the terminal app

## Installation

`Gemfile`:

```ruby
gem "rb-corebluetooth-mac"
```

```bash
bundle install
```

The Swift native extension is built via `swift build` at install time. Xcode is not required.

## Bluetooth Permission

The first time you create a `Central`, macOS shows an "Allow … to use Bluetooth?" prompt **bound to the process** (Terminal.app, iTerm.app, VS Code's integrated terminal, etc.). If denied, every subsequent `Central.new` raises `PermissionError`.

To recover: System Settings → Privacy & Security → Bluetooth → toggle the terminal app on. To force a fresh prompt: `tccutil reset Bluetooth`.

## Usage (Phase 1)

```ruby
require "corebluetooth_mac"

central = CoreBluetoothMac::Central.new(state_timeout: 5.0)

devices = central.scan(name: "StackChan-PicoRuby", timeout: 5.0)
peripheral = central.connect(devices.first, timeout: 5.0)

peripheral.discover_services
peripheral.services.each do |svc|
  puts svc.uuid
  svc.discover_characteristics
  svc.characteristics.each do |ch|
    next unless ch.readable?
    puts "  #{ch.uuid} = #{ch.read.inspect}"
  end
end

central.disconnect(peripheral)
```

## Usage (Phase 2): write & subscribe with Ractor pump

```ruby
require "corebluetooth_mac"

central = CoreBluetoothMac::Central.new
device  = central.scan(name: "StackChan-PicoRuby", timeout: 5.0).first or abort
periph  = central.connect(device)
periph.discover_services
periph.services.each(&:discover_characteristics)

rx = periph.find_characteristic("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
tx = periph.find_characteristic("6e400003-b5a3-f393-e0a9-e50e24dcca9e")

rx.write("ping\n", response: true)
sub = tx.subscribe

pump = Ractor.new(sub) do |s|
  while (v = s.next_value(timeout: 5.0))
    Ractor.yield v
  end
end

5.times { puts pump.take.inspect }
tx.unsubscribe
central.disconnect(periph)
```

## Errors

- `CoreBluetoothMac::PermissionError` — Bluetooth permission denied for this process.
- `CoreBluetoothMac::StateError` — Bluetooth off / unsupported / resetting.
- `CoreBluetoothMac::TimeoutError` — an operation did not complete within `timeout:`.
- `CoreBluetoothMac::ConnectionError` — connect failed or device disconnected mid-op.
- `CoreBluetoothMac::DiscoveryError` — service / characteristic discovery error.
- `CoreBluetoothMac::IOError` — read / write / notify framework error.
- `CoreBluetoothMac::ClosedError` — operation on a freed `Central`.

## Limitations

- One in-flight blocking operation per peripheral per kind. Concurrent reads on the same peripheral are serialized.
- BLE central role only; no `CBPeripheralManager` (peripheral / advertising) support.
- macOS only; not iOS / iPadOS / Linux.

## Phase 2 (next)

`Characteristic#write`, `#write_without_response`, `#subscribe` → Ractor-shareable `Subscription` with `#next_value(timeout:)`.

## License

MIT
