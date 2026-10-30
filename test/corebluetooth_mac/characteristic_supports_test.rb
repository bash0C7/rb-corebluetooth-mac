# frozen_string_literal: true

require_relative "../test_helper"

class TestCharacteristicSupports < Test::Unit::TestCase
  def make(props, initial_value: nil)
    CoreBluetoothMac::Characteristic.new(
      service: nil, uuid: "abcd",
      properties: Set.new(props),
      initial_value: initial_value
    )
  end

  def test_supports_question_mark
    ch = make([:read, :notify])
    assert ch.supports?(:read)
    assert ch.supports?(:notify)
    refute ch.supports?(:write)
  end

  def test_old_predicates_removed
    ch = make([:read])
    refute ch.respond_to?(:readable?)
    refute ch.respond_to?(:writable?)
    refute ch.respond_to?(:notifiable?)
  end

  def test_full_property_symbols_recognized
    %i[broadcast read write_without_response write notify indicate
       authenticated_signed_writes extended_properties
       notify_encryption_required indicate_encryption_required].each do |sym|
      ch = make([sym])
      assert ch.supports?(sym), "should support #{sym}"
    end
  end

  def test_initial_value_attr
    ch = make([:read], initial_value: "hello".b)
    assert_equal "hello".b, ch.initial_value
    assert_equal Encoding::ASCII_8BIT, ch.initial_value.encoding
  end

  def test_initial_value_nil_default
    ch = make([:read])
    assert_nil ch.initial_value
  end
end
