# rb-corebluetooth-mac Design Doc

- Date: 2026-05-15
- Status: Draft (awaiting user approval)
- Author: bash0C7 (with Claude pairing)
- Consumer: `~/dev/src/github.com/bash0C7/stackchan-picoruby` (`pc/web-ble-test/` → planned rename to `pc/ble-bridge/`)
- Target device: CoreS3 running picoruby-ble peripheral, advertising name `StackChan-PicoRuby`

## 1. Mission

Provide a Ruby gem that lets a macOS host act as a BLE **central** by directly driving Apple's `CoreBluetooth` framework through a Swift native extension. The gem must replace all current human-in-the-loop Web Bluetooth / `chrome://bluetooth-internals` workflows so that an automated Ruby HTTP/WS server (Sinatra inside `stackchan-picoruby/pc/`) can scan, connect, discover GATT, read, write, and subscribe to notifications against a CoreS3 BLE peripheral.

## 2. Scope

**Phase 1** (this session, ship as `0.1.0`):

- `Central.new` with Bluetooth state / permission handling
- `Central#scan(name:, services:, timeout:)` → `[DiscoveredDevice]`
- `Central#connect(device, timeout:)` → `Peripheral`
- `Peripheral#discover_services` (full tree population deferred to per-level calls)
- `Service#discover_characteristics`
- `Characteristic#read(timeout:)` returning a frozen `String` (binary)
- `Central#disconnect(peripheral)`
- Phase 1 success criterion: `examples/scan_and_read.rb` finds `StackChan-PicoRuby`, connects, reads Device Name (`0x2A00`) under Generic Access service (`0x1800`), and returns the string `"StackChan-PicoRuby"`.

**Phase 2** (continues in the same session per user request, ship as `0.2.0`):

- `Characteristic#write(data, response: true/false, timeout:)`
- `Characteristic#subscribe` → `Subscription` value object
- `Subscription#next_value(timeout:)` → frozen `String` or `nil`
- `Subscription#close` / `Characteristic#unsubscribe`
- Designed to be **Ractor-shareable** so consumers can pump notifications from a child Ractor
- NUS integration with CoreS3 is gated on the peripheral side adding RX/TX characteristics (`6e400002…` / `6e400003…`). The gem must not hardcode NUS UUIDs.

**Non-goals** (out of scope, both phases):

- Peripheral role (no `CBPeripheralManager` work)
- Background-mode advertising preservation, `restoreState`
- L2CAP channels
- BLE 5 extended scanning / coded PHY beyond what CoreBluetooth exposes by default
- iOS / iPadOS support
- Linux fallback (a future portable façade can wrap this gem; not designed here)

## 3. Architecture Overview

Three-layer stack, mirroring the sibling Apple-framework gems under `bash0C7/`:

```
[ Ruby user code / Sinatra ]
            │
            ▼
[ lib/corebluetooth_mac/*.rb ]
    │ - Central: thin C-ext wrapper (TypedData)
    │ - DiscoveredDevice, Subscription: Data.define value objects (Ractor-shareable)
    │ - Peripheral, Service, Characteristic: pure Ruby (no C state),
    │   route operations back through @central
            │
            ▼
[ ext/corebluetooth_mac/corebluetooth_mac.c ]
    │ - TypedData_Wrap_Struct allocator + free for Central
    │ - rb_define_method on Central (the "heavy" surface)
    │ - rb_define_module_function for Subscription operations (registry-keyed)
    │ - rb_thread_call_without_gvl for every blocking BLE call
    │ - No business logic. ~150 LOC target.
            │
            ▼ ( @c C ABI, SE-0495 )
[ ext/corebluetooth_mac/Sources/CoreBluetoothMac/*.swift ]
    │ - CBMCentral: owns CBCentralManager + CBPeripheralDelegate per peripheral
    │ - DispatchSemaphore-based sync for every Ruby-blocking call
    │ - SubscriptionRegistry: process-global, mutex-protected dict of
    │   subscription_id → (queue, semaphore, characteristic)
            │
            ▼
[ CoreBluetooth framework (Apple) ]
```

