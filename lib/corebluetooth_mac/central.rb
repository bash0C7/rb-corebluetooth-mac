# frozen_string_literal: true

module CoreBluetoothMac
  class Central
    # Phase 1 lands real init in Task 12; for now this is unimplemented.
    def initialize(state_timeout: 3.0)
      raise NotImplementedError, "Central.new arrives in Task 12"
    end
  end
end
