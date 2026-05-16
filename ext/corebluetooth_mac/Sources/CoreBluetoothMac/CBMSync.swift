import Foundation
@preconcurrency import CoreBluetooth
import os

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

// Domain values for the `.lib` case mirror the Ruby-side error model:
//   "timeout","closed","connection","discovery","validation"
// `.cb` / `.att` carry a numeric code + symbolic code_name parsed from the
// native CoreBluetooth NSError domains (CBErrorDomain / CBATTErrorDomain).
enum CBMError: Error {
    case lib(domain: String, message: String)
    case cb(code: Int, codeName: String, message: String)
    case att(code: Int, codeName: String, message: String)

    var json: [String: Any] {
        switch self {
        case .lib(let domain, let message):
            return ["domain": domain, "code": NSNull(), "code_name": NSNull(), "message": message]
        case .cb(let code, let codeName, let message):
            return ["domain": "cb", "code": code, "code_name": codeName, "message": message]
        case .att(let code, let codeName, let message):
            return ["domain": "att", "code": code, "code_name": codeName, "message": message]
        }
    }
}

extension CBMError {
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
}

// Mirror of Ruby's ErrorCodes.cb_name / att_name.
// Source: /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/.../CBError.h
private func cbCodeName(_ code: Int) -> String {
    switch code {
    case 0: return "unknown"
    case 1: return "invalid_parameters"
    case 2: return "invalid_handle"
    case 3: return "not_connected"
    case 4: return "out_of_space"
    case 5: return "operation_cancelled"
    case 6: return "connection_timeout"
    case 7: return "peripheral_disconnected"
    case 8: return "uuid_not_allowed"
    case 9: return "already_advertising"
    case 10: return "connection_failed"
    case 11: return "connection_limit_reached"
    case 12: return "unknown_device"
    case 13: return "operation_not_supported"
    case 14: return "peer_removed_pairing_information"
    case 15: return "encryption_timed_out"
    case 16: return "too_many_le_paired_devices"
    default: return "unknown"
    }
}

private func attCodeName(_ code: Int) -> String {
    switch code {
    case 0x00: return "success"
    case 0x01: return "invalid_handle"
    case 0x02: return "read_not_permitted"
    case 0x03: return "write_not_permitted"
    case 0x04: return "invalid_pdu"
    case 0x05: return "insufficient_authentication"
    case 0x06: return "request_not_supported"
    case 0x07: return "invalid_offset"
    case 0x08: return "insufficient_authorization"
    case 0x09: return "prepare_queue_full"
    case 0x0A: return "attribute_not_found"
    case 0x0B: return "attribute_not_long"
    case 0x0C: return "insufficient_encryption_key_size"
    case 0x0D: return "invalid_attribute_value_length"
    case 0x0E: return "unlikely_error"
    case 0x0F: return "insufficient_encryption"
    case 0x10: return "unsupported_group_type"
    case 0x11: return "insufficient_resources"
    default: return "unknown"
    }
}

// JSON envelope serializer: every Swift→C string return is wrapped in either
//   {"ok": true,  "data": <payload>}
//   {"ok": false, "error": {"domain": ..., "code": ..., "code_name": ..., "message": ...}}
// The C bridge parses this and either returns the data field or raises
// CoreBluetoothMac::Error with structured domain/code/code_name keywords.
struct CBMEnvelope {
    static func ok(_ data: Any?) -> String {
        let env: [String: Any] = ["ok": true, "data": data ?? NSNull()]
        let bytes = try! JSONSerialization.data(withJSONObject: env)
        return String(data: bytes, encoding: .utf8)!
    }
    static func err(_ e: CBMError) -> String {
        let env: [String: Any] = ["ok": false, "error": e.json]
        let bytes = try! JSONSerialization.data(withJSONObject: env)
        return String(data: bytes, encoding: .utf8)!
    }
}
