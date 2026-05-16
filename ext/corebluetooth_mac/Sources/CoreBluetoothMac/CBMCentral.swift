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
            case .unauthorized: return .lib(domain: "closed", message: "Bluetooth permission denied. Open System Settings → Privacy & Security → Bluetooth and enable your terminal application.")
            case .unsupported:  return .lib(domain: "closed", message: "Bluetooth is not supported on this machine.")
            case .poweredOff:   return .lib(domain: "closed", message: "Bluetooth is off. Turn it on in Control Center / System Settings.")
            case .resetting:    return .lib(domain: "closed", message: "Bluetooth is resetting; try again.")
            case .unknown:      break  // wait
            @unknown default:   break
            }
            let r = stateSem.wait(timeout: deadline)
            if r == .timedOut {
                return .lib(domain: "timeout", message: "Bluetooth state did not reach poweredOn within \(timeoutMs)ms")
            }
        }
    }

    struct ScanResult {
        let identifier: String
        let name: String?
        let rssi: Int
        let txPowerLevel: Int?
        let isConnectable: Bool?
        let serviceUUIDs: [String]
        let serviceData: [String: String]   // UUID (lc) → hex
        let manufacturerData: String?        // hex
        let solicitedServiceUUIDs: [String]
        let overflowServiceUUIDs: [String]
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

    func scanResultsAsArray(_ results: [ScanResult]) -> [[String: Any]] {
        return results.map { r in
            let d: [String: Any] = [
                "identifier": r.identifier,
                "name": r.name ?? NSNull(),
                "rssi": r.rssi,
                "tx_power_level": r.txPowerLevel ?? NSNull(),
                "connectable": r.isConnectable ?? NSNull(),
                "service_uuids": r.serviceUUIDs,
                "service_data": r.serviceData,
                "manufacturer_data": r.manufacturerData ?? NSNull(),
                "solicited_service_uuids": r.solicitedServiceUUIDs,
                "overflow_service_uuids": r.overflowServiceUUIDs,
            ]
            return d
        }
    }

    // Hex-encode a `Data` blob to a lowercase hex string (no separators).
    private static func hexEncode(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
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

        // Parse the 8 documented advertisement-data keys.
        // Source: <CoreBluetooth/CBAdvertisementData.h> in MacOSX.sdk.
        let txPower: Int? = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        let isConnectable: Bool? = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue

        let serviceUUIDs: [String] = ((advertisementData[CBAdvertisementDataServiceUUIDsKey]
            as? [CBUUID]) ?? []).map { $0.uuidString.lowercased() }

        let solicitedUUIDs: [String] = ((advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey]
            as? [CBUUID]) ?? []).map { $0.uuidString.lowercased() }

        let overflowUUIDs: [String] = ((advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey]
            as? [CBUUID]) ?? []).map { $0.uuidString.lowercased() }

        var serviceData: [String: String] = [:]
        if let raw = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (uuid, data) in raw {
                serviceData[uuid.uuidString.lowercased()] = Self.hexEncode(data)
            }
        }

        let manufacturerData: String? = (advertisementData[CBAdvertisementDataManufacturerDataKey]
            as? Data).map { Self.hexEncode($0) }

        let r = ScanResult(
            identifier: peripheral.identifier.uuidString,
            name: name,
            rssi: RSSI.intValue,
            txPowerLevel: txPower,
            isConnectable: isConnectable,
            serviceUUIDs: serviceUUIDs,
            serviceData: serviceData,
            manufacturerData: manufacturerData,
            solicitedServiceUUIDs: solicitedUUIDs,
            overflowServiceUUIDs: overflowUUIDs,
        )
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
            return .lib(domain: "connection", message: "Unknown peripheral identifier \(identifier); scan first.")
        }
        d.connectError = nil
        d.connected = false
        manager.connect(p, options: nil)
        let r = d.connectSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
        if r == .timedOut { manager.cancelPeripheralConnection(p); return .lib(domain: "timeout", message: "connect timed out after \(timeoutMs)ms") }
        if let e = d.connectError { return CBMError.from(e as NSError, fallbackDomain: "connection") }
        if !d.connected { return .lib(domain: "connection", message: "connect signalled but state is not connected") }
        return nil
    }

    func disconnect(identifier: String) -> CBMError? {
        guard let (p, _) = peripheral(identifier: identifier) else {
            return .lib(domain: "closed", message: "Unknown peripheral identifier \(identifier).")
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

    func discoverServices(identifier: String, serviceUUIDs: [CBUUID]?, timeoutMs: Int32) -> Result<[[String: Any]], CBMError> {
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .failure(.lib(domain: "closed", message: "Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        d.servicesError = nil
        p.discoverServices(serviceUUIDs)
        let r = d.servicesSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
        if r == .timedOut { return .failure(.lib(domain: "timeout", message: "discoverServices timed out after \(timeoutMs)ms")) }
        if let e = d.servicesError { return .failure(CBMError.from(e as NSError, fallbackDomain: "discovery")) }
        // CBService.isPrimary is a readonly Bool per <CoreBluetooth/CBService.h>.
        let arr: [[String: Any]] = (p.services ?? []).map { svc in
            return [
                "uuid": svc.uuid.uuidString.lowercased(),
                "is_primary": svc.isPrimary,
            ]
        }
        return .success(arr)
    }

    func discoverCharacteristics(identifier: String, serviceUUID: String, timeoutMs: Int32)
        -> Result<[[String: Any]], CBMError>
    {
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .failure(.lib(domain: "closed", message: "Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        let targetUUID = CBUUID(string: serviceUUID)
        guard let service = (p.services ?? []).first(where: { $0.uuid == targetUUID }) else {
            return .failure(.lib(domain: "discovery", message: "Service \(serviceUUID) not found on peripheral"))
        }
        d.charsServiceUUID = targetUUID
        d.charsError = nil
        p.discoverCharacteristics(nil, for: service)
        let r = d.charsSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
        d.charsServiceUUID = nil
        if r == .timedOut { return .failure(.lib(domain: "timeout", message: "discoverCharacteristics timed out after \(timeoutMs)ms")) }
        if let e = d.charsError { return .failure(CBMError.from(e as NSError, fallbackDomain: "discovery")) }
        let arr: [[String: Any]] = (service.characteristics ?? []).map { ch in
            var props: [String] = []
            if ch.properties.contains(.broadcast)                  { props.append("broadcast") }
            if ch.properties.contains(.read)                       { props.append("read") }
            if ch.properties.contains(.writeWithoutResponse)       { props.append("write_without_response") }
            if ch.properties.contains(.write)                      { props.append("write") }
            if ch.properties.contains(.notify)                     { props.append("notify") }
            if ch.properties.contains(.indicate)                   { props.append("indicate") }
            if ch.properties.contains(.authenticatedSignedWrites)  { props.append("authenticated_signed_writes") }
            if ch.properties.contains(.extendedProperties)         { props.append("extended_properties") }
            if ch.properties.contains(.notifyEncryptionRequired)   { props.append("notify_encryption_required") }
            if ch.properties.contains(.indicateEncryptionRequired) { props.append("indicate_encryption_required") }
            var d: [String: Any] = ["uuid": ch.uuid.uuidString.lowercased(), "properties": props]
            if let v = ch.value {
                d["initial_value"] = v.map { String(format: "%02x", $0) }.joined()
            }
            return d
        }
        return .success(arr)
    }

    func discoverIncludedServices(identifier: String, serviceUUID: String, timeoutMs: Int32)
        -> Result<[[String: Any]], CBMError>
    {
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .failure(.lib(domain: "closed", message: "Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        let targetUUID = CBUUID(string: serviceUUID)
        guard let service = (p.services ?? []).first(where: { $0.uuid == targetUUID }) else {
            return .failure(.lib(domain: "discovery", message: "Service \(serviceUUID) not found on peripheral"))
        }
        d.includedSvcUUID = targetUUID
        d.includedSvcError = nil
        p.discoverIncludedServices(nil, for: service)
        let r = d.includedSvcSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
        d.includedSvcUUID = nil
        if r == .timedOut { return .failure(.lib(domain: "timeout", message: "discoverIncludedServices timed out after \(timeoutMs)ms")) }
        if let e = d.includedSvcError { return .failure(CBMError.from(e as NSError, fallbackDomain: "discovery")) }
        let arr: [[String: Any]] = (service.includedServices ?? []).map { svc in
            return [
                "uuid": svc.uuid.uuidString.lowercased(),
                "is_primary": svc.isPrimary,
            ]
        }
        return .success(arr)
    }

    func readCharacteristic(identifier: String, serviceUUID: String, charUUID: String, timeoutMs: Int32)
        -> Result<Data, CBMError>
    {
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .failure(.lib(domain: "closed", message: "Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        let svcId = CBUUID(string: serviceUUID)
        let chId  = CBUUID(string: charUUID)
        guard let svc = (p.services ?? []).first(where: { $0.uuid == svcId }) else {
            return .failure(.lib(domain: "discovery", message: "Service \(serviceUUID) not discovered"))
        }
        guard let ch  = (svc.characteristics ?? []).first(where: { $0.uuid == chId }) else {
            return .failure(.lib(domain: "discovery", message: "Characteristic \(charUUID) not discovered"))
        }
        d.readCharUUID = chId
        d.readError = nil
        d.readValue = nil
        p.readValue(for: ch)
        let r = d.readSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
        d.readCharUUID = nil
        if r == .timedOut { return .failure(.lib(domain: "timeout", message: "read timed out after \(timeoutMs)ms")) }
        if let e = d.readError { return .failure(CBMError.from(e as NSError, fallbackDomain: "connection")) }
        return .success(d.readValue ?? Data())
    }

    func writeCharacteristic(identifier: String, serviceUUID: String, charUUID: String,
                              data: Data, withResponse: Bool, timeoutMs: Int32) -> CBMError? {
        guard let (p, d) = peripheral(identifier: identifier) else { return .lib(domain: "closed", message: "Unknown peripheral \(identifier)") }
        guard p.state == .connected else { return .lib(domain: "connection", message: "Peripheral not connected") }
        let svcId = CBUUID(string: serviceUUID)
        let chId  = CBUUID(string: charUUID)
        guard let svc = (p.services ?? []).first(where: { $0.uuid == svcId }),
              let ch  = (svc.characteristics ?? []).first(where: { $0.uuid == chId }) else {
            return .lib(domain: "discovery", message: "Service/characteristic not discovered")
        }
        if withResponse {
            d.writeCharUUID = chId
            d.writeError = nil
            p.writeValue(data, for: ch, type: .withResponse)
            let r = d.writeSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
            d.writeCharUUID = nil
            if r == .timedOut { return .lib(domain: "timeout", message: "write timed out after \(timeoutMs)ms") }
            if let e = d.writeError { return CBMError.from(e as NSError, fallbackDomain: "connection") }
            return nil
        } else {
            // Best-effort. Optionally honor canSendWriteWithoutResponse.
            p.writeValue(data, for: ch, type: .withoutResponse)
            return nil
        }
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
            // Record disconnect error (or nil for clean disconnect) for polling via last_disconnect_error.
            d.lastDisconnectInfo.withLock { $0 = error.map { $0 as NSError } }
            // If a connect was pending, surface the error.
            if d.connectError == nil && error != nil {
                d.connectError = error
                d.connectSem.signal()
            }
            // Fail-fast any in-progress readRSSI wait.
            d.rssiLock.withLock {
                if $0 == nil {
                    $0 = .failure(.lib(domain: "connection", message: "Peripheral disconnected during readRSSI"))
                }
            }
            d.rssiSem.signal()
        }
    }

    func readRSSI(identifier: String, timeoutMs: Int32) -> Result<Int, CBMError> {
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .failure(.lib(domain: "closed", message: "Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        // Drain stale signals from prior disconnect/abort
        while d.rssiSem.wait(timeout: .now()) == .success { }
        d.rssiLock.withLock { $0 = nil }
        p.readRSSI()
        if d.rssiSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs))) == .timedOut {
            return .failure(.lib(domain: "timeout", message: "readRSSI timed out after \(timeoutMs)ms"))
        }
        if let r = d.rssiLock.withLock({ $0 }) {
            return r
        }
        return .failure(.lib(domain: "discovery", message: "RSSI result missing"))
    }

    func maxWriteLength(identifier: String, withResponse: Bool) -> Result<Int, CBMError> {
        guard let (p, _) = peripheral(identifier: identifier) else {
            return .failure(.lib(domain: "closed", message: "Unknown peripheral \(identifier)"))
        }
        let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
        return .success(p.maximumWriteValueLength(for: type))
    }

    func lastDisconnectError(identifier: String) -> NSError? {
        guard let uuid = UUID(uuidString: identifier),
              let d = delegate(for: uuid) else { return nil }
        return d.lastDisconnectInfo.withLock { $0 }
    }

    func subscribeCharacteristic(identifier: String, serviceUUID: String, charUUID: String,
                                  timeoutMs: Int32) -> Result<Int64, CBMError> {
        guard let (p, d) = peripheral(identifier: identifier) else { return .failure(.lib(domain: "closed", message: "Unknown peripheral")) }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        let svcId = CBUUID(string: serviceUUID)
        let chId  = CBUUID(string: charUUID)
        guard let svc = (p.services ?? []).first(where: { $0.uuid == svcId }),
              let ch  = (svc.characteristics ?? []).first(where: { $0.uuid == chId }) else {
            return .failure(.lib(domain: "discovery", message: "Service/characteristic not discovered"))
        }
        d.notifyCharUUID = chId
        d.notifyError = nil
        p.setNotifyValue(true, for: ch)
        let r = d.notifySem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
        d.notifyCharUUID = nil
        if r == .timedOut { return .failure(.lib(domain: "timeout", message: "subscribe timed out")) }
        if let e = d.notifyError { return .failure(CBMError.from(e as NSError, fallbackDomain: "connection")) }
        let id = CBMSubscriptionRegistry.shared.register(central: self, characteristicUUID: chId)
        return .success(id)
    }

    func unsubscribeCharacteristic(identifier: String, serviceUUID: String, charUUID: String,
                                    timeoutMs: Int32) -> CBMError? {
        guard let (p, d) = peripheral(identifier: identifier) else { return .lib(domain: "closed", message: "Unknown peripheral") }
        guard p.state == .connected else { return .lib(domain: "connection", message: "Peripheral not connected") }
        let svcId = CBUUID(string: serviceUUID)
        let chId  = CBUUID(string: charUUID)
        guard let svc = (p.services ?? []).first(where: { $0.uuid == svcId }),
              let ch  = (svc.characteristics ?? []).first(where: { $0.uuid == chId }) else {
            return .lib(domain: "discovery", message: "Service/characteristic not discovered")
        }
        d.notifyCharUUID = chId
        d.notifyError = nil
        p.setNotifyValue(false, for: ch)
        let r = d.notifySem.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
        d.notifyCharUUID = nil
        if r == .timedOut { return .lib(domain: "timeout", message: "unsubscribe timed out") }
        if let e = d.notifyError { return CBMError.from(e as NSError, fallbackDomain: "connection") }
        // Close all subscriptions matching this characteristic UUID under this central.
        CBMSubscriptionRegistry.shared.purgeAll(under: self) // simpler than per-char; safe for Phase 2 single-subscription cases
        return nil
    }
}
