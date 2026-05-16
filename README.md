# rb-corebluetooth-mac

Apple CoreBluetooth (BLE central) for Ruby on macOS via Swift native extension.

## Requirements

- macOS 13+ (Bluetooth permission prompt requires this; `OSAllocatedUnfairLock` in the Swift extension requires macOS 13)
- Ruby (CRuby/MRI) ≥ 3.2 (no `.ruby-version` shipped — the consumer's Ruby is used)
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

### When loaded from a `path:` (or git:) source

If you wire the gem via `gem 'rb-corebluetooth-mac', path: '...'` instead of installing the published gem, Bundler skips the `extconf.rb` step and the prebuilt `lib/corebluetooth_mac/corebluetooth_mac.bundle` shipped in the repo is used as-is. Two consequences:

1. **The prebuilt `lib/corebluetooth_mac/corebluetooth_mac.bundle` is linked against whichever Ruby ABI last ran `rake compile` in this repo.** If your consumer's Ruby ABI does not match, load fails with `LoadError: linked to incompatible /Users/.../libruby.X.Y.dylib`. Run `bundle exec rake compile` in this repo with your consumer's Ruby active to rebuild the bundle for that ABI. (As a library, this gem does not ship a `.ruby-version` — the consumer chooses the Ruby.)
2. **Add `swift_gem` to your Gemfile as a path/git entry too**, because it is a runtime dependency that is not (yet) published to rubygems.org:
   ```ruby
   gem 'swift_gem', path: '/path/to/swift_gem'
   ```

## Bluetooth Permission

The first time you create a `Central`, macOS shows an "Allow … to use Bluetooth?" prompt **bound to the process** (Terminal.app, iTerm.app, VS Code's integrated terminal, etc.). If denied, every subsequent `Central.new` raises `CoreBluetoothMac::Error` with `#domain == :closed` and a message instructing the user to enable Bluetooth permission. The same domain covers other unusable adapter states (off / unsupported / resetting).

To recover: System Settings → Privacy & Security → Bluetooth → toggle the terminal app on. To force a fresh prompt: `tccutil reset Bluetooth`.

## Usage

End-to-end: scan → connect → discover → read GAP Device Name → read RSSI → check MTU → drain one event cycle → disconnect → close.

```ruby
require "corebluetooth_mac"

central = CoreBluetoothMac::Central.new(state_timeout: 5.0)

begin
  devices = central.scan(name: "YourDeviceName", timeout: 5.0) # name: nil lists all advertisers
  peripheral = central.connect(devices.first, timeout: 5.0)

  peripheral.discover_services(services: ["1800"], timeout: 5.0) # filter; nil = discover all
  gap = peripheral.find_service("1800")
  gap.discover_characteristics

  device_name_ch = gap.find_characteristic("2a00")
  puts "Device Name: #{device_name_ch.read.force_encoding('UTF-8')}" if device_name_ch.supports?(:read)

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

## Subscribing to notifications

`Characteristic#subscribe` returns a `Subscription`. Poll it with `Subscription#next_value(timeout:)`, which returns:

- **String** — notification payload (binary)
- **`nil`** — timeout (no value arrived within `timeout`; entry is still alive, poll again)
- **`false`** — entry is closed/drained terminal (use this to break loops)

### Simple polling (main thread)

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
  break if v == false   # subscription closed/drained — terminal
  next  if v.nil?       # timeout — keep polling until deadline
  puts v.inspect
end

tx.unsubscribe
central.disconnect(periph)
central.close
```

### Ractor pump (parallel)

`Subscription` is Ractor-shareable. Run the polling loop in a Ractor and yield received frames to the main thread when you want to interleave with other work:

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

pump = Ractor.new(sub) do |s|
  while (v = s.next_value(timeout: 5.0))
    Ractor.yield v
  end
end

5.times { puts pump.take.inspect }
tx.unsubscribe
central.disconnect(periph)
central.close
```

## Peripheral events

`Peripheral#poll_events(timeout:)` drains asynchronous events from the underlying `CBPeripheralDelegate` callbacks. Returns one event per call, or `nil` if the queue is empty within `timeout` (seconds). Event types:

- `PeripheralEvent::NameUpdated(name:)` — `peripheralDidUpdateName:` fired
- `PeripheralEvent::ServicesInvalidated(uuids:)` — `peripheral:didModifyServices:` fired; cached services for those UUIDs should be re-discovered
- `PeripheralEvent::Disconnected(error:)` — peripheral disconnected; `error` is a `CoreBluetoothMac::Error` or `nil` for clean disconnect

After a disconnect event the same error is also available via `Peripheral#last_disconnect_error`.

## Descriptors

```ruby
ch.discover_descriptors(timeout: 5.0)
ch.descriptors.each do |d|
  puts "#{d.uuid} = #{d.read.unpack1('H*')}"
end
```

## Running the examples

The repo ships with a Rakefile of demo tasks under `examples/`.

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

Each task is documented with a `# columns: ...` legend describing the TSV output schema. Tasks accept a positional `name=ARG` (and where applicable, `char_uuid=ARG`):

```bash
bundle exec rake "examples:scan[YourDeviceName]"
bundle exec rake "examples:rssi[YourDeviceName]"
bundle exec rake "examples:subscribe[YourDeviceName,6e400003-b5a3-f393-e0a9-e50e24dcca9e]"
```

## Errors

All failures raise a single `CoreBluetoothMac::Error < StandardError`. Discriminate via `#domain` (Symbol):

| `#domain`     | Meaning                                                          |
|---------------|------------------------------------------------------------------|
| `:timeout`    | Operation did not complete within `timeout:`                     |
| `:closed`     | Operation on a freed `Central` (after `#close`)                  |
| `:connection` | Connect failed or peripheral disconnected mid-op                 |
| `:discovery`  | Cached state not loaded yet (call `discover_*` first)            |
| `:validation` | Bad argument shape (e.g. UUID malformed, write payload too big)  |
| `:cb`         | `CBError` from CoreBluetooth (Bluetooth off, unauthorized, etc.) |
| `:att`        | `CBATTError` from the remote peer (read/write not permitted etc.)|

For `:cb` and `:att`, `#code` carries the numeric error code and `#code_name` carries a symbol like `:read_not_permitted` or `:peripheral_disconnected` when known.

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

- One in-flight blocking operation per peripheral per kind. Concurrent reads on the same peripheral are serialized.
- BLE central role only; no `CBPeripheralManager` (peripheral / advertising) support.
- macOS only; not iOS / iPadOS / Linux.
- **Apple CoreBluetooth filters `0x1800` (GAP) and `0x1801` (GATT) services from `discoverServices(nil)`.** Their characteristics (Device Name `0x2a00`, Appearance `0x2a01`, Service Changed `0x2a05`, etc.) are therefore not reachable via `Peripheral#find_characteristic`. For the advertised local name, use `Central#scan` results (`DiscoveredDevice#name`) which come from the scan-response payload rather than the GATT database.

## License

MIT
