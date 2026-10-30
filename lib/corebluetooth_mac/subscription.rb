# frozen_string_literal: true

module CoreBluetoothMac
  Subscription = Data.define(:central_id, :subscription_id) do
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
