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
    // CBCentralManager holds its delegate weakly (CBCentralManager.h:88).
    // The opaque pointer was the only strong retain on `c`; once this scope
    // ends, ARC deallocates. Serialize on the manager's own queue so any
    // in-flight delegate callback completes before we let `c` go.
    c.queue.sync {
        c.manager.delegate = nil
    }
    // Future: cancel pending operations / close subscriptions
    _ = c
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