### 3.1. Why this shape

- **Per-Ruby-object TypedData only for `Central`** (Approach 3 from brainstorming). Peripheral/Service/Characteristic are plain Ruby. This keeps the C surface small, avoids tangled GC graphs, and matches how users actually navigate the tree (always through a live `Central`).
- **Subscription is a `Data.define` value** carrying only `(central_id, subscription_id)` integers. Both fields are shareable, so the whole struct is Ractor-shareable by default. The Swift state lives in a registry keyed by `subscription_id`.
- **Notify delivery is poll-style**, not block-with-thread. The gem never spawns a Thread or Ractor internally. Consumers run their own Ractor if they want background pumping. This sidesteps the isolated-Proc problem and keeps the FM-pattern symmetry (`fmm_stream_next` ≅ `cbm_subscription_next_value`).

### 3.2. Concurrency model

- **CBCentralManager queue**: a dedicated `DispatchQueue(label: "corebluetoothmac.central")` (not main), so delegate callbacks don't fight with the Ruby main thread or with anything CoreBluetooth ships on the main queue.
- **GVL**: every C function that may block (scan/connect/discover/read/write/next_value) calls `rb_thread_call_without_gvl`. Other Ractors / GVL-respecting code stay unblocked.
- **Cross-Ractor**: `Central` and its `Peripheral/Service/Characteristic` graph live in the Ractor that created them (not shareable). `Subscription` instances are shareable; the registry is mutex-protected on the Swift side so concurrent `next_value` calls from different Ractors work.

## 4. Ruby Object Model

| Class | Form | Holds | Purpose |
|---|---|---|---|
| `CoreBluetoothMac::Central` | `TypedData_Wrap_Struct` | Swift `CBMCentral*` opaque ptr + `central_id: Integer` | The only "heavy" Ruby object. Drives `CBCentralManager`. |
| `CoreBluetoothMac::DiscoveredDevice` | `Data.define(:central_id, :identifier, :name, :rssi)` | Frozen values | Scan result. Ractor-shareable. |
| `CoreBluetoothMac::Peripheral` | Pure Ruby class | `@central`, `@identifier`, `@services` (Array, lazily populated) | Connection handle. |
| `CoreBluetoothMac::Service` | Pure Ruby class | `@peripheral`, `@uuid`, `@characteristics` | GATT service node. |
| `CoreBluetoothMac::Characteristic` | Pure Ruby class | `@service`, `@uuid`, `@properties` (Set of `:read`/`:write`/`:write_without_response`/`:notify`/`:indicate`) | GATT characteristic node. read/write/subscribe entry point. |
| `CoreBluetoothMac::Subscription` | `Data.define(:central_id, :subscription_id)` | Frozen Integers | **Ractor-shareable**. `#next_value(timeout:)` dispatches to registry. |

### 4.1. Module API

```ruby
module CoreBluetoothMac
  VERSION = "0.1.0"

  class Error < StandardError; end
  class StateError       < Error; end   # Bluetooth off, unauthorized, unsupported
  class PermissionError  < StateError; end
  class TimeoutError     < Error; end
  class ConnectionError  < Error; end
  class DiscoveryError   < Error; end
  class IOError          < Error; end   # read/write/notify framework error
  class ClosedError      < Error; end   # operation on disconnected/freed object
end
```

### 4.2. Method signatures (frozen for both phases)

