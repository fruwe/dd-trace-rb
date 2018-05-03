require 'spec_helper'
require 'ddtrace'

require 'active_record'
require 'mysql2'
require 'sqlite3'

RSpec.describe 'ActiveRecord multi-database implementation' do
  let(:tracer) { ::Datadog::Tracer.new(writer: FauxWriter.new) }
  let(:configuration_options) { { tracer: tracer, service_name: default_db_service_name } }
  let(:default_db_service_name) { 'default-db' }

  let(:application_record) do
    stub_const('ApplicationRecord', Class.new(ActiveRecord::Base) do
      self.abstract_class = true
    end)
  end

  let!(:gadget_class) do
    stub_const('Gadget', Class.new(application_record)).tap do |klass|
      # Connect to the default database
      ActiveRecord::Base.establish_connection('mysql2://root:root@127.0.0.1:53306/mysql')

      begin
        klass.count
      rescue ActiveRecord::StatementInvalid
        ActiveRecord::Schema.define(version: 20180101000000) do
          create_table 'gadgets', force: :cascade do |t|
            t.string   'title'
            t.datetime 'created_at', null: false
            t.datetime 'updated_at', null: false
          end
        end

        # Prevent extraneous spans from showing up
        klass.count
      end
    end
  end

  let!(:widget_class) do
    stub_const('Widget', Class.new(application_record)).tap do |klass|
      # Connect the Widget database
      klass.establish_connection(adapter: 'sqlite3', database: ':memory:')

      begin
        klass.count
      rescue ActiveRecord::StatementInvalid
        klass.connection.create_table 'widgets', force: :cascade do |t|
          t.string   'title'
          t.datetime 'created_at', null: false
          t.datetime 'updated_at', null: false
        end

        # Prevent extraneous spans from showing up
        klass.count
      end
    end
  end

  subject(:spans) do
    gadget_class.count
    widget_class.count
    tracer.writer.spans
  end

  let(:gadget_span) { spans[0] }
  let(:widget_span) { spans[1] }

  before(:each) do
    Datadog.registry[:active_record].reset_configuration!

    Datadog.configure do |c|
      # c.tracer debug: true
      c.use :active_record, configuration_options
    end
  end

  after(:each) do
    Datadog.registry[:active_record].reset_configuration!
  end

  context 'when databases are configured with' do
    let(:gadget_db_service_name) { 'gadget-db' }
    let(:widget_db_service_name) { 'widget-db' }

    context 'a Symbol that matches a configuration' do
      context 'when ActiveRecord has configurations' do
        before(:each) do
          # Stub ActiveRecord::Base, to pretend its been configured
          allow(ActiveRecord::Base).to receive(:configurations).and_return(
            {
              'gadget' => {
                'encoding' => 'utf8',
                'adapter'=>'mysql2',
                'username'=>'root',
                'host' => '127.0.0.1',
                'port' => 53306,
                'password' => nil,
                'database' => 'mysql'
              },
              'widget' => {
                'adapter' => 'sqlite3',
                'pool' => 5,
                'timeout' => 5000,
                'database' => ':memory:'
              }
            }
          )

          Datadog.configure do |c|
            c.use :active_record, describes: :gadget do |gadget_db|
              gadget_db.tracer = tracer
              gadget_db.service_name = gadget_db_service_name
            end

            c.use :active_record, describes: :widget do |widget_db|
              widget_db.tracer = tracer
              widget_db.service_name = widget_db_service_name
            end
          end
        end

        it do
          # Gadget is configured to show up as its own database service
          expect(gadget_span.service).to eq(gadget_db_service_name)
          # Widget is configured to show up as its own database service
          expect(widget_span.service).to eq(widget_db_service_name)
        end
      end
    end

    context 'a String that\'s a URL' do
      context 'for a typical server' do
        before(:each) do
          Datadog.configure do |c|
            c.use :active_record, describes: 'mysql2://root@127.0.0.1:53306/mysql' do |gadget_db|
              gadget_db.tracer = tracer
              gadget_db.service_name = gadget_db_service_name
            end
          end
        end

        it do
          # Gadget is configured to show up as its own database service
          expect(gadget_span.service).to eq(gadget_db_service_name)
          # Widget isn't, ends up assigned to the default database service
          expect(widget_span.service).to eq(default_db_service_name)
        end
      end

      context 'for an in-memory database' do
        before(:each) do
          Datadog.configure do |c|
            c.use :active_record, describes: 'sqlite3::memory:' do |widget_db|
              widget_db.tracer = tracer
              widget_db.service_name = widget_db_service_name
            end
          end
        end

        it do
          # Gadget belongs to the default database
          expect(gadget_span.service).to eq(default_db_service_name)
          # Widget belongs to its own database
          expect(widget_span.service).to eq(widget_db_service_name)
        end
      end
    end

    context 'a Hash that describes a connection' do
      before(:each) do
        widget_db_connection_hash = { adapter: 'sqlite3', database: ':memory:' }

        Datadog.configure do |c|
          c.use :active_record, describes: widget_db_connection_hash do |widget_db|
            widget_db.tracer = tracer
            widget_db.service_name = widget_db_service_name
          end
        end
      end

      it do
        # Gadget belongs to the default database
        expect(gadget_span.service).to eq(default_db_service_name)
        # Widget belongs to its own database
        expect(widget_span.service).to eq(widget_db_service_name)
      end
    end
  end
end
