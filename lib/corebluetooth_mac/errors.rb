# frozen_string_literal: true

module CoreBluetoothMac
  class Error < StandardError
    attr_reader :domain, :code, :code_name

    def initialize(message, domain:, code: nil, code_name: nil)
      super(message)
      @domain = domain
      @code = code
      @code_name = code_name
    end
  end
end