```ruby
Central.new                                # blocks ≤ 3.0s waiting for poweredOn, raises StateError/PermissionError otherwise

central.scan(name: nil, services: nil, timeout: 5.0)  # => [DiscoveredDevice]
central.connect(device, timeout: 5.0)                 # => Peripheral, raises ConnectionError on fail
central.disconnect(peripheral)                        # => nil
central.close                                         # invalidates Central + all descendants

peripheral.identifier                                 # => String (UUID)
peripheral.state                                      # => :disconnected / :connecting / :connected / :disconnecting
peripheral.discover_services(timeout: 5.0)            # populates @services, returns self
peripheral.services                                   # => [Service]
peripheral.find_service(uuid)                         # case-insensitive uuid match
peripheral.find_characteristic(uuid)                  # traverses all already-discovered services

service.uuid                                          # => String
service.discover_characteristics(timeout: 5.0)        # populates @characteristics, returns self
service.characteristics                               # => [Characteristic]
service.find_characteristic(uuid)

characteristic.uuid                                   # => String
characteristic.properties                             # => Set
characteristic.readable?  / writable? / notify?
characteristic.read(timeout: 5.0)                     # => frozen String
characteristic.write(data, response: true, timeout: 5.0)        # Phase 2
characteristic.write_without_response(data)                     # Phase 2, alias for write(..., response: false, timeout: nil)
characteristic.subscribe                              # Phase 2 => Subscription
characteristic.unsubscribe                            # Phase 2 => nil

subscription.next_value(timeout: 1.0)                 # Phase 2 => frozen String or nil
subscription.close                                    # Phase 2 => idempotent
subscription.subscription_id                          # Integer (Data.define accessor, useful for diagnostics)
```

## 5. Swift Architecture

### 5.1. Files

```
ext/corebluetooth_mac/Sources/CoreBluetoothMac/
├── CoreBluetoothMac.swift          # @c ABI surface only (thin)
├── CBMCentral.swift                # CBCentralManager owner + delegate
├── CBMPeripheralDelegate.swift     # per-peripheral discovery state machine
├── CBMSubscriptionRegistry.swift   # global, mutex-protected
└── CBMSync.swift                   # DispatchSemaphore / Box helpers shared with FM pattern
```

### 5.2. `CBMCentral` responsibilities

- Own one `CBCentralManager` initialized on a dedicated dispatch queue.
- Wait for `centralManagerDidUpdateState` to reach `.poweredOn` before allowing any operation (configurable timeout, default 3.0s, raised in C as `StateError` / `PermissionError`).
- Maintain dict `[UUID: CBPeripheral]` of every peripheral ever discovered / retrieved this session. `DiscoveredDevice` returned to Ruby carries the UUID; subsequent `connect(device)` looks the live `CBPeripheral` up.
- Per-peripheral delegate (`CBMPeripheralDelegate`) tracks: pending sync ops (services / characteristics / read / write_with_response / subscribe), their semaphores, and the latest snapshot of the GATT tree.
- Outstanding-ops policy: **one in-flight blocking op per peripheral per kind**. Concurrent reads on different characteristics of the same peripheral are serialized at the gem boundary; we don't try to demultiplex CoreBluetooth's `didUpdateValueFor` results in Phase 1/2. Document explicitly.
- Bluetooth permission UX (macOS 11+): the first `CBCentralManager.init` triggers the OS-level Bluetooth permission prompt. README must call this out. On `unauthorized`, raise `PermissionError("System Settings → Privacy & Security → Bluetooth で Ruby (Terminal.app / iTerm.app) を許可してください")`.

### 5.3. `CBMSubscriptionRegistry`

