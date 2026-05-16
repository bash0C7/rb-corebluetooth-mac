# rb-corebluetooth-mac — development norms

Ruby C extension wrapping Apple CoreBluetooth (BLE central) via Swift. Three-layer architecture: Ruby API → C bridge → Swift wrappers → CoreBluetooth framework.

## Layout

- `lib/corebluetooth_mac/*.rb` — Ruby public API (`Central`, `Peripheral`, `Service`, `Characteristic`, `Descriptor`, `Subscription`, `DiscoveredDevice`, `PeripheralEvent::*`, `Error`)
- `ext/corebluetooth_mac/corebluetooth_mac.c` — C bridge. Unwraps JSON envelopes from Swift, raises `CoreBluetoothMac::Error` on `ok: false`. Blocking ops use `rb_thread_call_without_gvl` with `RUBY_UBF_IO` so other Ruby threads run.
- `ext/corebluetooth_mac/Sources/CoreBluetoothMac/*.swift` — Swift wrappers. `@_cdecl` exports live in `CoreBluetoothMac.swift`.

## Wire protocol

Every `@_cdecl` export returns a JSON envelope:

```
{"ok": true,  "data": <payload>}
{"ok": false, "error": {"domain": "...", "code": N|null, "code_name": "..."|null, "message": "..."}}
```

Exception: `subscription_next_value` returns the symbol `:closed` for closure (not an envelope).

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
- **`Data.define`** for value objects (Ractor-shareable, frozen by default).
- **`OSAllocatedUnfairLock<State>` typed locks** on `@unchecked Sendable` final classes. No `var` + side-lock — Swift 6 strict-concurrency rejects it.
- **`@preconcurrency import CoreBluetooth`** for Sendable interop.
- **No silent rescue.** `rescue nil`, empty `rescue`, `rescue ... => _` are forbidden. Tests use `omit "reason: #{e.message}"`. Production code must log / re-raise / return Result-type.
- **`Characteristic#supports?(:read|:write|:notify|...)`** single predicate. No `readable?` / `writable?` / `notifiable?`.
- **`Service#is_primary`** flat attribute. No `primary?` predicate.
- **`Central#close`** is idempotent. `isClosed` gate on every public Swift method returns the closed-domain error envelope.
- macOS 13+ required (`OSAllocatedUnfairLock`, modern Bluetooth permission API).

## Build

```bash
bundle exec rake compile                  # incremental
bundle exec rake clean clobber compile    # required after any Swift signature change
bundle exec rake test                     # non-HW
BLE_HW=1 bundle exec rake test            # include hardware-gated integration tests
```

**After any Swift signature change** (function name / parameter type / return type), `rake clean clobber compile` is mandatory — plain `rake compile` does NOT regenerate `CoreBluetoothMac-Swift.h`, leaving the C bridge with stale prototypes ("Call to undeclared function 'cbm_*'").

`rake test` should be delegated to a subagent to avoid polluting the main context with rake-compiler make logs and Test::Unit dot progress. Single-test debugging (`-n test_specific`) can be Bash-direct.

## LSP / SourceKit / clangd noise

Common false positives:

- SourceKit: `Cannot find type 'CBM*'`, `Cannot find 'Box'` — Swift Package indexing lag.
- clangd: `Call to undeclared function 'cbm_*'` — `CoreBluetoothMac-Swift.h` not yet in clangd's index.

**Trust `bundle exec rake compile` exit 0 over LSP diagnostics.** These do not block real compilation.

`rake clangd:setup` writes `ext/corebluetooth_mac/compile_flags.txt` (gitignored, rbenv-dependent path) to silence `ruby.h not found` / `VALUE undefined` in clangd. DX-only file, not part of the build.

## Apple API sources

When writing Swift for Apple frameworks, consult Xcode docset or developer.apple.com. **Do not rely on memorized signatures.** CoreBluetooth SDK headers (ground truth):

`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/CoreBluetooth.framework/Versions/A/Headers/`

- `CBAdvertisementData.h` — ad-data keys
- `CBCharacteristic.h` — `CBCharacteristicProperties` bits
- `CBService.h` — `isPrimary`, `includedServices`
- `CBError.h` — `CBError` + `CBATTError` enums
- `CBPeripheral.h` — `readRSSI`, `maximumWriteValueLength`, `discoverDescriptors`, `peripheralDidUpdateName`, `didModifyServices`, `didReadRSSI`
- `CBDescriptor.h`
- `CBCentralManager.h` — `didDisconnectPeripheral`

## Examples

`examples/Rakefile` exposes 9 demo tasks under `examples:` namespace. `cd examples && bundle exec rake -T` lists each with a `# columns: ...` legend. Tasks take positional `name=ARG` (target peripheral filter) and where applicable `char_uuid=ARG`. Real BLE adapter required; specific peripheral optional (most tasks abort cleanly when scan returns empty).
