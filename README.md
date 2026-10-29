# rb-corebluetooth-mac

Apple CoreBluetooth (BLE central) for Ruby on macOS. Scans, connects, discovers, reads, writes, and subscribes to notifications through a Swift package and a thin C bridge. Built on [swift_gem](https://github.com/bash0C7/swift_gem).

## Requirements

- macOS 27+, Apple Silicon, with Bluetooth on
- Xcode 27 (builds run `xcrun swift`)
- Ruby 4.0+, Bundler 4.x

## Installation

Install from source:

```bash
git clone https://github.com/bash0C7/rb-corebluetooth-mac.git
cd rb-corebluetooth-mac
bundle install
bundle exec rake compile
```

## Bluetooth permission

The first `Central.new` makes macOS ask whether the app that started Ruby (Terminal, iTerm, the VS Code terminal, ...) may use Bluetooth. Until it is allowed, `Central.new` raises `CoreBluetoothMac::Error` with `#domain == :closed` and a message that names the setting. The same domain covers Bluetooth that is off, unsupported, or resetting.

To allow it later: System Settings → Privacy & Security → Bluetooth → turn the app on. `tccutil reset Bluetooth` makes macOS ask again.

## Usage

Scan, connect, discover, read, check the RSSI and write lengths, drain events, disconnect, close:

```ruby
require "corebluetooth_mac"

central = CoreBluetoothMac::Central.new(state_timeout: 5.0)

begin
  device = central.scan(name: "YourDeviceName", timeout: 5.0).first or abort "not found"
  peripheral = central.connect(device, timeout: 5.0)

  peripheral.discover_services(timeout: 5.0)
  peripheral.services.each(&:discover_characteristics)
  peripheral.services.flat_map(&:characteristics).select { _1.supports?(:read) }.each do |ch|
    puts "#{ch.uuid}: #{ch.read.unpack1('H*')}"
  end

  puts "RSSI: #{peripheral.read_rssi} dBm"
  puts "Max write (with response):    #{peripheral.max_write_length(response: true)}"
  puts "Max write (without response): #{peripheral.max_write_length(response: false)}"

  while (event = peripheral.poll_events(timeout: 0.0))
    puts "event: #{event.inspect}"
  end

  central.disconnect(peripheral)
rescue CoreBluetoothMac::Error => e
  warn "[#{e.domain}] #{e.message} (code=#{e.code.inspect} code_name=#{e.code_name.inspect})"
ensure
  central.close
end
```

`scan(name: nil)` returns every advertiser. `discover_services(services: ["180a"])` discovers only the listed services.

Open an IRB console with the gem loaded:

```bash
bundle exec rake console
```

## Subscribing to notifications

`Characteristic#subscribe` returns a `Subscription`. `Subscription#next_value(timeout:)` returns:

- **String**: the notification payload (binary)
- **`nil`**: no value arrived within `timeout`; poll again
- **`false`**: the subscription is closed and drained; stop polling

### Polling on the main thread

```ruby
require "corebluetooth_mac"

central = CoreBluetoothMac::Central.new
device  = central.scan(name: "YourDeviceName", timeout: 5.0).first or abort
periph  = central.connect(device)
periph.discover_services
periph.services.each(&:discover_characteristics)

tx = periph.find_characteristic("6e400003-b5a3-f393-e0a9-e50e24dcca9e")
sub = tx.subscribe

deadline = Time.now + 10
while (remaining = deadline - Time.now) > 0
  v = sub.next_value(timeout: remaining)
  break if v == false
  next  if v.nil?
  puts v.inspect
end

tx.unsubscribe
central.disconnect(periph)
central.close
```

### Polling in a Ractor

`Subscription` is Ractor-shareable and `next_value` runs inside a Ractor. Send the values back through a `Ractor::Port`:

```ruby
require "corebluetooth_mac"

central = CoreBluetoothMac::Central.new
device  = central.scan(name: "YourDeviceName", timeout: 5.0).first or abort
periph  = central.connect(device)
periph.discover_services
periph.services.each(&:discover_characteristics)

rx = periph.find_characteristic("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
tx = periph.find_characteristic("6e400003-b5a3-f393-e0a9-e50e24dcca9e")

rx.write("ping\n", response: true)
sub = tx.subscribe

port = Ractor::Port.new
pump = Ractor.new(sub, port) do |s, out|
  while (v = s.next_value(timeout: 5.0))
    out << v
  end
  out << :done
end

while (v = port.receive) != :done
  puts v.inspect
end
pump.join
tx.unsubscribe
central.disconnect(periph)
central.close
```

## Peripheral events

`Peripheral#poll_events(timeout:)` returns one event from the peripheral's queue, or `nil` when none arrives within `timeout` seconds:

- `PeripheralEvent::NameUpdated(name:)`: the peripheral changed its name
- `PeripheralEvent::ServicesInvalidated(uuids:)`: the peripheral invalidated these services; discover them again
- `PeripheralEvent::Disconnected(error:)`: the peripheral disconnected; `error` is a `CoreBluetoothMac::Error`, or `nil` for a clean disconnection

`Peripheral#last_disconnect_error` returns the error of the last disconnection.

## Descriptors

```ruby
ch.discover_descriptors(timeout: 5.0)
ch.descriptors.each do |d|
  puts "#{d.uuid} = #{d.read.unpack1('H*')}"
end
```

## Interrupts

Every blocking call releases the GVL. `Interrupt` (Ctrl-C), `Thread#raise`, and `Thread#kill` end the wait at once; an interrupted `connect` also cancels the pending connection.

## Running the examples

`examples/Rakefile` holds demo tasks:

```bash
cd examples
bundle exec rake -T
```

```
rake examples:connect_and_read[name]       # scan, connect, read GAP Device Name
rake examples:descriptors[name,char_uuid]  # discover and read descriptors
rake examples:discover_tree[name]          # full GATT tree dump
rake examples:events[name]                 # connect and poll_events for 30s
rake examples:max_write[name]              # print max write lengths
rake examples:rssi[name]                   # connect then readRSSI x5 @ 1s intervals
rake examples:scan[name]                   # scan all (no filter) or by Local Name
rake examples:scan_verbose[name]           # full ad-data dump
rake examples:subscribe[name,char_uuid]    # subscribe + Ractor pump 10s
```

Each task's description starts with a `# columns: ...` legend for its tab-separated output. Tasks take a positional `name` (and, where listed, `char_uuid`). The tasks that connect need a target: `name`, or `BLE_TARGET_NAME` when `name` is omitted, matched against the advertised name exactly or as a prefix. They connect to the strongest match:

```bash
bundle exec rake "examples:scan[YourDeviceName]"
bundle exec rake "examples:rssi[YourDeviceName]"
bundle exec rake "examples:subscribe[YourDeviceName,6e400003-b5a3-f393-e0a9-e50e24dcca9e]"
```

## Errors

Every failure raises `CoreBluetoothMac::Error < StandardError`. Branch on `#domain`:

| `#domain`     | Meaning                                                                          |
|---------------|----------------------------------------------------------------------------------|
| `:timeout`    | The operation did not finish within `timeout:`                                   |
| `:closed`     | The `Central` is closed, Bluetooth is unusable, or an operation other than `connect` and `poll_events` got a peripheral the `Central` has not scanned |
| `:connection` | Connecting failed, `connect` got a peripheral the `Central` has not scanned, or the peripheral is not connected |
| `:discovery`  | The service, characteristic, or descriptor is not discovered yet (call `discover_*` first) |
| `:validation` | An argument has the wrong shape                                                  |
| `:cb`         | `CBError` from CoreBluetooth                                                     |
| `:att`        | `CBATTError` from the remote peer (read/write not permitted etc.)                |

For `:cb` and `:att`, `#code` is the numeric code and `#code_name` a symbol such as `:read_not_permitted` or `:peripheral_disconnected`.

```ruby
begin
  ch.write(payload, response: true, timeout: 5.0)
rescue CoreBluetoothMac::Error => e
  case e.domain
  when :timeout    then warn "timed out"
  when :att        then warn "ATT error #{e.code_name} (#{e.code})"
  when :closed     then warn "Central was closed"
  else raise
  end
end
```

## Limitations

- One blocking operation of each kind per peripheral at a time.
- BLE central role only; no `CBPeripheralManager` (peripheral / advertising).
- macOS only.
- CoreBluetooth does not report the GAP (`0x1800`) and GATT (`0x1801`) services of some peripherals; for those, Device Name (`0x2a00`) and the other characteristics under them are not reachable. Use `DiscoveredDevice#name` for the advertised name.

## Development

```bash
bundle install
bundle exec rake test
BLE_HW=1 BLE_TARGET_NAME=YourDeviceName bundle exec rake test
```

`rake test` validates `sig/corebluetooth_mac.rbs`, runs `xcrun swift build -c release --package-path ext/corebluetooth_mac`, builds the C extension into `lib/corebluetooth_mac/corebluetooth_mac.bundle`, then runs the tests. The interrupt test scans for a moment and is omitted when the Bluetooth adapter is unavailable. The other tests that use the adapter run only with `BLE_HW=1`. Of those, the tests that connect to any peripheral use only the one whose advertised name equals or starts with `BLE_TARGET_NAME` and are omitted without it; the tests for a CoreS3 advertising `StackChan-PicoRuby` are omitted when it is not nearby.

## License

MIT
