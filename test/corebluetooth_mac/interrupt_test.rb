# frozen_string_literal: true

require "test_helper"

class InterruptTest < Test::Unit::TestCase
  def setup
    @central = HardwareGuard.central_or_omit(self)
  end

  def teardown
    @central&.close
  end

  def test_thread_raise_stops_a_blocking_scan_at_once
    th = Thread.new do
      Thread.current.report_on_exception = false
      @central.scan(timeout: 10.0)
    end
    sleep 0.5
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    th.raise(RuntimeError, "stop")
    assert_raise(RuntimeError) { th.value }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
  end
end
