import CoreBluetooth
import Foundation

private func central(_ ptr: UnsafeMutableRawPointer) -> CBMCentral {
    Unmanaged<CBMCentral>.fromOpaque(ptr).takeUnretainedValue()
}

private func token(_ ptr: UnsafeMutableRawPointer) -> CBMCancel {
    Unmanaged<CBMCancel>.fromOpaque(ptr).takeUnretainedValue()
}

private func envelope(_ json: String) -> UnsafeMutablePointer<CChar> {
    strdup(json)!
}

private func uuids(_ json: UnsafePointer<CChar>?) -> [CBUUID]? {
    guard let json,
          let arr = try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8)) as? [String] else { return nil }
    return arr.map { CBUUID(string: $0) }
}

private func bytes(_ data: Data, _ lenOut: UnsafeMutablePointer<Int32>) -> UnsafeMutablePointer<UInt8> {
    lenOut.pointee = Int32(data.count)
    let buf = malloc(max(data.count, 1))!.assumingMemoryBound(to: UInt8.self)
    data.copyBytes(to: buf, count: data.count)
    return buf
}

private func readResult(
    _ r: Result<Data, CBMError>,
    _ lenOut: UnsafeMutablePointer<Int32>,
    _ envelopeOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutablePointer<UInt8>? {
    lenOut.pointee = 0
    switch r {
    case .success(let data):
        envelopeOut.pointee = envelope(CBMEnvelope.ok(nil))
        return bytes(data, lenOut)
    case .failure(let err):
        envelopeOut.pointee = envelope(CBMEnvelope.err(err))
        return nil
    }
}

/// Returns a fixed greeting, exposed to C as `corebluetooth_mac_hello`.
///
/// - Returns: A string owned by the caller. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_hello)
public func cHello() -> UnsafeMutablePointer<CChar> {
    strdup("hello from CoreBluetoothMac")!
}

/// Releases a buffer returned by any bridge function, exposed to C as `corebluetooth_mac_free`.
///
/// - Parameter ptr: The buffer to release, or `nil`.
@c(corebluetooth_mac_free)
public func cFree(_ ptr: UnsafeMutableRawPointer?) {
    free(ptr)
}

/// Creates a cancellation token for one blocking call, exposed to C as `corebluetooth_mac_cancel_new`.
///
/// - Returns: A token to pass to a blocking bridge function. Release it with ``cCancelFree(_:)``.
@c(corebluetooth_mac_cancel_new)
public func cCancelNew() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(CBMCancel()).toOpaque()
}

/// Makes the blocking call that holds `cancel` time out now, exposed to C as `corebluetooth_mac_cancel`.
///
/// Safe to call from any thread, any number of times.
///
/// - Parameter cancel: A token from ``cCancelNew()``.
@c(corebluetooth_mac_cancel)
public func cCancel(_ cancel: UnsafeMutableRawPointer) {
    token(cancel).cancel()
}

/// Releases a token from ``cCancelNew()``, exposed to C as `corebluetooth_mac_cancel_free`.
///
/// - Parameter cancel: A token no call uses any more.
@c(corebluetooth_mac_cancel_free)
public func cCancelFree(_ cancel: UnsafeMutableRawPointer) {
    Unmanaged<CBMCancel>.fromOpaque(cancel).release()
}

/// Creates a central manager, exposed to C as `corebluetooth_mac_central_new`.
///
/// - Returns: A central owned by the caller. Release it with ``cCentralFree(_:)``.
@c(corebluetooth_mac_central_new)
public func cCentralNew() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(CBMCentral()).toOpaque()
}

/// Closes and releases a central, exposed to C as `corebluetooth_mac_central_free`.
///
/// - Parameter ptr: A central from ``cCentralNew()``.
@c(corebluetooth_mac_central_free)
public func cCentralFree(_ ptr: UnsafeMutableRawPointer) {
    Unmanaged<CBMCentral>.fromOpaque(ptr).takeRetainedValue().close()
}

/// Closes a central, exposed to C as `corebluetooth_mac_central_close`. Later calls do nothing.
///
/// - Parameter ptr: A central from ``cCentralNew()``.
@c(corebluetooth_mac_central_close)
public func cCentralClose(_ ptr: UnsafeMutableRawPointer) {
    central(ptr).close()
}

