import Foundation
@preconcurrency import CoreBluetooth
import os

// Tags emitted to the Ruby side via the event queue. `rawValue` is the
// snake_case string the Ruby `Peripheral#poll_events` dispatcher matches on
// (handoff §4.1 — Ruby idiom + envelope JSON convention).
enum PeripheralEventTag: String {
    case nameUpdated         = "name_updated"
    case servicesInvalidated = "services_invalidated"
    case disconnected        = "disconnected"
}

// State held inside the typed lock. Bound semaphore lives alongside the queue
// so producer/consumer share both atomically.
// `@unchecked Sendable` because the queue stores `[String: Any]` payloads
// (Apple SDK types — NSNull, etc.) which aren't statically Sendable. All
// mutation goes through OSAllocatedUnfairLock<PeripheralEventState> so this
// is safe (mirrors the @unchecked Sendable pattern on CBMPeripheralDelegate itself).
struct PeripheralEventState: @unchecked Sendable {
    var queue: [(tag: PeripheralEventTag, payload: [String: Any])] = []
    let sem = DispatchSemaphore(value: 0)
}

final class CBMPeripheralDelegate: NSObject, CBPeripheralDelegate, @unchecked Sendable {
    let peripheral: CBPeripheral

    // Connect
    let connectSem = DispatchSemaphore(value: 0)
    var connectError: Error? = nil
    var connected: Bool = false

    // Discover services
    let servicesSem = DispatchSemaphore(value: 0)
    var servicesError: Error? = nil

    // Discover characteristics (per service)
    let charsSem = DispatchSemaphore(value: 0)
    var charsError: Error? = nil
    var charsServiceUUID: CBUUID? = nil

    // Read
    let readSem = DispatchSemaphore(value: 0)
    var readError: Error? = nil
    var readValue: Data? = nil
    var readCharUUID: CBUUID? = nil

    // Write (with response)
    let writeSem = DispatchSemaphore(value: 0)
    var writeError: Error? = nil
    var writeCharUUID: CBUUID? = nil

    // Notify state change
    let notifySem = DispatchSemaphore(value: 0)
    var notifyError: Error? = nil
    var notifyCharUUID: CBUUID? = nil

    // Discover included services (per service)
    let includedSvcSem = DispatchSemaphore(value: 0)
    var includedSvcError: Error? = nil
    var includedSvcUUID: CBUUID? = nil

    // Read RSSI
    let rssiSem = DispatchSemaphore(value: 0)
    let rssiLock = OSAllocatedUnfairLock<Result<Int, CBMError>?>(initialState: nil)

    // Discover descriptors (per characteristic)
    let descriptorsSem = DispatchSemaphore(value: 0)
    let descriptorsLock = OSAllocatedUnfairLock<Result<[String], CBMError>?>(initialState: nil)
    var descriptorsCharUUID: String? = nil

    // Read descriptor value
    let descriptorReadSem = DispatchSemaphore(value: 0)
    let descriptorReadLock = OSAllocatedUnfairLock<Result<Data, CBMError>?>(initialState: nil)
    var descriptorReadUUID: String? = nil

    // Write descriptor value
    let descriptorWriteSem = DispatchSemaphore(value: 0)
    let descriptorWriteLock = OSAllocatedUnfairLock<Result<Void, CBMError>?>(initialState: nil)
    var descriptorWriteUUID: String? = nil

    // Disconnect error (populated by centralManager(_:didDisconnectPeripheral:error:))
    let lastDisconnectInfo = OSAllocatedUnfairLock<NSError?>(initialState: nil)

    // Event queue (name_updated / services_invalidated / disconnected) drained
    // by `cbm_peripheral_poll_events`. Typed lock + bound DispatchSemaphore for
    // bounded-wait dequeue. Bound is 256; older events are dropped on overflow.
    let events = OSAllocatedUnfairLock<PeripheralEventState>(initialState: PeripheralEventState())

    func pushEvent(tag: PeripheralEventTag, payload: [String: Any]) {
        // Box the payload because `[String: Any]` (Apple SDK NSNull / NSError
        // hash values) is not Sendable; the typed lock's withLock closure
        // requires a Sendable return. Box<T> is the project's @unchecked
        // Sendable wrapper (see CBMSync.swift).
        let payloadBox = Box(payload)
        let sem: DispatchSemaphore = events.withLock { state in
            state.queue.append((tag: tag, payload: payloadBox.value))
            if state.queue.count > 256 { state.queue.removeFirst() }  // drop oldest on overflow
            return state.sem
        }
        sem.signal()
    }

