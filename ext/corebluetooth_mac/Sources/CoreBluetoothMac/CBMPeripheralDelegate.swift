import Foundation
@preconcurrency import CoreBluetooth
import os

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

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    // MARK: CBPeripheralDelegate

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
