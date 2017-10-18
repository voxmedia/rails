# frozen_string_literal: true

require "cases/helper"
require "support/connection_helper"
require "concurrent/atomic/cyclic_barrier"

module ActiveRecord
  class PostgresqlTransactionNestedTest < ActiveRecord::PostgreSQLTestCase
    self.use_transactional_tests = false

    class Sample < ActiveRecord::Base
      self.table_name = "samples"
    end

    setup do
      @abort, Thread.abort_on_exception = Thread.abort_on_exception, false

      @connection = ActiveRecord::Base.connection

      @connection.transaction do
        @connection.drop_table "samples", if_exists: true
        @connection.create_table("samples") do |t|
          t.integer "value"
        end
      end

      Sample.reset_column_information
    end

    teardown do
      @connection.reconnect!
      @connection.drop_table "samples", if_exists: true

      Thread.abort_on_exception = @abort
    end

    test "unserializable transaction raises SerializationFailure inside nested SavepointTransaction" do
      assert_raises(ActiveRecord::SerializationFailure) do
        before = Concurrent::CyclicBarrier.new(2)
        after = Concurrent::CyclicBarrier.new(2)

        begin
          thread = Thread.new do
            with_warning_suppression do
              Sample.transaction(isolation: :serializable, requires_new: false) do
                Sample.transaction(requires_new: true) do
                  before.wait
                  Sample.create value: Sample.sum(:value)
                  after.wait
                end
              end
            end
          end

          begin
            with_warning_suppression do
              Sample.transaction(isolation: :serializable, requires_new: false) do
                Sample.transaction(requires_new: true) do
                  before.wait
                  Sample.create value: Sample.sum(:value)
                  after.wait
                end
              end
            end
          ensure
            thread.join
          end
        end
      end
    end

    test "deadlock raises Deadlocked inside nested SavepointTransaction" do
      with_warning_suppression do
        assert_raises(ActiveRecord::Deadlocked) do
          barrier = Concurrent::CyclicBarrier.new(2)

          s1 = Sample.create value: 1
          s2 = Sample.create value: 2

          begin
            thread = Thread.new do
              Sample.transaction(requires_new: false) do
                Sample.transaction(requires_new: true) do
                  s1.lock!
                  barrier.wait
                  s2.update_attributes value: 1
                end
              end
            end

            begin
              Sample.transaction(requires_new: false) do
                Sample.transaction(requires_new: true) do
                  s2.lock!
                  barrier.wait
                  s1.update_attributes value: 2
                end
              end
            ensure
              thread.join
            end
          end
        end
      end
    end

    private

      def with_warning_suppression
        #log_level = ActiveRecord::Base.connection.client_min_messages
        #ActiveRecord::Base.connection.client_min_messages = "error"
        yield
      ensure
        #ActiveRecord::Base.connection.client_min_messages = log_level
      end
  end
end
