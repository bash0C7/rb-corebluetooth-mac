# rb-corebluetooth-mac — development norms

Ruby C extension wrapping Apple CoreBluetooth (BLE central) via Swift, built on the [swift_gem](https://github.com/bash0C7/swift_gem) scaffold. Three layers: Ruby API → C bridge → Swift wrappers → CoreBluetooth framework.

## Environment

- macOS 27+, Apple Silicon, Xcode 27 (Swift 6.4). Builds run `xcrun swift`.
- Ruby 4.0+, Bundler 4.x. Gems install into `vendor/bundle` (`.bundle/config`).

## Layout

- `lib/corebluetooth_mac/*.rb` — Ruby public API (`Central`, `Peripheral`, `Service`, `Characteristic`, `Descriptor`, `Subscription`, `DiscoveredDevice`, `PeripheralEvent::*`, `Error`)
- `sig/corebluetooth_mac.rbs` — RBS for the public API. Ruby documentation lives here as `#` comments above each declaration.
- `ext/corebluetooth_mac/corebluetooth_mac.c` — C bridge. Unwraps JSON envelopes from Swift and raises `CoreBluetoothMac::Error` on `ok: false`.
- `ext/corebluetooth_mac/Sources/CoreBluetoothMac/CoreBluetoothMacBridge.swift` — `@c(corebluetooth_mac_*)` exports. Every buffer they return is released with `corebluetooth_mac_free`.
- `ext/corebluetooth_mac/Sources/CoreBluetoothMac/*.swift` — Swift wrappers (`CBMCentral`, `CBMPeripheralDelegate`, `CBMSubscriptionRegistry`) and shared types (`CBMError`, `CBMEnvelope`, `CBMCancel`).
- `ext/corebluetooth_mac/Tests/CoreBluetoothMacTests/*.swift` — Swift Testing tests (`@testable import CoreBluetoothMac`) for logic that runs without CoreBluetooth objects, such as `CBMSubscriptionRegistry`, which keys each subscription by central id, peripheral identifier, and characteristic UUID.
- `ext/corebluetooth_mac/swift_mkmf.rb` — vendored copy of swift_gem's `lib/swift_gem/mkmf.rb`; keep it identical.

## Wire protocol

Every bridge function that can fail returns a JSON envelope:

```
{"ok": true,  "data": <payload>}
{"ok": false, "error": {"domain": "...", "code": N|null, "code_name": "..."|null, "message": "..."}}
```

Exception: `__subscription_next_value` returns a String, `nil` (timeout), or the symbol `:closed`.

## Blocking calls and interrupts

Each blocking C method runs its Swift call through `call_without_gvl`, which creates a `CBMCancel` token (`corebluetooth_mac_cancel_new`) and passes `corebluetooth_mac_cancel` as the ubf of `rb_thread_call_without_gvl`. Every Swift wait goes through `CBMCancel.wait(_:until:)`, so the ubf ends the wait as a timeout and Interrupt, `Thread#raise`, and `Thread#kill` return at once. `rb_protect` frees the envelope and buffer when the interrupt unwinds. A new blocking operation takes a `cancel` parameter and waits only through the token. `CBMCancel.cancel()` signals only on its first call.

Each per-operation semaphore on `CBMCentral` / `CBMPeripheralDelegate` is `drain()`ed at the start of its operation, so a callback that arrived after an earlier timeout or interrupt does not complete the next call. The queue semaphores (`events.sem`, `CBMSubscriptionRegistry.Entry.semaphore`) count queued items and are never drained; their consumers always wait on the semaphore before popping, and `Entry.queue` / `Entry.closed` are touched only under the registry lock.

`__subscription_next_value` and `__subscription_close` are defined after `rb_ext_ractor_safe(true)` so `Subscription#next_value` runs inside a Ractor. The `Native` methods are not Ractor-safe.

## Error model

Single `CoreBluetoothMac::Error < StandardError` with required `domain:` keyword. **Subclasses banned.**

```ruby
class Error < StandardError
  attr_reader :domain, :code, :code_name
  def initialize(message, domain:, code: nil, code_name: nil)
end
```

`domain ∈ {:timeout, :closed, :connection, :discovery, :validation, :cb, :att}`. Rescue by `e.domain` symbol.

## Conventions

- **snake_case** envelope tags (`"name_updated"`, `"services_invalidated"`, `"disconnected"`).
- **`Data.define`** for value objects (Ractor-shareable).
- **`OSAllocatedUnfairLock<State>` typed locks** on `@unchecked Sendable` final classes. No `var` + side-lock.
- **`@preconcurrency import CoreBluetooth`** in the files whose `@Sendable` lock closures capture CoreBluetooth classes (`CBMCentral.swift`, `CBMSubscriptionRegistry.swift`); the SDK does not mark them `Sendable`.
- **No silent rescue.** `rescue nil`, empty `rescue`, `rescue ... => _` are forbidden. Tests use `omit "reason"`.
- **`Characteristic#supports?(:read|:write|:notify|...)`** single predicate. No `readable?` / `writable?` / `notifiable?`.
- **`Service#is_primary`** flat attribute. No `primary?` predicate.
- **`Central#close`** is idempotent. `isClosed` gate on every public Swift method returns the closed-domain error envelope.
- No code comments. Swift is documented with DocC (`///`); Ruby with `sig/corebluetooth_mac.rbs`.

## Build

```bash
bundle exec rake compile                  # xcrun swift build, then the C extension
bundle exec rake clobber compile          # after a Swift bridge signature change without a .c change
bundle exec rake swift_test               # xcrun swift test (Swift Testing, no Bluetooth)
bundle exec rake test                     # rbs validate, compile, swift_test, tests without Bluetooth hardware
BLE_HW=1 bundle exec rake test            # also run the tests that use the Bluetooth adapter
bundle exec rake console                  # IRB with the gem loaded
```

`xcrun swift build` writes `CoreBluetoothMac-Swift.h` under `ext/corebluetooth_mac/.build/out/Intermediates.noindex/GeneratedModuleMaps/`. The extension Makefile does not track that header, so a changed `@c` signature reaches the C side only after `rake clobber compile` or an edit to `corebluetooth_mac.c`.

`interrupt_test` needs only a usable adapter (`Central.new` reaching poweredOn) and runs in the plain `rake test`; it scans and never connects. `BLE_HW=1` tests need Bluetooth on and permitted. The tests that connect to an arbitrary peripheral (`disconnect_error_test`, `discover_descriptors_test`, `discover_included_services_test`, `discover_services_filter_test`, `max_write_length_test`, `peripheral_events_test`) connect only to the peripheral whose advertised name equals or starts with `BLE_TARGET_NAME`, and omit themselves without it; `notify_path_test` reads, writes, and subscribes, so it runs only when `BLE_TARGET_SERVICE` is the service UUID `test/support/virtual_peripheral.swift` prints, and it connects only to the advertiser of that service (run the script on a second Mac; a Mac's central does not see its own advertising, and a Mac's advertising carries no usable local name); the StackChan tests (`scan_test`, `connect_test`, `discover_test`, `read_gap_device_name_test`, `read_rssi_test`, `subscribe_test`, `subscribe_ractor_test`, `write_test`) omit themselves unless a CoreS3 advertising `StackChan-PicoRuby` with the Nordic UART service is nearby.

`rake test` should be delegated to a subagent to avoid polluting the main context with build logs and Test::Unit progress. Single-test debugging (`-n test_specific`) can be Bash-direct.

## LSP / SourceKit / clangd noise

- SourceKit: `Cannot find type 'CBM*'` — Swift Package indexing lag.
- clangd: `'CoreBluetoothMac-Swift.h' file not found`, `Call to undeclared function 'corebluetooth_mac_*'`, `ruby.h not found` — clangd lacks the build's include paths.

**Trust `bundle exec rake compile` exit 0 over LSP diagnostics.**

## Apple API sources

When writing Swift for Apple frameworks, consult the Xcode SDK or developer.apple.com. **Do not rely on memorized signatures.** CoreBluetooth headers (ground truth) are under `$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreBluetooth.framework/Headers/`:

- `CBAdvertisementData.h` — ad-data keys
- `CBCharacteristic.h` — `CBCharacteristicProperties` bits
- `CBService.h` — `isPrimary`, `includedServices`
- `CBError.h` — `CBError` + `CBATTError` enums
- `CBPeripheral.h` — `readRSSI`, `maximumWriteValueLength`, `discoverDescriptors`, `peripheralDidUpdateName`, `didModifyServices`, `didReadRSSI`, `peripheralIsReadyToSendWriteWithoutResponse:` (Swift: `peripheralIsReady(toSendWriteWithoutResponse:)`)
- `CBDescriptor.h`
- `CBCentralManager.h` — `didDisconnectPeripheral`

## Examples

`examples/Rakefile` exposes demo tasks under the `examples:` namespace. `cd examples && bundle exec rake -T` lists each with a `# columns: ...` legend. Tasks take positional `name=ARG` (target peripheral filter) and where applicable `char_uuid=ARG`. Tasks that connect require `name=ARG` or `BLE_TARGET_NAME` (exact or prefix match on the advertised name) and connect to the strongest match.
