@preconcurrency import CoreBluetooth
import Foundation
import os

/// A `CBCentralManager` with blocking operations for the C bridge.
///
/// Delegate callbacks run on ``queue``. Every operation returns a `closed` error after ``close()``.
final class CBMCentral: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    static let idCounter = OSAllocatedUnfairLock<Int64>(initialState: 0)

    let centralId: Int64
    let manager: CBCentralManager
    let queue: DispatchQueue

    private let stateLock = OSAllocatedUnfairLock<CBManagerState>(initialState: .unknown)
    private let stateSem = DispatchSemaphore(value: 0)
    private let closedFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    var isClosed: Bool { closedFlag.withLock { $0 } }

    /// Stops all subscriptions under this central and detaches every delegate. Later calls do nothing.
    func close() {
        let already = closedFlag.withLock { state in
            defer { state = true }
            return state
        }
        if already { return }
        CBMSubscriptionRegistry.shared.purgeAll(centralId: centralId)
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
        let assigned = Self.idCounter.withLock { state in
            state += 1
            return state
        }
        self.centralId = assigned
        self.queue = DispatchQueue(label: "corebluetoothmac.central.\(assigned)")
        self.manager = CBCentralManager(delegate: nil, queue: self.queue)
        super.init()
        self.manager.delegate = self
    }

    /// Waits until the manager reaches `poweredOn`.
    ///
    /// - Returns: `nil` once powered on, a `closed` error for an unusable adapter, or a `timeout` error.
    func awaitPoweredOn(timeoutMs: Int32, cancel: CBMCancel) -> CBMError? {
        if isClosed { return .closed }
        stateSem.drain()
        let until = deadline(timeoutMs)
        while true {
            switch stateLock.withLock({ $0 }) {
            case .poweredOn:    return nil
            case .unauthorized: return .lib(domain: "closed", message: "Bluetooth permission denied. Open System Settings → Privacy & Security → Bluetooth and enable your terminal application.")
            case .unsupported:  return .lib(domain: "closed", message: "Bluetooth is not supported on this machine.")
            case .poweredOff:   return .lib(domain: "closed", message: "Bluetooth is off. Turn it on in Control Center / System Settings.")
            case .resetting:    return .lib(domain: "closed", message: "Bluetooth is resetting; try again.")
            case .unknown:      break
            @unknown default:   break
            }
            if cancel.wait(stateSem, until: until) == .timedOut {
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
        let serviceData: [String: String]
        let manufacturerData: String?
        let solicitedServiceUUIDs: [String]
        let overflowServiceUUIDs: [String]
    }

    private let scanLock = OSAllocatedUnfairLock<[String: ScanResult]>(initialState: [:])
    private let nameFilter = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let knownPeripherals = OSAllocatedUnfairLock<[UUID: CBPeripheral]>(initialState: [:])

    /// Scans for `timeoutMs` milliseconds and returns one result per advertiser.
    ///
    /// - Parameters:
    ///   - name: The advertised name to match, or `nil` for every advertiser.
    ///   - services: The service UUIDs to filter on, or `nil` for no filter.
    func scan(name: String?, services: [CBUUID]?, timeoutMs: Int32, cancel: CBMCancel) -> Result<[[String: Any]], CBMError> {
        if isClosed { return .failure(.closed) }
        scanLock.withLock { $0.removeAll() }
        nameFilter.withLock { $0 = name }
        manager.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        cancel.sleep(until: deadline(timeoutMs))
        manager.stopScan()
        return .success(scanLock.withLock { Array($0.values) }.map { r in
            [
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
            ] as [String: Any]
        })
    }

    private static func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        stateLock.withLock { $0 = central.state }
        stateSem.signal()
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        if let filter = nameFilter.withLock({ $0 }), name != filter { return }

        knownPeripherals.withLock { state in
            if state[peripheral.identifier] == nil {
                state[peripheral.identifier] = peripheral
            }
        }

        let uuids = { (key: String) -> [String] in
            ((advertisementData[key] as? [CBUUID]) ?? []).map { $0.uuidString.lowercased() }
        }
        var serviceData: [String: String] = [:]
        if let raw = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (uuid, data) in raw {
                serviceData[uuid.uuidString.lowercased()] = Self.hexEncode(data)
            }
        }

        let r = ScanResult(
            identifier: peripheral.identifier.uuidString,
            name: name,
            rssi: RSSI.intValue,
            txPowerLevel: (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue,
            isConnectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue,
            serviceUUIDs: uuids(CBAdvertisementDataServiceUUIDsKey),
            serviceData: serviceData,
            manufacturerData: (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map(Self.hexEncode),
            solicitedServiceUUIDs: uuids(CBAdvertisementDataSolicitedServiceUUIDsKey),
            overflowServiceUUIDs: uuids(CBAdvertisementDataOverflowServiceUUIDsKey),
        )
        scanLock.withLock { $0[peripheral.identifier.uuidString] = r }
    }

    private let delegatesLock = OSAllocatedUnfairLock<[UUID: CBMPeripheralDelegate]>(initialState: [:])

    func delegate(for identifier: UUID) -> CBMPeripheralDelegate? {
        delegatesLock.withLock { $0[identifier] }
    }

    func peripheral(identifier: String) -> (CBPeripheral, CBMPeripheralDelegate)? {
        guard let uuid = UUID(uuidString: identifier),
              let peripheral = knownPeripherals.withLock({ $0[uuid] }) else { return nil }
        let d = delegatesLock.withLock { dict in
            if let existing = dict[uuid] { return existing }
            let nd = CBMPeripheralDelegate(peripheral: peripheral, centralId: centralId)
            dict[uuid] = nd
            return nd
        }
        return (peripheral, d)
    }

    func connect(identifier: String, timeoutMs: Int32, cancel: CBMCancel) -> CBMError? {
        if isClosed { return .closed }
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .lib(domain: "connection", message: "Unknown peripheral identifier \(identifier); scan first.")
        }
        d.connectError = nil
        d.connected = false
        d.connectSem.drain()
        manager.connect(p, options: nil)
        if cancel.wait(d.connectSem, until: deadline(timeoutMs)) == .timedOut {
            manager.cancelPeripheralConnection(p)
            return .lib(domain: "timeout", message: "connect timed out after \(timeoutMs)ms")
        }
        if let e = d.connectError { return CBMError.from(e as NSError, fallbackDomain: "connection") }
        if !d.connected { return .lib(domain: "connection", message: "connect signalled but state is not connected") }
        return nil
    }

    func disconnect(identifier: String) -> CBMError? {
        if isClosed { return .closed }
        guard let (p, _) = peripheral(identifier: identifier) else {
            return .lib(domain: "closed", message: "Unknown peripheral identifier \(identifier).")
        }
        manager.cancelPeripheralConnection(p)
        return nil
    }

    func peripheralState(identifier: String) -> String {
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

    func discoverServices(identifier: String, serviceUUIDs: [CBUUID]?, timeoutMs: Int32, cancel: CBMCancel)
        -> Result<[[String: Any]], CBMError>
    {
        if isClosed { return .failure(.closed) }
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .failure(.lib(domain: "closed", message: "Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        d.servicesError = nil
        d.servicesSem.drain()
        p.discoverServices(serviceUUIDs)
        if cancel.wait(d.servicesSem, until: deadline(timeoutMs)) == .timedOut {
            return .failure(.lib(domain: "timeout", message: "discoverServices timed out after \(timeoutMs)ms"))
        }
        if let e = d.servicesError { return .failure(CBMError.from(e as NSError, fallbackDomain: "discovery")) }
        let wanted = serviceUUIDs.map(Set.init)
        return .success((p.services ?? []).filter { wanted?.contains($0.uuid) ?? true }.map { svc in
            ["uuid": svc.uuid.uuidString.lowercased(), "is_primary": svc.isPrimary]
        })
    }

    func discoverCharacteristics(identifier: String, serviceUUID: String, timeoutMs: Int32, cancel: CBMCancel)
        -> Result<[[String: Any]], CBMError>
    {
        if isClosed { return .failure(.closed) }
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
        d.charsSem.drain()
        p.discoverCharacteristics(nil, for: service)
        let r = cancel.wait(d.charsSem, until: deadline(timeoutMs))
        d.charsServiceUUID = nil
        if r == .timedOut { return .failure(.lib(domain: "timeout", message: "discoverCharacteristics timed out after \(timeoutMs)ms")) }
        if let e = d.charsError { return .failure(CBMError.from(e as NSError, fallbackDomain: "discovery")) }
        let names: [(CBCharacteristicProperties, String)] = [
            (.broadcast, "broadcast"),
            (.read, "read"),
            (.writeWithoutResponse, "write_without_response"),
            (.write, "write"),
            (.notify, "notify"),
            (.indicate, "indicate"),
            (.authenticatedSignedWrites, "authenticated_signed_writes"),
            (.extendedProperties, "extended_properties"),
            (.notifyEncryptionRequired, "notify_encryption_required"),
            (.indicateEncryptionRequired, "indicate_encryption_required"),
        ]
        return .success((service.characteristics ?? []).map { ch in
            var d: [String: Any] = [
                "uuid": ch.uuid.uuidString.lowercased(),
                "properties": names.filter { ch.properties.contains($0.0) }.map(\.1),
            ]
            if let v = ch.value {
                d["initial_value"] = Self.hexEncode(v)
            }
            return d
        })
    }

    func discoverIncludedServices(identifier: String, serviceUUID: String, timeoutMs: Int32, cancel: CBMCancel)
        -> Result<[[String: Any]], CBMError>
    {
        if isClosed { return .failure(.closed) }
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
        d.includedSvcSem.drain()
        p.discoverIncludedServices(nil, for: service)
        let r = cancel.wait(d.includedSvcSem, until: deadline(timeoutMs))
        d.includedSvcUUID = nil
        if r == .timedOut { return .failure(.lib(domain: "timeout", message: "discoverIncludedServices timed out after \(timeoutMs)ms")) }
        if let e = d.includedSvcError { return .failure(CBMError.from(e as NSError, fallbackDomain: "discovery")) }
        return .success((service.includedServices ?? []).map { svc in
            ["uuid": svc.uuid.uuidString.lowercased(), "is_primary": svc.isPrimary]
        })
    }

    func readCharacteristic(identifier: String, serviceUUID: String, charUUID: String, timeoutMs: Int32, cancel: CBMCancel)
        -> Result<Data, CBMError>
    {
        if isClosed { return .failure(.closed) }
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .failure(.lib(domain: "closed", message: "Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        let svcId = CBUUID(string: serviceUUID)
        let chId  = CBUUID(string: charUUID)
        guard let svc = (p.services ?? []).first(where: { $0.uuid == svcId }) else {
            return .failure(.lib(domain: "discovery", message: "Service \(serviceUUID) not discovered"))
        }
        guard let ch = (svc.characteristics ?? []).first(where: { $0.uuid == chId }) else {
            return .failure(.lib(domain: "discovery", message: "Characteristic \(charUUID) not discovered"))
        }
        d.readCharUUID = chId
        d.readError = nil
        d.readValue = nil
        d.readSem.drain()
        p.readValue(for: ch)
        let r = cancel.wait(d.readSem, until: deadline(timeoutMs))
        d.readCharUUID = nil
        if r == .timedOut { return .failure(.lib(domain: "timeout", message: "read timed out after \(timeoutMs)ms")) }
        if let e = d.readError { return .failure(CBMError.from(e as NSError, fallbackDomain: "connection")) }
        return .success(d.readValue ?? Data())
    }

    /// Writes `data` to a characteristic.
    ///
    /// Without response and with a positive `timeoutMs`, waits until `canSendWriteWithoutResponse` is true before writing.
    func writeCharacteristic(identifier: String, serviceUUID: String, charUUID: String,
                             data: Data, withResponse: Bool, timeoutMs: Int32, cancel: CBMCancel) -> CBMError? {
        if isClosed { return .closed }
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
            d.writeSem.drain()
            p.writeValue(data, for: ch, type: .withResponse)
            let r = cancel.wait(d.writeSem, until: deadline(timeoutMs))
            d.writeCharUUID = nil
            if r == .timedOut { return .lib(domain: "timeout", message: "write timed out after \(timeoutMs)ms") }
            if let e = d.writeError { return CBMError.from(e as NSError, fallbackDomain: "connection") }
            return nil
        }
        if timeoutMs > 0 {
            d.wwrReadySem.drain()
            let until = deadline(timeoutMs)
            while !p.canSendWriteWithoutResponse {
                if cancel.wait(d.wwrReadySem, until: until) == .timedOut && !p.canSendWriteWithoutResponse {
                    return .lib(domain: "timeout", message: "writeWithoutResponse not ready after \(timeoutMs)ms")
                }
            }
        }
        p.writeValue(data, for: ch, type: .withoutResponse)
        return nil
    }

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
        guard let d = delegate(for: p.identifier) else { return }
        d.connected = false
        d.lastDisconnectInfo.withLock { $0 = error.map { $0 as NSError } }
        if d.connectError == nil && error != nil {
            d.connectError = error
            d.connectSem.signal()
        }
        d.rssiLock.withLock {
            if $0 == nil {
                $0 = .failure(.lib(domain: "connection", message: "Peripheral disconnected during readRSSI"))
            }
        }
        d.rssiSem.signal()
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

        let errorPayload: Any = error.map { CBMError.from($0 as NSError, fallbackDomain: "connection").json } ?? NSNull()
        d.pushEvent(tag: .disconnected, payload: ["error": errorPayload])
        CBMSubscriptionRegistry.shared.disconnected(centralId: centralId, peripheral: p.identifier)
    }

    func readRSSI(identifier: String, timeoutMs: Int32, cancel: CBMCancel) -> Result<Int, CBMError> {
        if isClosed { return .failure(.closed) }
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .failure(.lib(domain: "closed", message: "Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        d.rssiSem.drain()
        d.rssiLock.withLock { $0 = nil }
        p.readRSSI()
        if cancel.wait(d.rssiSem, until: deadline(timeoutMs)) == .timedOut {
            return .failure(.lib(domain: "timeout", message: "readRSSI timed out after \(timeoutMs)ms"))
        }
        return d.rssiLock.withLock { $0 } ?? .failure(.lib(domain: "discovery", message: "RSSI result missing"))
    }

    func maxWriteLength(identifier: String, withResponse: Bool) -> Result<Int, CBMError> {
        if isClosed { return .failure(.closed) }
        guard let (p, _) = peripheral(identifier: identifier) else {
            return .failure(.lib(domain: "closed", message: "Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        return .success(p.maximumWriteValueLength(for: withResponse ? .withResponse : .withoutResponse))
    }

    func lastDisconnectError(identifier: String) -> NSError? {
        if isClosed { return nil }
        guard let uuid = UUID(uuidString: identifier),
              let d = delegate(for: uuid) else { return nil }
        return d.lastDisconnectInfo.withLock { $0 }
    }

    /// Takes one event from the peripheral's event queue.
    ///
    /// - Returns: A `tag` / `payload` hash, `NSNull` when no event arrives within `timeoutMs`,
    ///   a `closed` error after ``close()``, or a `validation` error for an identifier that is not tracked.
    func pollPeripheralEvents(identifier: String, timeoutMs: Int32, cancel: CBMCancel)
        -> Result<Any, CBMError>
    {
        if isClosed { return .failure(.closed) }
        guard let uuid = UUID(uuidString: identifier) else {
            return .failure(.lib(domain: "validation", message: "invalid peripheral identifier"))
        }
        guard let d = delegate(for: uuid) else {
            return .failure(.lib(domain: "validation", message: "peripheral not tracked"))
        }
        guard let event = d.pollEvent(timeoutMs: timeoutMs, cancel: cancel) else { return .success(NSNull()) }
        return .success(["tag": event.tag, "payload": event.payload])
    }

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

    func discoverDescriptors(identifier: String, serviceUUID: String, charUUID: String,
                             timeoutMs: Int32, cancel: CBMCancel) -> Result<[[String: Any]], CBMError> {
        if isClosed { return .failure(.closed) }
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .failure(.lib(domain: "closed", message: "Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        guard let ch = findCharacteristic(p, serviceUUID: serviceUUID, charUUID: charUUID) else {
            return .failure(.lib(domain: "discovery", message: "Characteristic \(charUUID) not found"))
        }
        d.descriptorsSem.drain()
        d.descriptorsLock.withLock { $0 = nil }
        d.descriptorsCharUUID = ch.uuid.uuidString
        p.discoverDescriptors(for: ch)
        if cancel.wait(d.descriptorsSem, until: deadline(timeoutMs)) == .timedOut {
            return .failure(.lib(domain: "timeout", message: "discoverDescriptors timed out after \(timeoutMs)ms"))
        }
        guard let r = d.descriptorsLock.withLock({ $0 }) else {
            return .failure(.lib(domain: "discovery", message: "discoverDescriptors result missing"))
        }
        return r.map { uuids in uuids.map { ["uuid": $0] } }
    }

    func readDescriptor(identifier: String, serviceUUID: String, charUUID: String,
                        descUUID: String, timeoutMs: Int32, cancel: CBMCancel) -> Result<Data, CBMError> {
        if isClosed { return .failure(.closed) }
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .failure(.lib(domain: "closed", message: "Unknown peripheral \(identifier)"))
        }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        guard let desc = findDescriptor(p, serviceUUID: serviceUUID, charUUID: charUUID, descUUID: descUUID) else {
            return .failure(.lib(domain: "discovery", message: "Descriptor \(descUUID) not found"))
        }
        d.descriptorReadSem.drain()
        d.descriptorReadLock.withLock { $0 = nil }
        d.descriptorReadUUID = desc.uuid.uuidString.lowercased()
        p.readValue(for: desc)
        if cancel.wait(d.descriptorReadSem, until: deadline(timeoutMs)) == .timedOut {
            return .failure(.lib(domain: "timeout", message: "readDescriptor timed out after \(timeoutMs)ms"))
        }
        return d.descriptorReadLock.withLock { $0 } ?? .failure(.lib(domain: "discovery", message: "readDescriptor result missing"))
    }

    func writeDescriptor(identifier: String, serviceUUID: String, charUUID: String,
                         descUUID: String, data: Data, timeoutMs: Int32, cancel: CBMCancel) -> CBMError? {
        if isClosed { return .closed }
        guard let (p, d) = peripheral(identifier: identifier) else {
            return .lib(domain: "closed", message: "Unknown peripheral \(identifier)")
        }
        guard p.state == .connected else { return .lib(domain: "connection", message: "Peripheral not connected") }
        guard let desc = findDescriptor(p, serviceUUID: serviceUUID, charUUID: charUUID, descUUID: descUUID) else {
            return .lib(domain: "discovery", message: "Descriptor \(descUUID) not found")
        }
        d.descriptorWriteSem.drain()
        d.descriptorWriteLock.withLock { $0 = nil }
        d.descriptorWriteUUID = desc.uuid.uuidString.lowercased()
        p.writeValue(data, for: desc)
        if cancel.wait(d.descriptorWriteSem, until: deadline(timeoutMs)) == .timedOut {
            return .lib(domain: "timeout", message: "writeDescriptor timed out after \(timeoutMs)ms")
        }
        switch d.descriptorWriteLock.withLock({ $0 }) {
        case .success: return nil
        case .failure(let err): return err
        case nil: return .lib(domain: "discovery", message: "writeDescriptor result missing")
        }
    }

    func subscribeCharacteristic(identifier: String, serviceUUID: String, charUUID: String,
                                 timeoutMs: Int32, cancel: CBMCancel) -> Result<Int64, CBMError> {
        if isClosed { return .failure(.closed) }
        guard let (p, d) = peripheral(identifier: identifier) else { return .failure(.lib(domain: "closed", message: "Unknown peripheral")) }
        guard p.state == .connected else { return .failure(.lib(domain: "connection", message: "Peripheral not connected")) }
        guard let ch = findCharacteristic(p, serviceUUID: serviceUUID, charUUID: charUUID) else {
            return .failure(.lib(domain: "discovery", message: "Service/characteristic not discovered"))
        }
        let id = CBMSubscriptionRegistry.shared.register(centralId: centralId, peripheral: p.identifier, characteristicUUID: ch.uuid)
        d.notifyCharUUID = ch.uuid
        d.notifyError = nil
        d.notifySem.drain()
        p.setNotifyValue(true, for: ch)
        let r = cancel.wait(d.notifySem, until: deadline(timeoutMs))
        d.notifyCharUUID = nil
        if r == .timedOut {
            CBMSubscriptionRegistry.shared.remove(subscriptionId: id)
            return .failure(.lib(domain: "timeout", message: "subscribe timed out"))
        }
        if let e = d.notifyError {
            CBMSubscriptionRegistry.shared.remove(subscriptionId: id)
            return .failure(CBMError.from(e as NSError, fallbackDomain: "connection"))
        }
        return .success(id)
    }

    /// Turns notifications off and closes only the subscriptions on this central for the peripheral's `charUUID`.
    func unsubscribeCharacteristic(identifier: String, serviceUUID: String, charUUID: String,
                                   timeoutMs: Int32, cancel: CBMCancel) -> CBMError? {
        if isClosed { return .closed }
        guard let (p, d) = peripheral(identifier: identifier) else { return .lib(domain: "closed", message: "Unknown peripheral") }
        guard p.state == .connected else { return .lib(domain: "connection", message: "Peripheral not connected") }
        guard let ch = findCharacteristic(p, serviceUUID: serviceUUID, charUUID: charUUID) else {
            return .lib(domain: "discovery", message: "Service/characteristic not discovered")
        }
        d.notifyCharUUID = ch.uuid
        d.notifyError = nil
        d.notifySem.drain()
        p.setNotifyValue(false, for: ch)
        let r = cancel.wait(d.notifySem, until: deadline(timeoutMs))
        d.notifyCharUUID = nil
        if r == .timedOut { return .lib(domain: "timeout", message: "unsubscribe timed out") }
        if let e = d.notifyError { return CBMError.from(e as NSError, fallbackDomain: "connection") }
        CBMSubscriptionRegistry.shared.purgeMatching(centralId: centralId, peripheral: p.identifier, characteristicUUID: ch.uuid)
        return nil
    }
}
