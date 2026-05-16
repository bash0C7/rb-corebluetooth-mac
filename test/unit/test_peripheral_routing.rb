# frozen_string_literal: true

require "test_helper"

class PeripheralRoutingTest < Test::Unit::TestCase
  StubCentral = Struct.new(:central_id) do
    def calls; @calls ||= []; end
    def stub(op, &body); (@stubs ||= {})[op] = body; end

    def __call_native(op, *args)
      calls << [op, args]
      (@stubs && @stubs[op] || ->(*) { nil }).call(*args)
    end
  end

  def setup
    @central = StubCentral.new(1)
    @peripheral = CoreBluetoothMac::Peripheral.new(central: @central, identifier: "AAAA")
  end

  def test_identifier_accessor
    assert_equal "AAAA", @peripheral.identifier
  end

  def test_discover_services_invokes_native_with_args
    @central.stub(:peripheral_discover_services) do |_id, _filter, _ms|
      [{"uuid" => "0000180a-0000-1000-8000-00805f9b34fb", "is_primary" => true}]
    end
    @peripheral.discover_services(timeout: 2.5)
    assert_equal [:peripheral_discover_services, ["AAAA", nil, 2500]], @central.calls.first
  end

  def test_discover_services_populates_services
    @central.stub(:peripheral_discover_services) do |_id, _filter, _ms|
      [{"uuid" => "0000180a-0000-1000-8000-00805f9b34fb", "is_primary" => true},
       {"uuid" => "00001800-0000-1000-8000-00805f9b34fb", "is_primary" => true}]
    end
    @peripheral.discover_services
    assert_equal 2, @peripheral.services.size
    assert_equal "00001800-0000-1000-8000-00805f9b34fb", @peripheral.services.last.uuid
    assert_equal true, @peripheral.services.last.is_primary
  end

  def test_discover_services_with_single_uuid_filter_passes_json_array
    @central.stub(:peripheral_discover_services) { |*| [] }
    @peripheral.discover_services(services: "1800", timeout: 1.0)
    assert_equal [:peripheral_discover_services, ["AAAA", '["1800"]', 1000]],
                 @central.calls.first
  end

  def test_discover_services_with_array_filter_passes_json_array
    @central.stub(:peripheral_discover_services) { |*| [] }
    @peripheral.discover_services(services: ["1800", "180a"], timeout: 1.0)
    assert_equal [:peripheral_discover_services, ["AAAA", '["1800","180a"]', 1000]],
                 @central.calls.first
  end

  def test_discover_services_with_empty_array_filter_passes_nil
    @central.stub(:peripheral_discover_services) { |*| [] }
    @peripheral.discover_services(services: [], timeout: 1.0)
    assert_equal [:peripheral_discover_services, ["AAAA", nil, 1000]],
                 @central.calls.first
  end

  def test_discover_services_rejects_invalid_filter_type
    err = assert_raise(CoreBluetoothMac::Error) do
      @peripheral.discover_services(services: 42)
    end
    assert_equal :validation, err.domain
  end

  def test_services_raises_discovery_error_before_discover
    err = assert_raise(CoreBluetoothMac::Error) { @peripheral.services }
    assert_equal :discovery, err.domain
    assert_equal "call discover_services first", err.message
  end

  def test_find_service_case_insensitive
    @central.stub(:peripheral_discover_services) do |_id, _filter, _ms|
      [{"uuid" => "00001800-0000-1000-8000-00805f9b34fb", "is_primary" => true}]
    end
    @peripheral.discover_services
    svc = @peripheral.find_service("00001800-0000-1000-8000-00805F9B34FB")
    refute_nil svc
    assert_equal "00001800-0000-1000-8000-00805f9b34fb", svc.uuid
  end

  def test_state_routes_to_native
    @central.stub(:peripheral_state) { |_| :connected }
    assert_equal :connected, @peripheral.state
    assert_equal [:peripheral_state, ["AAAA"]], @central.calls.last
  end
end

