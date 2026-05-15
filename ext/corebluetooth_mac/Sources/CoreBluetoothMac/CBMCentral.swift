import Foundation
@preconcurrency import CoreBluetooth
import os

final class CBMCentral: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    static let idCounter = OSAllocatedUnfairLock<Int64>(initialState: 0)

    let centralId: Int64
    let manager: CBCentralManager
    let queue: DispatchQueue

    private let stateLock = OSAllocatedUnfairLock<CBManagerState>(initialState: .unknown)
    private let stateSem = DispatchSemaphore(value: 0)

    override init() {
        // Assign a unique id atomically.
        let assigned: Int64 = Self.idCounter.withLock { state in
            state += 1
            return state
        }
        self.centralId = assigned
        self.queue = DispatchQueue(label: "corebluetoothmac.central.\(assigned)")
        self.manager = CBCentralManager(delegate: nil, queue: self.queue)
        super.init()
        self.manager.delegate = self
    }

    func awaitPoweredOn(timeoutMs: Int32) -> CBMError? {
        let deadline = DispatchTime.now() + .milliseconds(Int(timeoutMs))
        while true {
            let cur = stateLock.withLock { $0 }
            switch cur {
            case .poweredOn:    return nil
            case .unauthorized: return .permission("Bluetooth permission denied. Open System Settings → Privacy & Security → Bluetooth and enable your terminal application.")
            case .unsupported:  return .state("Bluetooth is not supported on this machine.")
            case .poweredOff:   return .state("Bluetooth is off. Turn it on in Control Center / System Settings.")
            case .resetting:    return .state("Bluetooth is resetting; try again.")
            case .unknown:      break  // wait
            @unknown default:   break
            }
            let r = stateSem.wait(timeout: deadline)
            if r == .timedOut {
                return .timeout("Bluetooth state did not reach poweredOn within \(timeoutMs)ms")
            }
        }
    }

    struct ScanResult {
        let identifier: String
        let name: String?
        let rssi: Int
    }

    // All mutable state lives inside its lock to satisfy Swift 6 strict-concurrency
    // (same pattern as `idCounter` in Task 11). A `var` + side-lock would emit
    // "stored property of Sendable type" errors on a `@unchecked Sendable` class.
    private let scanLock = OSAllocatedUnfairLock<[String: ScanResult]>(initialState: [:])
    private let nameFilter = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let knownPeripherals = OSAllocatedUnfairLock<[UUID: CBPeripheral]>(initialState: [:])

    func scan(name: String?, services: [CBUUID]?, timeoutMs: Int32) -> [ScanResult] {
        scanLock.withLock { $0.removeAll() }
        nameFilter.withLock { $0 = name }
        let options: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        manager.scanForPeripherals(withServices: services, options: options)
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs))) { [weak self] in
            self?.manager.stopScan()
        }
        Thread.sleep(forTimeInterval: TimeInterval(timeoutMs) / 1000.0)
        manager.stopScan()
        return scanLock.withLock { Array($0.values) }
    }

    func scanResultsAsJSON(_ results: [ScanResult]) -> String {
        let arr: [[String: Any]] = results.map { r in
            var d: [String: Any] = ["identifier": r.identifier, "rssi": r.rssi]
            if let n = r.name { d["name"] = n }
            return d
        }
        let data = try! JSONSerialization.data(withJSONObject: arr)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        stateLock.withLock { $0 = central.state }
        stateSem.signal()
    }

    // MARK: - Scan delegate

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let filter = nameFilter.withLock { $0 }
        if let filter = filter, name != filter { return }

        knownPeripherals.withLock { state in
            if state[peripheral.identifier] == nil {
                state[peripheral.identifier] = peripheral
            }
        }
        let r = ScanResult(identifier: peripheral.identifier.uuidString, name: name, rssi: RSSI.intValue)
        scanLock.withLock { $0[peripheral.identifier.uuidString] = r }
    }
}
