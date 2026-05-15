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

    private let delegatesLock = OSAllocatedUnfairLock<[UUID: CBMPeripheralDelegate]>(initialState: [:])

    func delegate(for identifier: UUID) -> CBMPeripheralDelegate? {
        return delegatesLock.withLock { $0[identifier] }
    }

    func peripheral(identifier: String) -> (CBPeripheral, CBMPeripheralDelegate)? {
        guard let uuid = UUID(uuidString: identifier) else { return nil }
        let p: CBPeripheral? = knownPeripherals.withLock { $0[uuid] }
        guard let peripheral = p else { return nil }
        let d = delegatesLock.withLock { dict -> CBMPeripheralDelegate in
            if let existing = dict[uuid] { return existing }
            let nd = CBMPeripheralDelegate(peripheral: peripheral)
            dict[uuid] = nd
            return nd
        }
        return (peripheral, d)
    }

    func connect(identifier: String, timeoutMs: Int32) -> CBMError? {
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .connection("Unknown peripheral identifier \(identifier); scan first.")
        }
        d.connectError = nil
        d.connected = false
        manager.connect(p, options: nil)
        let r = d.connectSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
        if r == .timedOut { manager.cancelPeripheralConnection(p); return .timeout("connect timed out after \(timeoutMs)ms") }
        if let e = d.connectError { return .connection(e.localizedDescription) }
        if !d.connected { return .connection("connect signalled but state is not connected") }
        return nil
    }

    func disconnect(identifier: String) -> CBMError? {
        guard let (p, _) = peripheral(identifier: identifier) else {
            return .closed("Unknown peripheral identifier \(identifier).")
        }
        manager.cancelPeripheralConnection(p)
        return nil
    }

    func peripheralState(identifier: String) -> String {
        guard let (p, _) = peripheral(identifier: identifier) else { return "unknown" }
        switch p.state {
        case .disconnected:  return "disconnected"
        case .connecting:    return "connecting"
        case .connected:     return "connected"
        case .disconnecting: return "disconnecting"
        @unknown default:    return "unknown"
        }
    }

    func discoverServices(identifier: String, timeoutMs: Int32) -> Result<[String], CBMError> {
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .failure(.closed("Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.connection("Peripheral not connected")) }
        d.servicesError = nil
        p.discoverServices(nil)
        let r = d.servicesSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
        if r == .timedOut { return .failure(.timeout("discoverServices timed out after \(timeoutMs)ms")) }
        if let e = d.servicesError { return .failure(.discovery(e.localizedDescription)) }
        let uuids = (p.services ?? []).map { $0.uuid.uuidString.lowercased() }
        return .success(uuids)
    }

    func discoverCharacteristics(identifier: String, serviceUUID: String, timeoutMs: Int32)
        -> Result<[[String: Any]], CBMError>
    {
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .failure(.closed("Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.connection("Peripheral not connected")) }
        let targetUUID = CBUUID(string: serviceUUID)
        guard let service = (p.services ?? []).first(where: { $0.uuid == targetUUID }) else {
            return .failure(.discovery("Service \(serviceUUID) not found on peripheral"))
        }
        d.charsServiceUUID = targetUUID
        d.charsError = nil
        p.discoverCharacteristics(nil, for: service)
        let r = d.charsSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
        d.charsServiceUUID = nil
        if r == .timedOut { return .failure(.timeout("discoverCharacteristics timed out after \(timeoutMs)ms")) }
        if let e = d.charsError { return .failure(.discovery(e.localizedDescription)) }
        let arr: [[String: Any]] = (service.characteristics ?? []).map { ch in
            var props: [String] = []
            if ch.properties.contains(.read)                 { props.append("read") }
            if ch.properties.contains(.write)                { props.append("write") }
            if ch.properties.contains(.writeWithoutResponse) { props.append("write_without_response") }
            if ch.properties.contains(.notify)               { props.append("notify") }
            if ch.properties.contains(.indicate)             { props.append("indicate") }
            return ["uuid": ch.uuid.uuidString.lowercased(), "properties": props]
        }
        return .success(arr)
    }

    // MARK: CBCentralManagerDelegate – connect lifecycle

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        if let d = delegate(for: p.identifier) {
            d.connected = true
            d.connectError = nil
            d.connectSem.signal()
        }
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if let d = delegate(for: p.identifier) {
            d.connected = false
            d.connectError = error ?? NSError(domain: "CBM", code: -1)
            d.connectSem.signal()
        }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if let d = delegate(for: p.identifier) {
            d.connected = false
            // If a connect was pending, surface the error.
            if d.connectError == nil && error != nil {
                d.connectError = error
                d.connectSem.signal()
            }
        }
    }
}
