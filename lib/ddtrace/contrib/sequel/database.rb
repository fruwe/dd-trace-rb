require 'ddtrace/ext/sql'
require 'ddtrace/ext/app_types'
require 'ddtrace/contrib/sequel/utils'

module Datadog
  module Contrib
    module Sequel
      # Adds instrumentation to Sequel::Database
      module Database
        def self.included(base)
          base.send(:prepend, InstanceMethods)
        end

        # Instance methods for instrumenting Sequel::Database
        module InstanceMethods
          def initialize(*args)
            # Setup configuration for this database
            pin = Datadog::Pin.new(
              Datadog.configuration[:sequel][:service_name] || adapter_name,
              app: Integration::APP,
              app_type: Datadog::Ext::AppTypes::DB,
              tracer: Datadog.configuration[:sequel][:tracer] || Datadog.tracer
            )
            pin.onto(self)
            super(*args)
          end

          def run(sql, options = ::Sequel::OPTS)
            pin = Datadog::Pin.get_from(self)
            opts = parse_opts(sql, options)

            response = nil

            pin.tracer.trace('sequel.query') do |span|
              span.service = pin.service
              span.resource = opts[:query]
              span.span_type = Datadog::Ext::SQL::TYPE
              span.set_tag('sequel.db.vendor', adapter_name)
              response = super(sql, options)
            end
            response
          end

          private

          def adapter_name
            Utils.adapter_name(self)
          end

          def parse_opts(sql, opts)
            db_opts = if ::Sequel::VERSION < '3.41.0' && self.class.to_s !~ /Dataset$/
                        @opts
                      elsif instance_variable_defined?(:@pool) && @pool
                        @pool.db.opts
                      end
            Utils.parse_opts(sql, opts, db_opts)
          end
        end
      end
    end
  end
end
