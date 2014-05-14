# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require File.expand_path(File.join(File.dirname(__FILE__),'..','..','..','..','test_helper'))
class NewRelic::Agent::MethodTracer::TraceExecutionScopedTest < Minitest::Test
  require 'new_relic/agent/method_tracer'
  include NewRelic::Agent::MethodTracer

  def setup
    NewRelic::Agent.agent.stats_engine.clear_stats
  end

  def test_get_stats_unscoped
    fake_engine = mocked_object('stat_engine')
    fake_engine.expects(:get_stats_no_scope).with('foob').returns('fakestats')
    assert_equal 'fakestats', get_stats_unscoped('foob')
  end

  def test_get_stats_scoped_scoped_only
    fake_engine = mocked_object('stat_engine')
    fake_engine.expects(:get_stats).with('foob', true, true).returns('fakestats')
    assert_equal 'fakestats', get_stats_scoped('foob', true)
  end

  def test_get_stats_scoped_no_scoped_only
    fake_engine = mocked_object('stat_engine')
    fake_engine.expects(:get_stats).with('foob', true, false).returns('fakestats')
    assert_equal 'fakestats', get_stats_scoped('foob', false)
  end

  def test_stat_engine
    assert_equal agent_instance.stats_engine, stat_engine
  end

  def test_agent_instance
    assert_equal NewRelic::Agent.instance, agent_instance
  end

  def test_metric_recording_outside_transaction
    trace_execution_scoped(['foo']) do
      # meh
    end
    assert_metrics_recorded_exclusive(
      'foo' => { :call_count => 1 }
    )
  end

  def test_metric_recording_in_non_nested_transaction
    in_transaction('outer') do
      trace_execution_scoped(['foo', 'bar']) do
        # erm
      end
    end

    expected_values = { :call_count => 1 }
    assert_metrics_recorded_exclusive(
      ['foo', 'outer'] => expected_values,
      'foo'            => expected_values,
      'bar'            => expected_values,
      'outer'          => expected_values
    )
  end

  def test_metric_recording_in_nested_transactions
    in_transaction('Controller/outer_txn') do
      in_transaction('Controller/inner_txn') do
        trace_execution_scoped(['foo', 'bar']) do
          # erm
        end
      end
    end

    expected_values = { :call_count => 1 }
    assert_metrics_recorded_exclusive(
      'HttpDispatcher'                                    => expected_values,
      'Controller/inner_txn'                              => expected_values,

      'Nested/Controller/inner_txn'                           => expected_values,
      ['Nested/Controller/inner_txn', 'Controller/inner_txn'] => expected_values,
      'Nested/Controller/outer_txn'                           => expected_values,
      ['Nested/Controller/outer_txn', 'Controller/inner_txn'] => expected_values,

      ['foo'                    , 'Controller/inner_txn'] => expected_values,
      'foo'                                               => expected_values,
      'bar'                                               => expected_values
    )
  end

  def test_metric_recording_in_3_nested_transactions
    in_transaction('Controller/outer_txn') do
      in_transaction('Controller/middle_txn') do
        in_transaction('Controller/inner_txn') do
          # erm
        end
      end
    end

    assert_metrics_recorded([
      'Controller/inner_txn',
      'Nested/Controller/inner_txn',
      'Nested/Controller/middle_txn',
      'Nested/Controller/outer_txn'
      ])
  end

  def test_metric_recording_inside_transaction
    in_transaction('outer') do
      trace_execution_scoped(['foo', 'bar']) do
        # erm
      end
    end

    expected_values = { :call_count => 1 }
    assert_metrics_recorded_exclusive(
      'outer'          => expected_values,
      'foo'            => expected_values,
      ['foo', 'outer'] => expected_values,
      'bar'            => expected_values
    )
  end

  def test_metric_recording_without_metric_option
    options = { :metric => false, :scoped_metric => false }

    in_transaction('outer') do
      trace_execution_scoped(['foo', 'bar'], options) do
        # erm
      end
    end

    expected_values = { :call_count => 1 }
    assert_metrics_recorded_exclusive(
      'outer' => expected_values,
      'bar'   => expected_values
    )
  end

  def test_set_if_nil
    h = {}
    set_if_nil(h, :foo)
    assert h[:foo]
    h[:bar] = false
    set_if_nil(h, :bar)
    assert !h[:bar]
  end

  def test_log_errors_base
    ran = false
    log_errors("name") do
      ran = true
    end
    assert ran, "should run the contents of the block"
  end

  def test_log_errors_with_return
    ran = false
    return_val = log_errors('name') do
      ran = true
      'happy trees'
    end

    assert ran, "should run contents of block"
    assert_equal 'happy trees', return_val, "should return contents of the block"
  end

  def test_log_errors_with_error
    expects_logging(:error,
      includes("Caught exception in name."),
      instance_of(RuntimeError))

    log_errors("name") do
      raise "should not propagate out of block"
    end
  end

  def test_trace_execution_scoped_header
    options = {:force => false, :deduct_call_time_from_parent => false}
    self.expects(:log_errors).with(:trace_execution_scoped_header).yields
    NewRelic::Agent::TracedMethodStack.expects(:push_frame).with(:method_tracer, 1.0, false)
    trace_execution_scoped_header(options, 1.0)
  end

  def test_trace_execution_scoped_calculates_exclusive_time
    freeze_time
    in_transaction('txn') do
      trace_execution_scoped(['parent']) do
        advance_time(10)
        trace_execution_scoped(['child']) do
          advance_time(10)
        end
      end
    end

    assert_metrics_recorded_exclusive(
      'txn'    => {
        :call_count           =>  1,
      },
      'parent' => {
        :call_count           =>  1,
        :total_call_time      => 20,
        :total_exclusive_time => 10,
      },
      ['parent', 'txn'] => {
        :call_count           =>  1,
        :total_call_time      => 20,
        :total_exclusive_time => 10,
      },
      'child'  => {
        :call_count           =>  1,
        :total_call_time      => 10,
        :total_exclusive_time => 10,
      },
      ['child', 'txn']  => {
        :call_count           =>  1,
        :total_call_time      => 10,
        :total_exclusive_time => 10,
      }
    )
  end

  def test_trace_execution_scoped_disabled
    self.expects(:traced?).returns(false)
    # make sure the method doesn't beyond the abort
    self.expects(:set_if_nil).never
    ran = false
    value = trace_execution_scoped(nil, {:options => 'hash'}) do
      ran = true
      1172
    end

    assert ran, 'should run contents of block'
    assert_equal 1172, value, 'should return contents of block'
  end

  def test_trace_execution_scope_runs_passed_block_and_returns_its_value
    value = trace_execution_scoped(['metric', 'array'], {}) do
      1172
    end
    assert_equal 1172, value, 'should return the contents of the block'
  end

  def test_trace_execution_scoped_does_not_swallow_errors
    assert_raises(RuntimeError) do
      trace_execution_scoped(['metric', 'array'], {}) do
        raise 'raising a test error'
      end
    end
  end

  private

  def mocked_object(name)
    object = mock(name)
    self.stubs(name).returns(object)
    object
  end

  def mocked_control
    mocked_object('control')
  end
end
