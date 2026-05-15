# frozen_string_literal: true

require "json"
require "set"

require_relative "corebluetooth_mac/version"

module CoreBluetoothMac
  class Error           < StandardError; end
  class StateError      < Error;          end
  class PermissionError < StateError;     end
  class TimeoutError    < Error;          end
  class ConnectionError < Error;          end
  class DiscoveryError  < Error;          end
  class IOError         < Error;          end
  class ClosedError     < Error;          end
end