class ServiceRoutingTest < Test::Unit::TestCase
  def setup
    @central = PeripheralRoutingTest::StubCentral.new(1)
    @peripheral = CoreBluetoothMac::Peripheral.new(central: @central, identifier: "AAAA")
    @central.stub(:peripheral_discover_services) do |_id, _filter, _ms|
      [{"uuid" => "00001800-0000-1000-8000-00805f9b34fb", "is_primary" => true}]
    end
    @peripheral.discover_services
    @service = @peripheral.services.first
  end

  def test_discover_characteristics_invokes_native
    @central.stub(:service_discover_characteristics) do |_pid, _sid, _ms|
      [{"uuid" => "00002a00-0000-1000-8000-00805f9b34fb", "properties" => ["read"]}]
    end
    @service.discover_characteristics(timeout: 3.0)
    assert_equal [:service_discover_characteristics,
                  ["AAAA", "00001800-0000-1000-8000-00805f9b34fb", 3000]],
                 @central.calls.last
  end

  def test_discover_characteristics_populates
    @central.stub(:service_discover_characteristics) do |_p, _s, _t|
      [{"uuid" => "00002a00-0000-1000-8000-00805f9b34fb", "properties" => ["read"]}]
    end
    @service.discover_characteristics
    ch = @service.characteristics.first
    assert_equal "00002a00-0000-1000-8000-00805f9b34fb", ch.uuid
    assert ch.supports?(:read)
    refute(ch.supports?(:write) || ch.supports?(:write_without_response))
  end

  def test_characteristics_raises_before_discover
    err = assert_raise(CoreBluetoothMac::Error) { @service.characteristics }
    assert_equal :closed, err.domain
  end

  def test_find_characteristic_raises_before_discover
    err = assert_raise(CoreBluetoothMac::Error) { @service.find_characteristic("anything") }
    assert_equal :closed, err.domain
  end
end

class CharacteristicRoutingTest < Test::Unit::TestCase
  def setup
    @central = PeripheralRoutingTest::StubCentral.new(1)
    @peripheral = CoreBluetoothMac::Peripheral.new(central: @central, identifier: "AAAA")
    @central.stub(:peripheral_discover_services) do |*|
      [{"uuid" => "00001800-0000-1000-8000-00805f9b34fb", "is_primary" => true}]
    end
    @peripheral.discover_services
    @service = @peripheral.services.first
    @central.stub(:service_discover_characteristics) do |_p, _s, _t|
      [{"uuid" => "00002a00-0000-1000-8000-00805f9b34fb",
        "properties" => ["read", "write", "notify"]}]
    end
    @service.discover_characteristics
    @ch = @service.characteristics.first
  end

  def test_read_routes_to_native
    @central.stub(:characteristic_read) { |_p, _s, _c, _t| "value".b }
    bytes = @ch.read(timeout: 4.0)
    assert_equal "value".b, bytes
    assert_equal [:characteristic_read,
                  ["AAAA", "00001800-0000-1000-8000-00805f9b34fb",
                   "00002a00-0000-1000-8000-00805f9b34fb", 4000]],
                 @central.calls.last
  end

  def test_write_with_response_routes
    @central.stub(:characteristic_write) { |*| nil }
    @ch.write("payload", response: true, timeout: 2.0)
    assert_equal [:characteristic_write,
                  ["AAAA", "00001800-0000-1000-8000-00805f9b34fb",
                   "00002a00-0000-1000-8000-00805f9b34fb",
                   "payload", 1, 2000]],
                 @central.calls.last
  end

  def test_write_without_response_routes
    @central.stub(:characteristic_write) { |*| nil }
    @ch.write_without_response("p")
    assert_equal [:characteristic_write,
                  ["AAAA", "00001800-0000-1000-8000-00805f9b34fb",
                   "00002a00-0000-1000-8000-00805f9b34fb",
                   "p", 0, 0]],
                 @central.calls.last
  end

  def test_subscribe_returns_Subscription_with_id
    @central.stub(:characteristic_subscribe) { |*| 1001 }
    sub = @ch.subscribe
    assert_kind_of CoreBluetoothMac::Subscription, sub
    assert_equal 1, sub.central_id
    assert_equal 1001, sub.subscription_id
  end

  def test_unsubscribe_routes
    @central.stub(:characteristic_unsubscribe) { |*| nil }
    @ch.unsubscribe
    assert_equal [:characteristic_unsubscribe,
                  ["AAAA", "00001800-0000-1000-8000-00805f9b34fb",
                   "00002a00-0000-1000-8000-00805f9b34fb"]],
                 @central.calls.last
  end
end
