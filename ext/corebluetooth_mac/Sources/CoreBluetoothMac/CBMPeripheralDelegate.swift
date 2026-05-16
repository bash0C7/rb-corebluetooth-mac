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
}
