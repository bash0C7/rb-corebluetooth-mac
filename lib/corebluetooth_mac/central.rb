# frozen_string_literal: true

module CoreBluetoothMac
  class Central
    def initialize(state_timeout: 3.0)
      @native = Native.new((state_timeout * 1000).to_i)
    end

    def central_id
      @native.central_id
    end
  end
end
