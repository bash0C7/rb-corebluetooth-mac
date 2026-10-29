# frozen_string_literal: true

require_relative "../test_helper"

class TestServiceShape < Test::Unit::TestCase
  def test_is_primary_attr_reader
    s = CoreBluetoothMac::Service.new(peripheral: nil, uuid: "1800", is_primary: true)
    assert_equal true, s.is_primary
  end

  def test_primary_predicate_removed
    s = CoreBluetoothMac::Service.new(peripheral: nil, uuid: "1800", is_primary: true)
    refute s.respond_to?(:primary?)
  end

  def test_included_service_uuids_starts_empty
    s = CoreBluetoothMac::Service.new(peripheral: nil, uuid: "1800", is_primary: true)
    assert_equal [], s.included_service_uuids
  end

  def test_initialize_requires_is_primary_kwarg
    assert_raise(ArgumentError) do
      CoreBluetoothMac::Service.new(peripheral: nil, uuid: "1800")
    end
  end
end
