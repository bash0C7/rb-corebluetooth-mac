# frozen_string_literal: true

require "test_helper"

class ModuleTest < Test::Unit::TestCase
  def test_VERSION_is_a_string
    assert_kind_of String, CoreBluetoothMac::VERSION
  end

  def test_VERSION_is_semver
    assert_match(/\A\d+\.\d+\.\d+\z/, CoreBluetoothMac::VERSION)
  end
end
