# frozen_string_literal: true

require_relative "../test_helper"

class TestPeripheralEventShape < Test::Unit::TestCase
  def test_name_updated_is_data
    e = CoreBluetoothMac::PeripheralEvent::NameUpdated.new(name: "newname")
    assert_equal "newname", e.name
    # NOTE: assert_predicate e, :frozen? omitted per handoff §4.2 — Data.define
    # instances are not auto-frozen; Ractor-shareability is verified in
    # test_event_classes_ractor_shareable.
  end

  def test_services_invalidated_carries_uuids
    e = CoreBluetoothMac::PeripheralEvent::ServicesInvalidated.new(uuids: ["1800"])
    assert_equal ["1800"], e.uuids
  end

  def test_disconnected_carries_error
    e = CoreBluetoothMac::PeripheralEvent::Disconnected.new(error: nil)
    assert_nil e.error
  end

  def test_event_classes_ractor_shareable
    e = CoreBluetoothMac::PeripheralEvent::NameUpdated.new(name: "x")
    assert Ractor.shareable?(e), "PeripheralEvent must be Ractor-shareable"
  end
end
