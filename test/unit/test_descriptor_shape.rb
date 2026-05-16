# frozen_string_literal: true

require_relative "../test_helper"

class TestDescriptorShape < Test::Unit::TestCase
  def test_initialize_with_uuid_and_characteristic
    d = CoreBluetoothMac::Descriptor.new(characteristic: nil, uuid: "2902")
    assert_equal "2902", d.uuid
    assert_nil d.value
  end
end
