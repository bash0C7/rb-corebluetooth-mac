# frozen_string_literal: true

# Codes mirror CBError.h enums (Swift `CBError.Code` / `CBATTError.Code`).
# Verified against /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/CoreBluetooth.framework/Versions/A/Headers/CBError.h.

module CoreBluetoothMac
  module ErrorCodes
    CB = {
      0 => :unknown,
      1 => :invalid_parameters,
      2 => :invalid_handle,
      3 => :not_connected,
      4 => :out_of_space,
      5 => :operation_cancelled,
      6 => :connection_timeout,
      7 => :peripheral_disconnected,
      8 => :uuid_not_allowed,
      9 => :already_advertising,
      10 => :connection_failed,
      11 => :connection_limit_reached,
      12 => :unknown_device,
      13 => :operation_not_supported,
      14 => :peer_removed_pairing_information,
      15 => :encryption_timed_out,
      16 => :too_many_le_paired_devices,
    }.freeze

    ATT = {
      0x00 => :success,
      0x01 => :invalid_handle,
      0x02 => :read_not_permitted,
      0x03 => :write_not_permitted,
      0x04 => :invalid_pdu,
      0x05 => :insufficient_authentication,
      0x06 => :request_not_supported,
      0x07 => :invalid_offset,
      0x08 => :insufficient_authorization,
      0x09 => :prepare_queue_full,
      0x0A => :attribute_not_found,
      0x0B => :attribute_not_long,
      0x0C => :insufficient_encryption_key_size,
      0x0D => :invalid_attribute_value_length,
      0x0E => :unlikely_error,
      0x0F => :insufficient_encryption,
      0x10 => :unsupported_group_type,
      0x11 => :insufficient_resources,
    }.freeze

    def self.cb_name(code)  = CB[code]
    def self.att_name(code) = ATT[code]
  end
end
