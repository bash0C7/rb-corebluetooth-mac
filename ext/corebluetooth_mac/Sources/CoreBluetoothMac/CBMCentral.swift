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

    // Task 15: closed-state gate. Set once via `close()` (idempotent); every
    // public op short-circuits with a `:closed` domain error so callers stop
    // relying on GC for teardown.
    private let closedFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    var isClosed: Bool { closedFlag.withLock { $0 } }

    func close() {
        let already = closedFlag.withLock { state -> Bool in
            defer { state = true }
            return state
        }
        if already { return }
        CBMSubscriptionRegistry.shared.purgeAll(under: self)
        // `queue.sync` serializes teardown against any in-flight delegate
        // callbacks (which run on the central's queue). Snapshot delegates
        // before clearing so we can null out their peripheral.delegate first.
        queue.sync {
            let snapshot = delegatesLock.withLock { Array($0.values) }
            for d in snapshot {
                d.peripheral.delegate = nil
            }
            delegatesLock.withLock { $0.removeAll() }
            knownPeripherals.withLock { $0.removeAll() }
            manager.delegate = nil
        }
    }

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
        if isClosed { return .lib(domain: "closed", message: "Central closed") }
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
        // Closed-gate enforcement lives in the @c shim (`cbm_central_scan`),
        // which has the error envelope to surface the failure. Defensive early
        // return here just avoids touching `manager` after teardown.
        if isClosed { return [] }
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
        if isClosed { return .lib(domain: "closed", message: "Central closed") }
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
        if isClosed { return .lib(domain: "closed", message: "Central closed") }
        guard let (p, _) = peripheral(identifier: identifier) else {
            return .lib(domain: "closed", message: "Unknown peripheral identifier \(identifier).")
        }
        manager.cancelPeripheralConnection(p)
        return nil
    }

    func peripheralState(identifier: String) -> String {
        // No error channel here — surface a distinct sentinel so the Ruby
        // wrapper can interpret it (current callers only consume the symbol).
        if isClosed { return "closed" }
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
        if isClosed { return .failure(.lib(domain: "closed", message: "Central closed")) }
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
        if isClosed { return .failure(.lib(domain: "closed", message: "Central closed")) }
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
        if isClosed { return .failure(.lib(domain: "closed", message: "Central closed")) }
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
        if isClosed { return .failure(.lib(domain: "closed", message: "Central closed")) }
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
        if isClosed { return .lib(domain: "closed", message: "Central closed") }
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
            // Fail-fast any in-progress descriptor operations.
            d.descriptorsLock.withLock {
                if $0 == nil { $0 = .failure(.lib(domain: "connection", message: "Peripheral disconnected")) }
            }
            d.descriptorsSem.signal()
            d.descriptorReadLock.withLock {
                if $0 == nil { $0 = .failure(.lib(domain: "connection", message: "Peripheral disconnected")) }
            }
            d.descriptorReadSem.signal()
            d.descriptorWriteLock.withLock {
                if $0 == nil { $0 = .failure(.lib(domain: "connection", message: "Peripheral disconnected")) }
            }
            d.descriptorWriteSem.signal()

            // Task 13: push a `disconnected` event onto the per-peripheral event queue.
            // This runs AFTER lastDisconnectInfo (Task 9) and in-flight op fail-fast
            // (Task 10/12) so existing paths continue to win the race and don't see a
            // stale event queue. Payload mirrors the `last_disconnect_error` envelope:
            // null for clean disconnect, or a CBMError-shaped error hash.
            let errorPayload: Any
            if let e = error {
                errorPayload = CBMError.from(e as NSError, fallbackDomain: "connection").json
            } else {
                errorPayload = NSNull()
            }
            d.pushEvent(tag: .disconnected, payload: ["error": errorPayload])
        }
    }

    func readRSSI(identifier: String, timeoutMs: Int32) -> Result<Int, CBMError> {
        if isClosed { return .failure(.lib(domain: "closed", message: "Central closed")) }
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
        if isClosed { return .failure(.lib(domain: "closed", message: "Central closed")) }
        guard let (p, _) = peripheral(identifier: identifier) else {
            return .failure(.lib(domain: "closed", message: "Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
        return .success(p.maximumWriteValueLength(for: type))
    }

    func lastDisconnectError(identifier: String) -> NSError? {
        // After close the delegate table is empty, so `delegate(for:)` already
        // returns nil — the explicit gate keeps intent obvious.
        if isClosed { return nil }
        guard let uuid = UUID(uuidString: identifier),
              let d = delegate(for: uuid) else { return nil }
        return d.lastDisconnectInfo.withLock { $0 }
    }

    // Task 13/15: drain one event from the per-peripheral queue.
    // Result shape distinguishes three cases the caller must surface differently:
    //   .failure(.lib(domain: "closed", ...))     — central closed
    //   .failure(.lib(domain: "validation", ...)) — bad UUID or unknown peripheral
    //   .success(nil)                              — timeout (no event yet)
    //   .success(.some((tag, payload)))            — event drained
    func pollPeripheralEvents(identifier: String, timeoutMs: Int32)
        -> Result<(tag: String, payload: [String: Any])?, CBMError>
    {
        if isClosed { return .failure(.lib(domain: "closed", message: "Central closed")) }
        guard let uuid = UUID(uuidString: identifier) else {
            return .failure(.lib(domain: "validation", message: "invalid peripheral identifier"))
        }
        guard let d = delegate(for: uuid) else {
            return .failure(.lib(domain: "validation", message: "peripheral not tracked"))
        }
        return .success(d.pollEvent(timeoutMs: timeoutMs))
    }

    // MARK: - Private helpers

    private func findCharacteristic(_ p: CBPeripheral, serviceUUID: String, charUUID: String) -> CBCharacteristic? {
        let svcId = CBUUID(string: serviceUUID)
        let chId  = CBUUID(string: charUUID)
        guard let svc = (p.services ?? []).first(where: { $0.uuid == svcId }) else { return nil }
        return (svc.characteristics ?? []).first(where: { $0.uuid == chId })
    }

    private func findDescriptor(_ p: CBPeripheral, serviceUUID: String, charUUID: String,
                                descUUID: String) -> CBDescriptor? {
        guard let ch = findCharacteristic(p, serviceUUID: serviceUUID, charUUID: charUUID) else { return nil }
        let dId = CBUUID(string: descUUID)
        return (ch.descriptors ?? []).first(where: { $0.uuid == dId })
    }

    // MARK: - Descriptor operations

    func discoverDescriptors(identifier: String, serviceUUID: String, charUUID: String,
                              timeoutMs: Int32) -> Result<[[String: Any]], CBMError> {
        if isClosed { return .failure(.lib(domain: "closed", message: "Central closed")) }
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .failure(.lib(domain: "closed", message: "Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        guard let ch = findCharacteristic(p, serviceUUID: serviceUUID, charUUID: charUUID) else {
            return .failure(.lib(domain: "discovery", message: "Characteristic \(charUUID) not found"))
        }
        // Drain stale signals.
        while d.descriptorsSem.wait(timeout: .now()) == .success {}
        d.descriptorsLock.withLock { $0 = nil }
        d.descriptorsCharUUID = ch.uuid.uuidString
        p.discoverDescriptors(for: ch)
        if d.descriptorsSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs))) == .timedOut {
            return .failure(.lib(domain: "timeout", message: "discoverDescriptors timed out after \(timeoutMs)ms"))
        }
        guard let r = d.descriptorsLock.withLock({ $0 }) else {
            return .failure(.lib(domain: "discovery", message: "discoverDescriptors result missing"))
        }
        return r.map { uuids in uuids.map { ["uuid": $0] } }
    }

    func readDescriptor(identifier: String, serviceUUID: String, charUUID: String,
                         descUUID: String, timeoutMs: Int32) -> Result<Data, CBMError> {
        if isClosed { return .failure(.lib(domain: "closed", message: "Central closed")) }
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .failure(.lib(domain: "closed", message: "Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        guard let desc = findDescriptor(p, serviceUUID: serviceUUID, charUUID: charUUID, descUUID: descUUID) else {
            return .failure(.lib(domain: "discovery", message: "Descriptor \(descUUID) not found"))
        }
        // Drain stale signals.
        while d.descriptorReadSem.wait(timeout: .now()) == .success {}
        d.descriptorReadLock.withLock { $0 = nil }
        d.descriptorReadUUID = desc.uuid.uuidString.lowercased()
        p.readValue(for: desc)
        if d.descriptorReadSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs))) == .timedOut {
            return .failure(.lib(domain: "timeout", message: "readDescriptor timed out after \(timeoutMs)ms"))
        }
        guard let r = d.descriptorReadLock.withLock({ $0 }) else {
            return .failure(.lib(domain: "discovery", message: "readDescriptor result missing"))
        }
        return r
    }

    func writeDescriptor(identifier: String, serviceUUID: String, charUUID: String,
                          descUUID: String, data: Data, timeoutMs: Int32) -> CBMError? {
        if isClosed { return .lib(domain: "closed", message: "Central closed") }
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .lib(domain: "closed", message: "Unknown peripheral \(identifier)")
        }
        guard p.state == .connected else { return .lib(domain: "connection", message: "Peripheral not connected") }
        guard let desc = findDescriptor(p, serviceUUID: serviceUUID, charUUID: charUUID, descUUID: descUUID) else {
            return .lib(domain: "discovery", message: "Descriptor \(descUUID) not found")
        }
        // Drain stale signals.
        while d.descriptorWriteSem.wait(timeout: .now()) == .success {}
        d.descriptorWriteLock.withLock { $0 = nil }
        d.descriptorWriteUUID = desc.uuid.uuidString.lowercased()
        p.writeValue(data, for: desc)
        if d.descriptorWriteSem.wait(timeout: .now() + .milliseconds(Int(timeoutMs))) == .timedOut {
            return .lib(domain: "timeout", message: "writeDescriptor timed out after \(timeoutMs)ms")
        }
        guard let r = d.descriptorWriteLock.withLock({ $0 }) else {
            return .lib(domain: "discovery", message: "writeDescriptor result missing")
        }
        switch r {
        case .success: return nil
        case .failure(let err): return err
        }
    }

    func subscribeCharacteristic(identifier: String, serviceUUID: String, charUUID: String,
                                  timeoutMs: Int32) -> Result<Int64, CBMError> {
        if isClosed { return .failure(.lib(domain: "closed", message: "Central closed")) }
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
        if isClosed { return .lib(domain: "closed", message: "Central closed") }
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
        // Close + drop only the subscriptions matching this characteristic
        // UUID under this central. Other concurrent subscriptions (e.g. a
        // second char that this Ruby caller is still pumping in a Ractor)
        // must stay alive — using `purgeAll(under:)` here would terminate
        // them too and surface as a spurious `false` on `next_value`.
        CBMSubscriptionRegistry.shared.purgeMatching(under: self, characteristicUUID: chId)
        return nil
    }
}
