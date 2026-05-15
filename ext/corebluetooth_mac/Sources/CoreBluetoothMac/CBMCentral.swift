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

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        stateLock.withLock { $0 = central.state }
        stateSem.signal()
    }
}
