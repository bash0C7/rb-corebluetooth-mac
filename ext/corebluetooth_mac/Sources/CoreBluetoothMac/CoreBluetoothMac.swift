import Foundation

@c
public func cbm_hello() -> UnsafeMutablePointer<CChar>? {
    return strdup("hello from CoreBluetoothMac")
}

@c
public func cbm_central_free(_ ptr: UnsafeMutableRawPointer) {
    // Task 11 will provide the real impl
}
