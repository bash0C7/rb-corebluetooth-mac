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
    // Future: cancel pending operations / close subscriptions
    _ = c
}

@c
public func cbm_central_id(_ ptr: UnsafeMutableRawPointer) -> Int64 {
    let c = Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
    return c.centralId
}
