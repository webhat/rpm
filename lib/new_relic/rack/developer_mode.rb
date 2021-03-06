# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require 'rack'
require 'rack/request'
require 'rack/response'
require 'rack/file'

require 'conditional_vendored_metric_parser'
require 'new_relic/collection_helper'
require 'new_relic/metric_parser/metric_parser'
require 'new_relic/rack/agent_middleware'
require 'new_relic/agent/instrumentation/middleware_proxy'

require 'new_relic/transaction_sample'
require 'new_relic/transaction_analysis'

module NewRelic
  class TransactionSample
    include TransactionAnalysis
  end

  module Rack
    # This middleware provides the 'developer mode' feature of newrelic_rpm,
    # which allows you to see data about local web transactions in development
    # mode immediately without needing to send this data to New Relic's servers.
    #
    # Enabling developer mode has serious performance and security impact, and
    # thus you should never use this middleware in a production or non-local
    # environment.
    #
    # This middleware should be automatically inserted in most contexts, but if
    # automatic middleware insertion fails, you may manually insert it into your
    # middleware chain.
    #
    # @api public
    #
    class DeveloperMode < AgentMiddleware

      VIEW_PATH   = File.expand_path('../../../../ui/views/'  , __FILE__)
      HELPER_PATH = File.expand_path('../../../../ui/helpers/', __FILE__)
      require File.join(HELPER_PATH, 'developer_mode_helper.rb')

      include NewRelic::DeveloperModeHelper

      class << self
        attr_writer :profiling_enabled
      end

      def self.profiling_enabled?
        @profiling_enabled
      end

      def traced_call(env)
        return @app.call(env) unless /^\/newrelic/ =~ ::Rack::Request.new(env).path_info
        dup._call(env)
      end

      protected

      def _call(env)
        NewRelic::Agent.ignore_transaction

        @req = ::Rack::Request.new(env)
        @rendered = false
        case @req.path_info
        when /profile/
          profile
        when /file/
          ::Rack::File.new(VIEW_PATH).call(env)
        when /index/
          index
        when /threads/
          threads
        when /reset/
          reset
        when /show_sample_detail/
          show_sample_data
        when /show_sample_summary/
          show_sample_data
        when /show_sample_sql/
          show_sample_data
        when /explain_sql/
          explain_sql
        when /^\/newrelic\/?$/
          index
        else
          @app.call(env)
        end
      end

      private

      def index
        get_samples
        render(:index)
      end

      def reset
        NewRelic::Agent.instance.transaction_sampler.reset!
        NewRelic::Agent.instance.sql_sampler.reset!
        ::Rack::Response.new{|r| r.redirect('/newrelic/')}.finish
      end

      def explain_sql
        get_segment

        return render(:sample_not_found) unless @sample

        @sql = @segment[:sql]
        @trace = @segment[:backtrace]

        if NewRelic::Agent.agent.record_sql == :obfuscated
          @obfuscated_sql = @segment.obfuscated_sql
        end

        _headers, explanations = @segment.explain_sql
        if explanations
          @explanation = explanations
          if !@explanation.blank?
            first_row = @explanation.first
            # Show the standard headers if it looks like a mysql explain plan
            # Otherwise show blank headers
            if first_row.length < NewRelic::MYSQL_EXPLAIN_COLUMNS.length
              @row_headers = nil
            else
              @row_headers = NewRelic::MYSQL_EXPLAIN_COLUMNS
            end
          end
        end
        render(:explain_sql)
      end

      def profile
        should_be_on = (params['start'] == 'true')
        NewRelic::Rack::DeveloperMode.profiling_enabled = should_be_on

        index
      end

      def threads
        render(:threads)
      end

      def render(view, layout=true)
        add_rack_array = true
        if view.is_a? Hash
          layout = false
          if view[:object]
            # object *is* used here, as it is capture in the binding below
            object = view[:object]
          end

          if view[:collection]
            return view[:collection].map do |obj|
              render({:partial => view[:partial], :object => obj})
            end.join(' ')
          end

          if view[:partial]
            add_rack_array = false
            view = "_#{view[:partial]}"
          end
        end
        binding = Proc.new {}.binding
        if layout
          body = render_with_layout(view) do
            render_without_layout(view, binding)
          end
        else
          body = render_without_layout(view, binding)
        end
        if add_rack_array
          ::Rack::Response.new(body, 200, {'Content-Type' => 'text/html'}).finish
        else
          body
        end
      end

      # You have to call this with a block - the contents returned from
      # that block are interpolated into the layout
      def render_with_layout(view)
        body = ERB.new(File.read(File.join(VIEW_PATH, 'layouts/newrelic_default.rhtml')))
        body.result(Proc.new {}.binding)
      end

      # you have to pass a binding to this (a proc) so that ERB can have
      # access to helper functions and local variables
      def render_without_layout(view, binding)
        ERB.new(File.read(File.join(VIEW_PATH, 'newrelic', view.to_s + '.rhtml')), nil, nil, 'frobnitz').result(binding)
      end

      def content_tag(tag, contents, opts={})
        opt_values = opts.map {|k, v| "#{k}=\"#{v}\"" }.join(' ')
        "<#{tag} #{opt_values}>#{contents}</#{tag}>"
      end

      def sample
        @sample || @samples[0]
      end

      def params
        @req.params
      end

      def segment
        @segment
      end

      def show_sample_data
        get_sample

        return render(:sample_not_found) unless @sample

        @request_params = @sample.params['request_params'] || {}
        @custom_params = @sample.params['custom_params'] || {}

        controller_metric = @sample.transaction_name

        metric_parser = NewRelic::MetricParser::MetricParser.for_metric_named controller_metric
        @sample_controller_name = metric_parser.controller_name
        @sample_action_name = metric_parser.action_name

        @sql_segments = @sample.sql_segments
        if params['d']
          @sql_segments.sort!{|a,b| b.duration <=> a.duration }
        end

        sort_method = params['sort'] || :total_time
        @profile_options = {:min_percent => 0.5, :sort_method => sort_method.to_sym}

        render(:show_sample)
      end

      def get_samples
        @samples = NewRelic::Agent.instance.transaction_sampler.dev_mode_sample_buffer.samples.select do |sample|
          sample.params[:path] != nil
        end

        return @samples = @samples.sort_by(&:duration).reverse                   if params['h']
        return @samples = @samples.sort{|x,y| x.params[:uri] <=> y.params[:uri]} if params['u']
        @samples = @samples.reverse
      end

      def get_sample
        get_samples
        id = params['id']
        sample_id = id.to_i
        @samples.each do |s|
          if s.sample_id == sample_id
            @sample = s
            return
          end
        end
      end

      def get_segment
        get_sample
        return unless @sample

        segment_id = params['segment'].to_i
        @segment = @sample.find_segment(segment_id)
      end
    end
  end
end
