import Foundation

@c
public func cbm_hello() -> UnsafeMutablePointer<CChar>? {
    return strdup("hello from CoreBluetoothMac")
}