- Process-global singleton (Swift `actor` or `OSAllocatedUnfairLock`-protected struct — pick the latter for parity with FM's `OSAllocatedUnfairLock` usage).
- Maps `subscription_id: Int64` → `Entry`:
  ```swift
  struct Entry {
      weak var central: CBMCentral?
      let characteristic: CBCharacteristic
      var queue: [Data]
      var closed: Bool
      let semaphore: DispatchSemaphore
  }
  ```
- `enqueue(subscriptionId:, data:)`: called from `peripheral(_:didUpdateValueFor:)` when the characteristic is subscribed.
- `dequeue(subscriptionId:, timeoutMs:)`: blocks on `semaphore` up to timeout, returns `(Data?, closed: Bool)`. Drives the GVL-released wait in `cbm_subscription_next_value`.
- `close(subscriptionId:)`: sets `closed`, signals semaphore so any waiter wakes and returns `nil`.
- Cleared in bulk when `CBMCentral` deinits (every entry whose `central` weak ref is now nil is purged on next access).

### 5.4. `@c` ABI surface (SE-0495)

Per `swift_gem` README, Swift 6.3+ `@c` attribute is mandatory; `@_cdecl` is not used.

```swift
@c public func cbm_central_new(
    _ stateTimeoutMs: Int32,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutableRawPointer?

@c public func cbm_central_free(_ ptr: UnsafeMutableRawPointer)

@c public func cbm_central_scan(
    _ ptr: UnsafeMutableRawPointer,
    _ name_filter: UnsafePointer<CChar>?,
    _ service_uuids_json: UnsafePointer<CChar>?,   // ["uuid", ...] or nil
    _ timeout_ms: Int32,
    _ error_out: ...
) -> UnsafeMutablePointer<CChar>?                   // strdup'd JSON array of {identifier,name,rssi}

@c public func cbm_central_connect(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ timeout_ms: Int32,
    _ error_out: ...
) -> Int32                                          // 1 ok, 0 fail (err in error_out)

@c public func cbm_central_disconnect(...) -> Int32

@c public func cbm_peripheral_discover_services(...) -> UnsafeMutablePointer<CChar>?  // JSON [uuids]
@c public func cbm_peripheral_discover_characteristics(...) -> UnsafeMutablePointer<CChar>?  // JSON [{uuid, props}]

@c public func cbm_characteristic_read(...) -> /* opaque bytes via len_out */
@c public func cbm_characteristic_write(...) -> Int32                            // Phase 2
@c public func cbm_characteristic_subscribe(...) -> Int64                        // Phase 2, returns subscription_id

@c public func cbm_subscription_next_value(
    _ subscription_id: Int64,
    _ timeout_ms: Int32,
    _ closed_out: UnsafeMutablePointer<Int32>,
    _ len_out: UnsafeMutablePointer<Int32>,
    _ error_out: ...
) -> UnsafeMutablePointer<UInt8>?                                                # Phase 2

@c public func cbm_subscription_close(_ subscription_id: Int64)                  # Phase 2
```

JSON crossing the ABI keeps the C bridge boilerplate minimal (no Array<CStr> juggling). The volumes are tiny (one scan returns ≤ tens of devices).

## 6. C Bridge

`ext/corebluetooth_mac/corebluetooth_mac.c`. Target ≤ 150 LOC.

Responsibilities:

1. `Init_corebluetooth_mac`: define module, error classes, `Central` class with alloc func + methods, module functions for `Subscription` operations.
2. `TypedData_Wrap_Struct` for `Central` (free fn = `cbm_central_free`).
3. For every blocking call: pack args into a struct, call `rb_thread_call_without_gvl`, on return raise on `error_out` or build the Ruby return value.
4. JSON parsing for service/char arrays: keep it dumb — use `rb_funcall(rb_const_get(rb_cObject, rb_intern("JSON")), rb_intern("parse"), 1, str)` rather than linking a C JSON lib. `require "json"` in `lib/corebluetooth_mac.rb`.
5. No business logic, no caching, no validation beyond `StringValueCStr` / `Check_Type`.

## 7. Lifecycle

```
Central.new
  → cbm_central_new(timeout_ms=3000)
  → Swift: CBCentralManager init on dedicated queue
  → Swift: wait DispatchSemaphore until didUpdateState fires
      .poweredOn        → return handle
      .unauthorized     → return null + "permission denied"
      .unsupported      → return null + "unsupported hardware"
      .poweredOff       → return null + "Bluetooth is off"
      (timeout)         → return null + "state did not reach poweredOn within 3s"
  → C: raise StateError/PermissionError if null, else wrap

central.scan(...)
  → cbm_central_scan: scanForPeripherals + collect via didDiscover into a [UUID: Snapshot] map
  → after timeout_ms: stopScan, return strdup'd JSON
  → Ruby: parse, map to DiscoveredDevice instances

central.connect(device)
  → cbm_central_connect: lookup CBPeripheral by UUID, call connect, semaphore-wait until didConnect/didFailToConnect/didDisconnectPeripheral
  → Ruby: build Peripheral with @central, @identifier, @services=[]

peripheral.discover_services
  → reach into the per-peripheral delegate via @central
  → discoverServices(nil), wait, return JSON of UUIDs
  → Ruby populates @services with Service instances

service.discover_characteristics
  → similar, returns JSON of {uuid, props}, Ruby builds Characteristic instances

characteristic.read
  → readValue(for:), wait for didUpdateValueFor matching this characteristic, return bytes
  → Ruby returns frozen binary String

characteristic.write(data, response: true)        # Phase 2
  → writeValue(_:for:type:.withResponse), wait for didWriteValueFor, raise IOError on err

characteristic.write_without_response(data)       # Phase 2
  → writeValue(..., type: .withoutResponse). No semaphore wait (best-effort). Optional canSendWriteWithoutResponse loop guard.

characteristic.subscribe                          # Phase 2
  → setNotifyValue(true, for:), wait for didUpdateNotificationStateFor
  → register Entry in SubscriptionRegistry, return subscription_id
  → Ruby wraps in Subscription Data instance

subscription.next_value(timeout:)                 # Phase 2
  → cbm_subscription_next_value: registry.dequeue with semaphore + timeout
  → returns frozen String, or nil on timeout, or nil + flag if closed

characteristic.unsubscribe                        # Phase 2
  → setNotifyValue(false, for:), wait for didUpdateNotificationStateFor
  → registry.close(subscription_id) — any pending next_value returns nil

central.close / Central GC
  → cancel all peripheral connections
  → stop scan
  → close all subscriptions under this central (registry sweep)
  → release CBCentralManager (Swift Unmanaged.release)
```

## 8. Error Mapping

| CoreBluetooth condition | Ruby exception |
|---|---|
| `.unauthorized` state | `PermissionError` |
| `.unsupported` / `.resetting` | `StateError` |
| `.poweredOff` | `StateError` ("Bluetooth is off") |
| Operation timed out | `TimeoutError` |
| `didFailToConnect` | `ConnectionError` |
| `didDisconnectPeripheral(error: non-nil)` while op pending | `ConnectionError` (and operation raises) |
| `didDiscoverServices(error:)` non-nil | `DiscoveryError` |
| `didUpdateValueFor(error:)` non-nil | `IOError` |
| `didWriteValueFor(error:)` non-nil | `IOError` |
| Method called after `central.close` or peripheral disconnected | `ClosedError` |

The Swift side preserves `error.localizedDescription` and passes it through `error_out` as a `strdup`'d C string; Ruby includes it in the exception message.

## 9. Memory & Ractor Safety

- `Central` holds a Swift-side `Unmanaged.passRetained` pointer; the C `dfree` calls `cbm_central_free` which:
  1. Cancels all CBPeripheral connections
  2. Closes all subscriptions for this central in the registry
  3. `Unmanaged.fromOpaque(ptr).release()`
- `Subscription` is a frozen `Data.define` value. The underlying registry entry has `weak var central`; if the `Central` was already freed, `next_value` returns `nil + closed=true` immediately.
- The registry uses `OSAllocatedUnfairLock<State>` (same primitive as FM's `FMMStream.state`). Lock is held only while mutating the dict / queue; the semaphore wait happens outside the lock.
- Ractor-shareability check: `Ractor.shareable?(subscription)` must be `true`. This is a test fixture.

## 10. Project Layout

```
rb-corebluetooth-mac/
├── .ruby-version                          # 4.0.3 (matches sibling gems' dev pin; gemspec requires >= 3.2.0)
├── .swift-version                         # 6.3.1 (matches sibling gems)
├── .gitignore                             # vendor/, tmp/, lib/corebluetooth_mac/*.bundle, .build/, Gemfile.lock — see siblings
├── Gemfile                                # path: ../swift_gem, irb, rake, rake-compiler, test-unit
├── Rakefile                               # ExtensionTask + TestTask
├── rb-corebluetooth-mac.gemspec           # name "rb-corebluetooth-mac", extensions in ext/corebluetooth_mac/extconf.rb
├── LICENSE.txt                            # MIT, copy from sibling
├── README.md                              # Requirements / Install / Usage / Permission UX / Limitations
├── docs/
│   └── superpowers/specs/
│       └── 2026-05-15-rb-corebluetooth-mac-design.md   # this file
├── ext/
│   └── corebluetooth_mac/
│       ├── extconf.rb                     # SwiftGem::Mkmf.create_swift_makefile("corebluetooth_mac/corebluetooth_mac", package: "CoreBluetoothMac", source_dir: __dir__)
│       ├── Package.swift                  # platforms: [.macOS("13.0")], dynamic library "CoreBluetoothMac"
│       ├── corebluetooth_mac.c
│       └── Sources/
│           └── CoreBluetoothMac/
│               ├── CoreBluetoothMac.swift
│               ├── CBMCentral.swift
│               ├── CBMPeripheralDelegate.swift
│               ├── CBMSubscriptionRegistry.swift
│               └── CBMSync.swift
├── lib/
│   ├── corebluetooth_mac.rb               # entry require + module + errors
│   └── corebluetooth_mac/
│       ├── version.rb
│       ├── central.rb
│       ├── peripheral.rb
│       ├── service.rb
│       ├── characteristic.rb
│       ├── discovered_device.rb
│       └── subscription.rb
├── examples/
│   ├── scan_and_read.rb                   # Phase 1 deliverable
│   ├── scan_only.rb                       # spike runner
│   └── subscribe_ractor.rb                # Phase 2 deliverable (Ractor pump)
└── test/
    ├── test_helper.rb                     # hardware-skip helper
    ├── unit/                              # no-hardware tests
    │   ├── test_module.rb
    │   ├── test_errors.rb
    │   ├── test_discovered_device.rb
    │   ├── test_subscription_value.rb     # Ractor.shareable? check, equality, frozen
    │   └── test_peripheral_routing.rb     # with a stub Central
    └── integration/                       # require ENV["BLE_HW"]=1 + CoreS3 advertising
        ├── test_central_init.rb
        ├── test_scan.rb
        ├── test_connect.rb
        ├── test_discover.rb
        ├── test_read_gap_device_name.rb   # Phase 1 success-criterion test
        ├── test_write.rb                  # Phase 2 (needs Phase 2 peripheral)
        ├── test_subscribe.rb              # Phase 2
        └── test_subscribe_ractor.rb       # Phase 2, cross-Ractor pump
```

Module/require/gem naming (consistent with user brief and sibling conventions):

- gem name: `rb-corebluetooth-mac`
- require name: `corebluetooth_mac`
- Ruby module: `CoreBluetoothMac`
- Swift package / dylib: `CoreBluetoothMac`
- C init function: `Init_corebluetooth_mac`

## 11. TDD Strategy (t-wada style)

The implementation is driven by **small Red → Green → Refactor cycles** with a "TODO list" maintained per phase. Each cycle:

1. Write **one** failing test (the smallest meaningful failure)
2. Make it pass with the **simplest possible code** — explicit license to use "仮実装" (fake it / return a constant) when that's the smallest step
3. Refactor only when there's actual duplication or unclear naming; never speculatively
4. Re-run **all** tests before moving on
5. Cross the item off the TODO list, add any new items discovered

### 11.1. Layers in TDD-friendliness order

| Layer | Tests live | Strategy |
|---|---|---|
| **L1: Pure Ruby value objects** (DiscoveredDevice, Subscription) | `test/unit/` | Classic RGR. Trivial. Includes `Ractor.shareable?` invariant. |
| **L2: Pure Ruby routing** (Peripheral, Service, Characteristic) | `test/unit/` with a stub Central recording `__call_native(:op, ...)` invocations | Mock at the routing seam, not at the Swift seam. Test that `peripheral.discover_services` ends up calling `central.__call_native(:peripheral_discover_services, identifier, timeout_ms)` with the right args. |
| **L3: C bridge + Swift skeleton** (Central allocator, error mapping, no real BLE) | `test/unit/` + a build step | First `Central.new` test asserts it raises `StateError` / `PermissionError` in a controlled way (we can force the Swift side to short-circuit on a `CBM_FAKE=1` env or, simpler, just trust the prompt + skip-if-no-hardware). |
| **L4: Real CoreBluetooth against CoreS3** | `test/integration/` | Walking-skeleton end-to-end test for Phase 1's success criterion is the **single most important driver**: write it first as a `:pending` test, then build everything underneath until it goes green. |

### 11.2. Hardware-dependent tests

```ruby
# test/test_helper.rb
module HardwareGuard
  def self.skip_unless_hardware!(test)
    return if ENV["BLE_HW"] == "1"
    test.omit "Set BLE_HW=1 with a CoreS3 advertising StackChan-PicoRuby nearby"
  end
end
```

- Integration tests call `HardwareGuard.skip_unless_hardware!(self)` in `setup`.
- The CoreS3 setup is documented in `stackchan-picoruby/CLAUDE.md` and `docs/superpowers/specs/2026-05-15-ble-phase1-rf-not-emitting-handoff.md`. The advertising window is 60s after `rake r2p2:reset` on the device side.
- Failure mode: integration tests **omit** with the operator instructions; they do not error. This complies with the project's "no silent rescue" rule because the skip reason is explicit and visible.

### 11.3. Phase 1 TODO list (red-green order)

```
Phase 1 — TODO
[ ] unit: CoreBluetoothMac::VERSION exists and is a String
[ ] unit: error classes form the documented hierarchy
[ ] unit: DiscoveredDevice value equality, frozen, Ractor.shareable?
[ ] build: extconf.rb generates a Makefile, `rake compile` produces lib/corebluetooth_mac/corebluetooth_mac.bundle (Swift hello-world @c roundtrip)
[ ] unit: Central.new can be called; raises StateError with descriptive message when Bluetooth is off / unauthorized (mock by setting env-controlled fake state in Swift)
[ ] integration (HW): Central.new succeeds when Bluetooth on and permission granted
[ ] integration (HW): central.scan(name: "StackChan-PicoRuby", timeout: 5.0) returns ≥1 DiscoveredDevice
[ ] unit: Peripheral routes discover_services to central.__call_native(:peripheral_discover_services, identifier, timeout_ms) (stub Central)
[ ] integration (HW): central.connect(device) returns Peripheral with state :connected
[ ] integration (HW): peripheral.discover_services finds GAP service 0x1800
[ ] integration (HW): service.discover_characteristics finds Device Name 0x2A00 with :read property
[ ] integration (HW): characteristic.read returns frozen String "StackChan-PicoRuby"
[ ] integration (HW): central.disconnect(peripheral) succeeds and peripheral.state == :disconnected
[ ] e2e: examples/scan_and_read.rb runs green against CoreS3
```

### 11.4. Phase 2 TODO list

```
Phase 2 — TODO
[ ] unit: Subscription.new(...) is Ractor.shareable?
[ ] unit: Characteristic#write(data, response: true) routes to native with correct args (stub Central)
[ ] build: SubscriptionRegistry Swift unit (XCTest? — skip, exercised via Ruby integration only)
[ ] integration (HW, needs CoreS3 Phase 2 NUS): characteristic.write writes a packet and target acks
[ ] integration (HW): write_without_response sends fire-and-forget
[ ] integration (HW): characteristic.subscribe returns Subscription with non-zero id
[ ] integration (HW): subscription.next_value(timeout: 5.0) returns the next notification
[ ] integration (HW): subscription.next_value(timeout: 0.1) returns nil on timeout
[ ] integration (HW): characteristic.unsubscribe causes pending next_value to return nil
[ ] integration (HW, Ractor): pumping subscription from a child Ractor delivers values to main via Ractor.yield/take
[ ] e2e: examples/subscribe_ractor.rb runs green
```

### 11.5. "仮実装 → 三角測量 → 明白な実装" examples

- DiscoveredDevice equality: first test asserts two with same UUID are `==`. Fake impl: `def ==(o); true; end`. Second test asserts two with different UUIDs are not `==`. Triangulate to real impl. (For `Data.define` this collapses to "use Data" but keep the discipline as practice.)
- `central.scan`: first test passes timeout=0 and asserts result is `[]` (hardware off mode). Then add a `name:` filter test against the real fixture. Don't reach for the full delegate plumbing until the second test forces it.

### 11.6. Safety nets

- `rake compile` must run **before** any test (`task test: :compile` in the Rakefile, exactly as FM has).
- Each commit corresponds to one green TODO checkbox (Conventional Commits: `test:` / `feat:` / `fix:` / `refactor:`).
- No commit lands a red test (CI-equivalent local rule).
- A long Swift build is wrapped per `~/dev/src/CLAUDE.md`'s `screen -dmS` longrun pattern only if it exceeds 2 minutes; expected to be <30s on M-series Mac so probably bypassable, but the pattern is available.

## 12. Bluetooth Permission UX (README must document)

- First `Central.new` triggers macOS "Allow … to use Bluetooth?" prompt. The prompt is bound to the *process* (Terminal.app, iTerm.app, VS Code, etc.), not to the gem.
- If denied, every subsequent `Central.new` raises `PermissionError` immediately. User must go to System Settings → Privacy & Security → Bluetooth and toggle their terminal app on.
- macOS may cache a stale permission state across reinstalls; `tccutil reset Bluetooth` clears it (mention as a footnote).
- `Info.plist` is not needed for a Ruby process because the prompt uses a system-default reason string. README should still suggest setting `LSEnvironment`-style description if the user ever wraps Ruby in an `.app`.

## 13. Open Questions / Future Work

1. **Concurrent reads on the same peripheral**: Phase 1/2 serialize. If a consumer ever needs parallel I/O across characteristics, we'd need to demultiplex `didUpdateValueFor` by `(characteristic.uuid, op_token)`. Defer.
2. **Reconnection / cached peripheral retrieval**: `retrievePeripherals(withIdentifiers:)` would let users skip rescanning a known device. Not in either phase. Worth adding when Sinatra server wants persistent device pairing across restarts.
3. **Advertisement data beyond name/RSSI**: manufacturer data, service data, tx power. Useful for sensor beacons. Not in scope.
4. **MTU / connection parameters**: CoreBluetooth exposes `maximumWriteValueLength(for:)`. Phase 2 should surface this so consumers can chunk writes. Tracked as a Phase 2 nice-to-have, not a TODO.
5. **`indicate` vs `notify`**: both surface via the same delegate callback; we don't currently distinguish on Ruby side. `Characteristic#properties` exposes `:indicate` but `subscribe` treats them the same. OK for the StackChan use case.

## 14. Approval gate

This design intentionally locks:

- Object model (Approach 3 hybrid)
- Notify delivery model (Ractor-friendly poll-style, no Threads/Ractors inside the gem)
- C ABI shape (JSON across the boundary, integer subscription IDs)
- Swift syntax (`@c` per SE-0495, no `@_cdecl`)
- TDD discipline (t-wada style, per-phase TODO list, walking skeleton anchored on `examples/scan_and_read.rb`)

Next step on approval: invoke `superpowers:writing-plans` to produce the executable plan, then `superpowers:executing-plans` (or `subagent-driven-development`) to drive the cycles.
