import CoreBluetooth
import Foundation
import os

/// The tag of an event in a peripheral's event queue, as Ruby receives it.
enum PeripheralEventTag: String {
    case nameUpdated         = "name_updated"
    case servicesInvalidated = "services_invalidated"
    case disconnected        = "disconnected"
}

/// A peripheral's event queue and the semaphore whose count equals the queue length.
struct PeripheralEventState: @unchecked Sendable {
    var queue: [(tag: PeripheralEventTag, payload: [String: Any])] = []
    let sem = DispatchSemaphore(value: 0)
}

/// The `CBPeripheralDelegate` of one peripheral, holding the result and semaphore of each pending operation.
final class CBMPeripheralDelegate: NSObject, CBPeripheralDelegate, @unchecked Sendable {
    static let eventQueueLimit = 256

    let peripheral: CBPeripheral

    let connectSem = DispatchSemaphore(value: 0)
    var connectError: Error? = nil
    var connected: Bool = false

    let servicesSem = DispatchSemaphore(value: 0)
    var servicesError: Error? = nil

    let charsSem = DispatchSemaphore(value: 0)
    var charsError: Error? = nil
    var charsServiceUUID: CBUUID? = nil

    let readSem = DispatchSemaphore(value: 0)
    var readError: Error? = nil
    var readValue: Data? = nil
    var readCharUUID: CBUUID? = nil

    let writeSem = DispatchSemaphore(value: 0)
    var writeError: Error? = nil
    var writeCharUUID: CBUUID? = nil

    let wwrReadySem = DispatchSemaphore(value: 0)

    let notifySem = DispatchSemaphore(value: 0)
    var notifyError: Error? = nil
    var notifyCharUUID: CBUUID? = nil

    let includedSvcSem = DispatchSemaphore(value: 0)
    var includedSvcError: Error? = nil
    var includedSvcUUID: CBUUID? = nil

    let rssiSem = DispatchSemaphore(value: 0)
    let rssiLock = OSAllocatedUnfairLock<Result<Int, CBMError>?>(initialState: nil)

    let descriptorsSem = DispatchSemaphore(value: 0)
    let descriptorsLock = OSAllocatedUnfairLock<Result<[String], CBMError>?>(initialState: nil)
    var descriptorsCharUUID: String? = nil

    let descriptorReadSem = DispatchSemaphore(value: 0)
    let descriptorReadLock = OSAllocatedUnfairLock<Result<Data, CBMError>?>(initialState: nil)
    var descriptorReadUUID: String? = nil

    let descriptorWriteSem = DispatchSemaphore(value: 0)
    let descriptorWriteLock = OSAllocatedUnfairLock<Result<Void, CBMError>?>(initialState: nil)
    var descriptorWriteUUID: String? = nil

    let lastDisconnectInfo = OSAllocatedUnfairLock<NSError?>(initialState: nil)

    let events = OSAllocatedUnfairLock<PeripheralEventState>(initialState: PeripheralEventState())

    /// Appends an event, dropping the oldest one when the queue holds ``eventQueueLimit`` events.
    func pushEvent(tag: PeripheralEventTag, payload: [String: Any]) {
        let payloadBox = Box(payload)
        let signalSem: DispatchSemaphore? = events.withLock { state in
            let isOverflow = state.queue.count >= Self.eventQueueLimit
            if isOverflow { state.queue.removeFirst() }
            state.queue.append((tag: tag, payload: payloadBox.value))
            return isOverflow ? nil : state.sem
        }
        signalSem?.signal()
    }

    /// Takes the oldest event, waiting up to `timeoutMs` milliseconds for one.
    ///
    /// - Returns: The event's tag and payload, or `nil` when none arrives in time.
    func pollEvent(timeoutMs: Int32, cancel: CBMCancel) -> (tag: String, payload: [String: Any])? {
        let sem = events.withLock { $0.sem }
        if cancel.wait(sem, until: deadline(timeoutMs)) == .timedOut { return nil }
        let event: Box<(PeripheralEventTag, [String: Any])>? = events.withLock { state in
            state.queue.isEmpty ? nil : Box(state.queue.removeFirst())
        }
        return event.map { ($0.value.0.rawValue, $0.value.1) }
    }

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    func peripheralDidUpdateName(_ p: CBPeripheral) {
        pushEvent(tag: .nameUpdated, payload: ["name": p.name ?? ""])
    }

    func peripheral(_ p: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        pushEvent(tag: .servicesInvalidated, payload: ["uuids": invalidatedServices.map { $0.uuid.uuidString.lowercased() }])
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        servicesError = error
        servicesSem.signal()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if charsServiceUUID == service.uuid {
            charsError = error
            charsSem.signal()
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?) {
        if includedSvcUUID == service.uuid {
            includedSvcError = error
            includedSvcSem.signal()
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if readCharUUID == characteristic.uuid {
            readError = error
            readValue = characteristic.value
            readSem.signal()
            return
        }
        CBMSubscriptionRegistry.shared.enqueue(characteristic: characteristic)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if writeCharUUID == characteristic.uuid {
            writeError = error
            writeSem.signal()
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        wwrReadySem.signal()
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if notifyCharUUID == characteristic.uuid {
            notifyError = error
            notifySem.signal()
        }
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        rssiLock.withLock {
            $0 = error.map { .failure(CBMError.from($0 as NSError, fallbackDomain: "discovery")) } ?? .success(RSSI.intValue)
        }
        rssiSem.signal()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid.uuidString == descriptorsCharUUID else { return }
        let uuids = (characteristic.descriptors ?? []).map { $0.uuid.uuidString.lowercased() }
        descriptorsLock.withLock {
            $0 = error.map { .failure(CBMError.from($0 as NSError, fallbackDomain: "discovery")) } ?? .success(uuids)
        }
        descriptorsSem.signal()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        guard descriptor.uuid.uuidString.lowercased() == descriptorReadUUID else { return }
        let data: Data
        switch descriptor.value {
        case let d as Data:
            data = d
        case let n as NSNumber:
            var v = n.uint16Value.littleEndian
            data = Data(bytes: &v, count: 2)
        case let s as String:
            data = Data(s.utf8)
        default:
            data = Data()
        }
        descriptorReadLock.withLock {
            $0 = error.map { .failure(CBMError.from($0 as NSError, fallbackDomain: "cb")) } ?? .success(data)
        }
        descriptorReadSem.signal()
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        guard descriptor.uuid.uuidString.lowercased() == descriptorWriteUUID else { return }
        descriptorWriteLock.withLock {
            $0 = error.map { .failure(CBMError.from($0 as NSError, fallbackDomain: "cb")) } ?? .success(())
        }
        descriptorWriteSem.signal()
    }
}
