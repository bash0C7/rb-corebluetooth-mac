# frozen_string_literal: true

module CoreBluetoothMac
  class Error < StandardError
    attr_reader :domain, :code, :code_name

    # NOTE: `:unknown` default is a temporary tolerance for C-bridge raise sites
    # that have not yet been rewritten to the JSON envelope (Plan Task 3).
    # Once Task 3 lands, change `domain:` to a required keyword.
    def initialize(message, domain: :unknown, code: nil, code_name: nil)
      super(message)
      @domain = domain
      @code = code
      @code_name = code_name
    end
  end
end