    func pollEvent(timeoutMs: Int32) -> (tag: String, payload: [String: Any])? {
        // Fast path: already-queued event, no wait. Return a Box from inside
        // the lock to satisfy Sendable; unwrap outside the closure.
        let fastPath: Box<(PeripheralEventTag, [String: Any])>? = events.withLock { state in
            state.queue.isEmpty ? nil : Box(state.queue.removeFirst())
        }
        if let immediate = fastPath {
            return (immediate.value.0.rawValue, immediate.value.1)
        }
        let sem = events.withLock { $0.sem }
        let r = sem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
        if r == .timedOut { return nil }
        let waited: Box<(PeripheralEventTag, [String: Any])>? = events.withLock { state in
            state.queue.isEmpty ? nil : Box(state.queue.removeFirst())
        }
        guard let e = waited else { return nil }
        return (e.value.0.rawValue, e.value.1)
    }

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    // MARK: CBPeripheralDelegate

    // CBPeripheralDelegate `peripheralDidUpdateName:` — Apple SDK
    // CBPeripheral.h L282. Pushes a `name_updated` event with the new name
    // (empty string if peripheral.name is nil — payload key always present).
    func peripheralDidUpdateName(_ p: CBPeripheral) {
        pushEvent(tag: .nameUpdated, payload: ["name": p.name ?? ""])
    }

    // CBPeripheralDelegate `peripheral:didModifyServices:` — Apple SDK
    // CBPeripheral.h L294. Pushes a `services_invalidated` event carrying the
    // lowercased UUID strings of the invalidated services.
    func peripheral(_ p: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        let uuids = invalidatedServices.map { $0.uuid.uuidString.lowercased() }
        pushEvent(tag: .servicesInvalidated, payload: ["uuids": uuids])
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        servicesError = error
        servicesSem.signal()
    }

    func peripheral(_ p: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if charsServiceUUID == service.uuid {
            charsError = error
            charsSem.signal()
        }
    }

    func peripheral(_ p: CBPeripheral,
                    didDiscoverIncludedServicesFor service: CBService,
                    error: Error?) {
        if includedSvcUUID == service.uuid {
            includedSvcError = error
            includedSvcSem.signal()
        }
    }

    func peripheral(_ p: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        // Read result OR notification
        if readCharUUID == characteristic.uuid {
            readError = error
            readValue = characteristic.value
            readSem.signal()
            return
        }
        // Notify path: hand off to SubscriptionRegistry (Task 18+)
        CBMSubscriptionRegistry.shared.enqueue(
            characteristic: characteristic, error: error
        )
    }

    func peripheral(_ p: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if writeCharUUID == characteristic.uuid {
            writeError = error
            writeSem.signal()
        }
    }

    func peripheral(_ p: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if notifyCharUUID == characteristic.uuid {
            notifyError = error
            notifySem.signal()
        }
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let e = error {
            rssiLock.withLock { $0 = .failure(CBMError.from(e as NSError, fallbackDomain: "discovery")) }
        } else {
            rssiLock.withLock { $0 = .success(RSSI.intValue) }
        }
        rssiSem.signal()
    }

    func peripheral(_ p: CBPeripheral,
                    didDiscoverDescriptorsFor characteristic: CBCharacteristic,
                    error: Error?) {
        let charUUIDStr = characteristic.uuid.uuidString
        guard charUUIDStr == descriptorsCharUUID else { return }
        if let e = error {
            descriptorsLock.withLock { $0 = .failure(CBMError.from(e as NSError, fallbackDomain: "discovery")) }
        } else {
            let uuids = (characteristic.descriptors ?? []).map { $0.uuid.uuidString.lowercased() }
            descriptorsLock.withLock { $0 = .success(uuids) }
        }
        descriptorsSem.signal()
    }

    func peripheral(_ p: CBPeripheral,
                    didUpdateValueFor descriptor: CBDescriptor,
                    error: Error?) {
        let descUUIDStr = descriptor.uuid.uuidString.lowercased()
        guard descUUIDStr == descriptorReadUUID else { return }
        if let e = error {
            descriptorReadLock.withLock { $0 = .failure(CBMError.from(e as NSError, fallbackDomain: "cb")) }
        } else {
            // CBDescriptor.value can be various types depending on descriptor type.
            // We serialize to Data for a uniform binary representation.
            let data: Data
            if let d = descriptor.value as? Data {
                data = d
            } else if let n = descriptor.value as? NSNumber {
                var v = n.uint16Value.littleEndian
                data = Data(bytes: &v, count: 2)
            } else if let s = descriptor.value as? String, let d = s.data(using: .utf8) {
                data = d
            } else {
                data = Data()
            }
            descriptorReadLock.withLock { $0 = .success(data) }
        }
        descriptorReadSem.signal()
    }

    func peripheral(_ p: CBPeripheral,
                    didWriteValueFor descriptor: CBDescriptor,
                    error: Error?) {
        let descUUIDStr = descriptor.uuid.uuidString.lowercased()
        guard descUUIDStr == descriptorWriteUUID else { return }
        if let e = error {
            descriptorWriteLock.withLock { $0 = .failure(CBMError.from(e as NSError, fallbackDomain: "cb")) }
        } else {
            descriptorWriteLock.withLock { $0 = .success(()) }
        }
        descriptorWriteSem.signal()
    }
}
