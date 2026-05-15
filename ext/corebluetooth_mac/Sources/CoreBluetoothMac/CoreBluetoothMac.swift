import Foundation
import CoreBluetooth

@c
public func cbm_hello() -> UnsafeMutablePointer<CChar>? {
    return strdup("hello from CoreBluetoothMac")
}

@c
public func cbm_central_new(
    _ stateTimeoutMs: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutableRawPointer? {
    error_tag_out.pointee = 0
    error_out.pointee = nil

    let c = CBMCentral()
    if let err = c.awaitPoweredOn(timeoutMs: stateTimeoutMs) {
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return nil
    }
    return Unmanaged.passRetained(c).toOpaque()
}

@c
public func cbm_central_free(_ ptr: UnsafeMutableRawPointer) {
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeRetainedValue()
    CBMSubscriptionRegistry.shared.purgeAll(under: c)
    // Optionally cancel all active connections; CBCentralManager deinit handles it.
}

@c
public func cbm_central_id(_ ptr: UnsafeMutableRawPointer) -> Int64 {
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    return c.centralId
}

@c
public func cbm_central_scan(
    _ ptr: UnsafeMutableRawPointer,
    _ name_filter: UnsafePointer<CChar>?,
    _ service_uuids_json: UnsafePointer<CChar>?,
    _ timeout_ms: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutablePointer<CChar>? {
    error_tag_out.pointee = 0
    error_out.pointee = nil

    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    let nameStr: String? = name_filter.map { String(cString: $0) }
    var services: [CBUUID]? = nil
    if let json = service_uuids_json {
        let s = String(cString: json)
        if let data = s.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            services = arr.map { CBUUID(string: $0) }
        }
    }
    let results = c.scan(name: nameStr, services: services, timeoutMs: timeout_ms)
    return strdup(c.scanResultsAsJSON(results))
}

@c
public func cbm_central_connect(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ timeout_ms: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    let id = String(cString: identifier)
    if let err = c.connect(identifier: id, timeoutMs: timeout_ms) {
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return 0
    }
    return 1
}

@c
public func cbm_central_disconnect(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    let id = String(cString: identifier)
    if let err = c.disconnect(identifier: id) {
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return 0
    }
    return 1
}

@c
public func cbm_peripheral_state(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    return strdup(c.peripheralState(identifier: String(cString: identifier)))
}

@c
public func cbm_peripheral_discover_services(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ timeout_ms: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutablePointer<CChar>? {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    switch c.discoverServices(identifier: String(cString: identifier), timeoutMs: timeout_ms) {
    case .success(let uuids):
        let data = try! JSONSerialization.data(withJSONObject: uuids)
        return strdup(String(data: data, encoding: .utf8) ?? "[]")
    case .failure(let err):
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return nil
    }
}

@c
public func cbm_characteristic_read(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ service_uuid: UnsafePointer<CChar>,
    _ char_uuid: UnsafePointer<CChar>,
    _ timeout_ms: Int32,
    _ len_out: UnsafeMutablePointer<Int32>,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutablePointer<UInt8>? {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    len_out.pointee = 0
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    switch c.readCharacteristic(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: service_uuid),
        charUUID: String(cString: char_uuid),
        timeoutMs: timeout_ms
    ) {
    case .success(let data):
        let n = data.count
        len_out.pointee = Int32(n)
        if n == 0 {
            let buf = malloc(1)?.assumingMemoryBound(to: UInt8.self)
            return buf
        }
        let buf = malloc(n)!.assumingMemoryBound(to: UInt8.self)
        data.copyBytes(to: buf, count: n)
        return buf
    case .failure(let err):
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return nil
    }
}

@c
public func cbm_characteristic_write(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ service_uuid: UnsafePointer<CChar>,
    _ char_uuid: UnsafePointer<CChar>,
    _ data: UnsafePointer<UInt8>,
    _ data_len: Int32,
    _ with_response: Int32,
    _ timeout_ms: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    let bytes = UnsafeBufferPointer(start: data, count: Int(data_len))
    let payload = Data(buffer: bytes)
    if let err = c.writeCharacteristic(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: service_uuid),
        charUUID: String(cString: char_uuid),
        data: payload,
        withResponse: with_response != 0,
        timeoutMs: timeout_ms
    ) {
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return 0
    }
    return 1
}

@c
public func cbm_service_discover_characteristics(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ service_uuid: UnsafePointer<CChar>,
    _ timeout_ms: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutablePointer<CChar>? {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    switch c.discoverCharacteristics(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: service_uuid),
        timeoutMs: timeout_ms
    ) {
    case .success(let arr):
        let data = try! JSONSerialization.data(withJSONObject: arr)
        return strdup(String(data: data, encoding: .utf8) ?? "[]")
    case .failure(let err):
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return nil
    }
}

@c
public func cbm_characteristic_subscribe(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ service_uuid: UnsafePointer<CChar>,
    _ char_uuid: UnsafePointer<CChar>,
    _ timeout_ms: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int64 {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    switch c.subscribeCharacteristic(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: service_uuid),
        charUUID: String(cString: char_uuid),
        timeoutMs: timeout_ms
    ) {
    case .success(let id): return id
    case .failure(let err):
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return 0
    }
}

@c
public func cbm_characteristic_unsubscribe(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ service_uuid: UnsafePointer<CChar>,
    _ char_uuid: UnsafePointer<CChar>,
    _ timeout_ms: Int32,
    _ error_tag_out: UnsafeMutablePointer<Int32>,
    _ error_out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    error_tag_out.pointee = 0
    error_out.pointee = nil
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    if let err = c.unsubscribeCharacteristic(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: service_uuid),
        charUUID: String(cString: char_uuid),
        timeoutMs: timeout_ms
    ) {
        error_tag_out.pointee = cbmErrorTag(err)
        error_out.pointee = strdup(cbmErrorMessage(err))
        return 0
    }
    return 1
}

@c
public func cbm_subscription_next_value(
    _ subscription_id: Int64,
    _ timeout_ms: Int32,
    _ closed_out: UnsafeMutablePointer<Int32>,
    _ len_out: UnsafeMutablePointer<Int32>
) -> UnsafeMutablePointer<UInt8>? {
    closed_out.pointee = 0
    len_out.pointee = 0
    let (data, closed) = CBMSubscriptionRegistry.shared.dequeue(
        subscriptionId: subscription_id, timeoutMs: timeout_ms
    )
    if closed { closed_out.pointee = 1 }
    guard let d = data else { return nil }
    let n = d.count
    len_out.pointee = Int32(n)
    if n == 0 {
        return malloc(1)?.assumingMemoryBound(to: UInt8.self)
    }
    let buf = malloc(n)!.assumingMemoryBound(to: UInt8.self)
    d.copyBytes(to: buf, count: n)
    return buf
}

@c
public func cbm_subscription_close(_ subscription_id: Int64) {
    CBMSubscriptionRegistry.shared.close(subscriptionId: subscription_id)
}
