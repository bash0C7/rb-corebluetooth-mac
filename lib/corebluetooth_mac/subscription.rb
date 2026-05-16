# frozen_string_literal: true

module CoreBluetoothMac
  Subscription = Data.define(:central_id, :subscription_id) do
    # Returns:
    #   String — notification payload (binary)
    #   nil    — timeout (no value arrived within `timeout`)
    #   false  — subscription is closed and drained (terminal; further calls
    #            keep returning false). Use this to terminate polling loops.
    # The C bridge returns the symbol `:closed` for the terminal state; we
    # translate to `false` here so callers can write
    #   while (v = sub.next_value(timeout: 0.5)) ; handle(v) ; end
    # without inspecting symbols, while still distinguishing it from a timeout.
    def next_value(timeout: 1.0)
      r = CoreBluetoothMac.__subscription_next_value(
        central_id, subscription_id, (timeout * 1000).to_i
      )
      return false if r == :closed
      r
    end

    def close
      CoreBluetoothMac.__subscription_close(central_id, subscription_id)
    end
  end
end
