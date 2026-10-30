import CoreBluetooth
import Foundation
import os

/// A mutable reference that crosses `Sendable` boundaries under an external lock.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// An error returned to Ruby as the `error` member of an envelope.
///
/// `.lib` carries one of the domains `timeout`, `closed`, `connection`, `discovery`, `validation`.
/// `.cb` and `.att` carry a code from `CBErrorDomain` and `CBATTErrorDomain`.
enum CBMError: Error {
    case lib(domain: String, message: String)
    case cb(code: Int, codeName: String, message: String)
    case att(code: Int, codeName: String, message: String)

    var json: [String: Any] {
        switch self {
        case .lib(let domain, let message):
            ["domain": domain, "code": NSNull(), "code_name": NSNull(), "message": message]
        case .cb(let code, let codeName, let message):
            ["domain": "cb", "code": code, "code_name": codeName, "message": message]
        case .att(let code, let codeName, let message):
            ["domain": "att", "code": code, "code_name": codeName, "message": message]
        }
    }

    /// Maps an `NSError` from CoreBluetooth to a ``CBMError``.
    ///
    /// - Parameters:
    ///   - nsError: The error a CoreBluetooth callback delivered.
    ///   - fallbackDomain: The `.lib` domain for errors outside `CBErrorDomain` and `CBATTErrorDomain`.
    /// - Returns: `.cb` or `.att` with the code name, or `.lib` in `fallbackDomain`.
    static func from(_ nsError: NSError, fallbackDomain: String = "discovery") -> CBMError {
        let msg = nsError.localizedDescription
        switch nsError.domain {
        case CBErrorDomain:
            return .cb(code: nsError.code, codeName: cbCodeName(nsError.code), message: msg)
        case CBATTErrorDomain:
            return .att(code: nsError.code, codeName: attCodeName(nsError.code), message: msg)
        default:
            return .lib(domain: fallbackDomain, message: msg.isEmpty ? "Unknown error" : msg)
        }
    }

    static let closed = CBMError.lib(domain: "closed", message: "Central closed")
}

private func cbCodeName(_ code: Int) -> String {
    switch code {
    case 1: "invalid_parameters"
    case 2: "invalid_handle"
    case 3: "not_connected"
    case 4: "out_of_space"
    case 5: "operation_cancelled"
    case 6: "connection_timeout"
    case 7: "peripheral_disconnected"
    case 8: "uuid_not_allowed"
    case 9: "already_advertising"
    case 10: "connection_failed"
    case 11: "connection_limit_reached"
    case 12: "unknown_device"
    case 13: "operation_not_supported"
    case 14: "peer_removed_pairing_information"
    case 15: "encryption_timed_out"
    case 16: "too_many_le_paired_devices"
    default: "unknown"
    }
}

private func attCodeName(_ code: Int) -> String {
    switch code {
    case 0x00: "success"
    case 0x01: "invalid_handle"
    case 0x02: "read_not_permitted"
    case 0x03: "write_not_permitted"
    case 0x04: "invalid_pdu"
    case 0x05: "insufficient_authentication"
    case 0x06: "request_not_supported"
    case 0x07: "invalid_offset"
    case 0x08: "insufficient_authorization"
    case 0x09: "prepare_queue_full"
    case 0x0A: "attribute_not_found"
    case 0x0B: "attribute_not_long"
    case 0x0C: "insufficient_encryption_key_size"
    case 0x0D: "invalid_attribute_value_length"
    case 0x0E: "unlikely_error"
    case 0x0F: "insufficient_encryption"
    case 0x10: "unsupported_group_type"
    case 0x11: "insufficient_resources"
    default: "unknown"
    }
}

/// Serializes the JSON envelope every bridge function returns to C.
///
/// Success is `{"ok": true, "data": <payload>}` and failure is `{"ok": false, "error": {...}}` with the members of ``CBMError/json``.
enum CBMEnvelope {
    static func ok(_ data: Any?) -> String {
        serialize(["ok": true, "data": data ?? NSNull()])
    }

    static func err(_ e: CBMError) -> String {
        serialize(["ok": false, "error": e.json])
    }

    static func result(_ r: Result<some Any, CBMError>) -> String {
        switch r {
        case .success(let data): ok(data)
        case .failure(let e): err(e)
        }
    }

    static func status(_ e: CBMError?) -> String {
        e.map(err) ?? ok(nil)
    }

    private static func serialize(_ env: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: env), as: UTF8.self)
    }
}

/// A cancellation token for one blocking call from Ruby.
///
/// ``cancel()`` makes the wait in progress, and every later wait, end as `.timedOut`.
final class CBMCancel: Sendable {
    private let state = OSAllocatedUnfairLock<(cancelled: Bool, waiting: DispatchSemaphore?)>(
        initialState: (false, nil)
    )

    /// Ends the current and all later ``wait(_:until:)`` calls. Only the first call signals the waited semaphore.
    func cancel() {
        let waiting = state.withLock { s -> DispatchSemaphore? in
            if s.cancelled { return nil }
            s.cancelled = true
            return s.waiting
        }
        waiting?.signal()
    }

    /// Waits on `semaphore` until `deadline` or until ``cancel()``.
    ///
    /// - Parameters:
    ///   - semaphore: The semaphore a CoreBluetooth callback signals.
    ///   - deadline: The time at which the wait times out.
    /// - Returns: `.success` when `semaphore` was signaled, `.timedOut` on the deadline or after ``cancel()``.
    func wait(_ semaphore: DispatchSemaphore, until deadline: DispatchTime) -> DispatchTimeoutResult {
        let cancelled = state.withLock { s in
            s.waiting = semaphore
            return s.cancelled
        }
        let result = cancelled ? .timedOut : semaphore.wait(timeout: deadline)
        return state.withLock { s in
            s.waiting = nil
            return s.cancelled ? .timedOut : result
        }
    }

    /// Waits until `deadline` or until ``cancel()``.
    ///
    /// - Parameter deadline: The time at which the wait ends.
    func sleep(until deadline: DispatchTime) {
        _ = wait(DispatchSemaphore(value: 0), until: deadline)
    }
}

extension DispatchSemaphore {
    /// Consumes every pending signal, such as one from a callback that arrived after an earlier wait timed out.
    func drain() {
        while wait(timeout: .now()) == .success {}
    }
}

/// Returns the deadline `timeoutMs` milliseconds from now.
///
/// - Parameter timeoutMs: The timeout in milliseconds.
/// - Returns: The deadline for ``CBMCancel/wait(_:until:)``.
func deadline(_ timeoutMs: Int32) -> DispatchTime {
    .now() + .milliseconds(Int(timeoutMs))
}