/// Returns the central's process-unique id, exposed to C as `corebluetooth_mac_central_id`.
///
/// - Parameter ptr: A central from ``cCentralNew()``.
/// - Returns: A positive id.
@c(corebluetooth_mac_central_id)
public func cCentralId(_ ptr: UnsafeMutableRawPointer) -> Int64 {
    central(ptr).centralId
}

/// Waits until Bluetooth is powered on, exposed to C as `corebluetooth_mac_central_await_powered_on`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - timeoutMs: The longest wait in milliseconds.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: An envelope with `null` data. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_central_await_powered_on)
public func cCentralAwaitPoweredOn(
    _ ptr: UnsafeMutableRawPointer,
    _ timeoutMs: Int32,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<CChar> {
    envelope(CBMEnvelope.status(central(ptr).awaitPoweredOn(timeoutMs: timeoutMs, cancel: token(cancel))))
}

/// Scans for advertisers, exposed to C as `corebluetooth_mac_central_scan`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - nameFilter: The advertised name to match, or `NULL`.
///   - serviceUUIDsJSON: A JSON array of service UUID strings, or `NULL`.
///   - timeoutMs: The scan duration in milliseconds.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: An envelope with an array of advertisement hashes. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_central_scan)
public func cCentralScan(
    _ ptr: UnsafeMutableRawPointer,
    _ nameFilter: UnsafePointer<CChar>?,
    _ serviceUUIDsJSON: UnsafePointer<CChar>?,
    _ timeoutMs: Int32,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<CChar> {
    envelope(CBMEnvelope.result(central(ptr).scan(
        name: nameFilter.map { String(cString: $0) },
        services: uuids(serviceUUIDsJSON),
        timeoutMs: timeoutMs,
        cancel: token(cancel)
    )))
}

/// Connects to a scanned peripheral, exposed to C as `corebluetooth_mac_central_connect`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The peripheral's identifier from a scan.
///   - timeoutMs: The longest wait in milliseconds.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: An envelope with `null` data. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_central_connect)
public func cCentralConnect(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ timeoutMs: Int32,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<CChar> {
    envelope(CBMEnvelope.status(central(ptr).connect(identifier: String(cString: identifier), timeoutMs: timeoutMs, cancel: token(cancel))))
}

/// Starts disconnecting a peripheral, exposed to C as `corebluetooth_mac_central_disconnect`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The peripheral's identifier.
/// - Returns: An envelope with `null` data. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_central_disconnect)
public func cCentralDisconnect(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    envelope(CBMEnvelope.status(central(ptr).disconnect(identifier: String(cString: identifier))))
}

/// Returns a peripheral's connection state, exposed to C as `corebluetooth_mac_peripheral_state`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The peripheral's identifier.
/// - Returns: `disconnected`, `connecting`, `connected`, `disconnecting`, `closed`, or `unknown`. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_peripheral_state)
public func cPeripheralState(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    strdup(central(ptr).peripheralState(identifier: String(cString: identifier)))!
}

/// Discovers a peripheral's services, exposed to C as `corebluetooth_mac_peripheral_discover_services`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The connected peripheral's identifier.
///   - serviceUUIDsJSON: A JSON array of service UUID strings, or `NULL` for every service.
///   - timeoutMs: The longest wait in milliseconds.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: An envelope with an array of `uuid` / `is_primary` hashes. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_peripheral_discover_services)
public func cPeripheralDiscoverServices(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ serviceUUIDsJSON: UnsafePointer<CChar>?,
    _ timeoutMs: Int32,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<CChar> {
    envelope(CBMEnvelope.result(central(ptr).discoverServices(
        identifier: String(cString: identifier),
        serviceUUIDs: uuids(serviceUUIDsJSON),
        timeoutMs: timeoutMs,
        cancel: token(cancel)
    )))
}

/// Discovers a service's characteristics, exposed to C as `corebluetooth_mac_service_discover_characteristics`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The connected peripheral's identifier.
///   - serviceUUID: A discovered service's UUID.
///   - timeoutMs: The longest wait in milliseconds.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: An envelope with an array of `uuid` / `properties` / `initial_value` hashes. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_service_discover_characteristics)
public func cServiceDiscoverCharacteristics(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ serviceUUID: UnsafePointer<CChar>,
    _ timeoutMs: Int32,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<CChar> {
    envelope(CBMEnvelope.result(central(ptr).discoverCharacteristics(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: serviceUUID),
        timeoutMs: timeoutMs,
        cancel: token(cancel)
    )))
}

/// Discovers a service's included services, exposed to C as `corebluetooth_mac_service_discover_included_services`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The connected peripheral's identifier.
///   - serviceUUID: A discovered service's UUID.
///   - timeoutMs: The longest wait in milliseconds.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: An envelope with an array of `uuid` / `is_primary` hashes. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_service_discover_included_services)
public func cServiceDiscoverIncludedServices(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ serviceUUID: UnsafePointer<CChar>,
    _ timeoutMs: Int32,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<CChar> {
    envelope(CBMEnvelope.result(central(ptr).discoverIncludedServices(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: serviceUUID),
        timeoutMs: timeoutMs,
        cancel: token(cancel)
    )))
}

/// Reads a characteristic's value, exposed to C as `corebluetooth_mac_characteristic_read`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The connected peripheral's identifier.
///   - serviceUUID: A discovered service's UUID.
///   - charUUID: A discovered characteristic's UUID.
///   - timeoutMs: The longest wait in milliseconds.
///   - lenOut: Receives the value's length.
///   - envelopeOut: Receives an envelope with `null` data or the error. Release it with ``cFree(_:)``.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: The value on success, or `NULL` on error. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_characteristic_read)
public func cCharacteristicRead(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ serviceUUID: UnsafePointer<CChar>,
    _ charUUID: UnsafePointer<CChar>,
    _ timeoutMs: Int32,
    _ lenOut: UnsafeMutablePointer<Int32>,
    _ envelopeOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<UInt8>? {
    readResult(central(ptr).readCharacteristic(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: serviceUUID),
        charUUID: String(cString: charUUID),
        timeoutMs: timeoutMs,
        cancel: token(cancel)
    ), lenOut, envelopeOut)
}

/// Writes a characteristic's value, exposed to C as `corebluetooth_mac_characteristic_write`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The connected peripheral's identifier.
///   - serviceUUID: A discovered service's UUID.
///   - charUUID: A discovered characteristic's UUID.
///   - data: The bytes to write.
///   - dataLen: The number of bytes in `data`.
///   - withResponse: Nonzero to write with response.
///   - timeoutMs: The longest wait in milliseconds. Zero sends a write without response at once.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: An envelope with `null` data. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_characteristic_write)
public func cCharacteristicWrite(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ serviceUUID: UnsafePointer<CChar>,
    _ charUUID: UnsafePointer<CChar>,
    _ data: UnsafePointer<UInt8>,
    _ dataLen: Int32,
    _ withResponse: Int32,
    _ timeoutMs: Int32,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<CChar> {
    envelope(CBMEnvelope.status(central(ptr).writeCharacteristic(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: serviceUUID),
        charUUID: String(cString: charUUID),
        data: Data(UnsafeBufferPointer(start: data, count: Int(dataLen))),
        withResponse: withResponse != 0,
        timeoutMs: timeoutMs,
        cancel: token(cancel)
    )))
}

/// Reads a peripheral's RSSI, exposed to C as `corebluetooth_mac_peripheral_read_rssi`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The connected peripheral's identifier.
///   - timeoutMs: The longest wait in milliseconds.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: An envelope with the RSSI in dBm. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_peripheral_read_rssi)
public func cPeripheralReadRSSI(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ timeoutMs: Int32,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<CChar> {
    envelope(CBMEnvelope.result(central(ptr).readRSSI(identifier: String(cString: identifier), timeoutMs: timeoutMs, cancel: token(cancel))))
}

/// Returns the error of a peripheral's last disconnection, exposed to C as `corebluetooth_mac_peripheral_last_disconnect_error`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The peripheral's identifier.
/// - Returns: An envelope with the error hash, or `null` after a clean disconnection. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_peripheral_last_disconnect_error)
public func cPeripheralLastDisconnectError(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    let error = central(ptr).lastDisconnectError(identifier: String(cString: identifier))
    return envelope(CBMEnvelope.ok(error.map { CBMError.from($0, fallbackDomain: "connection").json }))
}

/// Takes one event from a peripheral's event queue, exposed to C as `corebluetooth_mac_peripheral_poll_events`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The peripheral's identifier.
///   - timeoutMs: The longest wait in milliseconds.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: An envelope with a `tag` / `payload` hash, or `null` on timeout. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_peripheral_poll_events)
public func cPeripheralPollEvents(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ timeoutMs: Int32,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<CChar> {
    envelope(CBMEnvelope.result(central(ptr).pollPeripheralEvents(identifier: String(cString: identifier), timeoutMs: timeoutMs, cancel: token(cancel))))
}

/// Returns the longest value a single write can carry, exposed to C as `corebluetooth_mac_peripheral_max_write_length`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The connected peripheral's identifier.
///   - withResponse: Nonzero for writes with response.
/// - Returns: An envelope with the length in bytes. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_peripheral_max_write_length)
public func cPeripheralMaxWriteLength(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ withResponse: Int32
) -> UnsafeMutablePointer<CChar> {
    envelope(CBMEnvelope.result(central(ptr).maxWriteLength(identifier: String(cString: identifier), withResponse: withResponse != 0)))
}

/// Turns notifications on and registers a subscription, exposed to C as `corebluetooth_mac_characteristic_subscribe`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The connected peripheral's identifier.
///   - serviceUUID: A discovered service's UUID.
///   - charUUID: A discovered characteristic's UUID.
///   - timeoutMs: The longest wait in milliseconds.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: An envelope with the subscription id. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_characteristic_subscribe)
public func cCharacteristicSubscribe(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ serviceUUID: UnsafePointer<CChar>,
    _ charUUID: UnsafePointer<CChar>,
    _ timeoutMs: Int32,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<CChar> {
    envelope(CBMEnvelope.result(central(ptr).subscribeCharacteristic(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: serviceUUID),
        charUUID: String(cString: charUUID),
        timeoutMs: timeoutMs,
        cancel: token(cancel)
    )))
}

/// Turns notifications off and closes the characteristic's subscriptions, exposed to C as `corebluetooth_mac_characteristic_unsubscribe`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The connected peripheral's identifier.
///   - serviceUUID: A discovered service's UUID.
///   - charUUID: A discovered characteristic's UUID.
///   - timeoutMs: The longest wait in milliseconds.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: An envelope with `null` data. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_characteristic_unsubscribe)
public func cCharacteristicUnsubscribe(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ serviceUUID: UnsafePointer<CChar>,
    _ charUUID: UnsafePointer<CChar>,
    _ timeoutMs: Int32,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<CChar> {
    envelope(CBMEnvelope.status(central(ptr).unsubscribeCharacteristic(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: serviceUUID),
        charUUID: String(cString: charUUID),
        timeoutMs: timeoutMs,
        cancel: token(cancel)
    )))
}

/// Takes the next notification value of a subscription, exposed to C as `corebluetooth_mac_subscription_next_value`.
///
/// - Parameters:
///   - subscriptionId: An id from ``cCharacteristicSubscribe(_:_:_:_:_:_:)``.
///   - timeoutMs: The longest wait in milliseconds.
///   - closedOut: Receives 1 when the subscription is closed and drained or unknown, otherwise 0.
///   - lenOut: Receives the value's length.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: The value, or `NULL` on timeout or when closed. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_subscription_next_value)
public func cSubscriptionNextValue(
    _ subscriptionId: Int64,
    _ timeoutMs: Int32,
    _ closedOut: UnsafeMutablePointer<Int32>,
    _ lenOut: UnsafeMutablePointer<Int32>,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<UInt8>? {
    lenOut.pointee = 0
    let (data, closed) = CBMSubscriptionRegistry.shared.dequeue(subscriptionId: subscriptionId, timeoutMs: timeoutMs, cancel: token(cancel))
    closedOut.pointee = closed ? 1 : 0
    return data.map { bytes($0, lenOut) }
}

/// Closes a subscription and wakes its pending wait, exposed to C as `corebluetooth_mac_subscription_close`.
///
/// - Parameter subscriptionId: An id from ``cCharacteristicSubscribe(_:_:_:_:_:_:)``. Unknown ids are ignored.
@c(corebluetooth_mac_subscription_close)
public func cSubscriptionClose(_ subscriptionId: Int64) {
    CBMSubscriptionRegistry.shared.close(subscriptionId: subscriptionId)
}

/// Discovers a characteristic's descriptors, exposed to C as `corebluetooth_mac_characteristic_discover_descriptors`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The connected peripheral's identifier.
///   - serviceUUID: A discovered service's UUID.
///   - charUUID: A discovered characteristic's UUID.
///   - timeoutMs: The longest wait in milliseconds.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: An envelope with an array of `uuid` hashes. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_characteristic_discover_descriptors)
public func cCharacteristicDiscoverDescriptors(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ serviceUUID: UnsafePointer<CChar>,
    _ charUUID: UnsafePointer<CChar>,
    _ timeoutMs: Int32,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<CChar> {
    envelope(CBMEnvelope.result(central(ptr).discoverDescriptors(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: serviceUUID),
        charUUID: String(cString: charUUID),
        timeoutMs: timeoutMs,
        cancel: token(cancel)
    )))
}

/// Reads a descriptor's value, exposed to C as `corebluetooth_mac_descriptor_read`.
///
/// Number values are returned as 2 little-endian bytes and strings as UTF-8.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The connected peripheral's identifier.
///   - serviceUUID: A discovered service's UUID.
///   - charUUID: A discovered characteristic's UUID.
///   - descUUID: A discovered descriptor's UUID.
///   - timeoutMs: The longest wait in milliseconds.
///   - lenOut: Receives the value's length.
///   - envelopeOut: Receives an envelope with `null` data or the error. Release it with ``cFree(_:)``.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: The value on success, or `NULL` on error. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_descriptor_read)
public func cDescriptorRead(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ serviceUUID: UnsafePointer<CChar>,
    _ charUUID: UnsafePointer<CChar>,
    _ descUUID: UnsafePointer<CChar>,
    _ timeoutMs: Int32,
    _ lenOut: UnsafeMutablePointer<Int32>,
    _ envelopeOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<UInt8>? {
    readResult(central(ptr).readDescriptor(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: serviceUUID),
        charUUID: String(cString: charUUID),
        descUUID: String(cString: descUUID),
        timeoutMs: timeoutMs,
        cancel: token(cancel)
    ), lenOut, envelopeOut)
}

/// Writes a descriptor's value, exposed to C as `corebluetooth_mac_descriptor_write`.
///
/// - Parameters:
///   - ptr: A central from ``cCentralNew()``.
///   - identifier: The connected peripheral's identifier.
///   - serviceUUID: A discovered service's UUID.
///   - charUUID: A discovered characteristic's UUID.
///   - descUUID: A discovered descriptor's UUID.
///   - data: The bytes to write.
///   - dataLen: The number of bytes in `data`.
///   - timeoutMs: The longest wait in milliseconds.
///   - cancel: A token from ``cCancelNew()``.
/// - Returns: An envelope with `null` data. Release it with ``cFree(_:)``.
@c(corebluetooth_mac_descriptor_write)
public func cDescriptorWrite(
    _ ptr: UnsafeMutableRawPointer,
    _ identifier: UnsafePointer<CChar>,
    _ serviceUUID: UnsafePointer<CChar>,
    _ charUUID: UnsafePointer<CChar>,
    _ descUUID: UnsafePointer<CChar>,
    _ data: UnsafePointer<UInt8>,
    _ dataLen: Int32,
    _ timeoutMs: Int32,
    _ cancel: UnsafeMutableRawPointer
) -> UnsafeMutablePointer<CChar> {
    envelope(CBMEnvelope.status(central(ptr).writeDescriptor(
        identifier: String(cString: identifier),
        serviceUUID: String(cString: serviceUUID),
        charUUID: String(cString: charUUID),
        descUUID: String(cString: descUUID),
        data: Data(UnsafeBufferPointer(start: data, count: Int(dataLen))),
        timeoutMs: timeoutMs,
        cancel: token(cancel)
    )))
}
