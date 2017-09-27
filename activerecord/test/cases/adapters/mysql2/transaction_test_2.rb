# frozen_string_literal: true

require "cases/helper"
require "support/connection_helper"

module ActiveRecord
  class Mysql2TransactionTest < ActiveRecord::Mysql2TestCase
    self.use_transactional_tests = false

    class Sample < ActiveRecord::Base
      self.table_name = "samples"
    end

    setup do
      @abort, Thread.abort_on_exception = Thread.abort_on_exception, false

      @connection = ActiveRecord::Base.connection
      @connection.clear_cache!

      @connection.transaction do
        @connection.drop_table "samples", if_exists: true
        @connection.create_table("samples") do |t|
          t.integer "value"
        end
      end

      Sample.reset_column_information
    end

    teardown do
      @connection.drop_table "samples", if_exists: true

      Thread.abort_on_exception = @abort
    end

    test "rolls back with no exception after Deadlocked inside SavepointTransaction" do
      barrier = Concurrent::CyclicBarrier.new(2)
      s1 = Sample.create value: 1
      s2 = Sample.create value: 2

      begin
        thread = Thread.new do
          # Start a RealTransaction
          Sample.transaction(:requires_new => false) do
            # Start a SavepointTransaction inside it
            Sample.transaction(:requires_new => true) do
              s1.lock!
              barrier.wait
              s2.update_attributes value: 1
            end
          end
        end

        begin
          # Start a RealTransaction
          Sample.transaction(:requires_new => false) do
            # Start a SavepointTransaction inside it
            Sample.transaction(:requires_new => true) do
              s2.lock!
              barrier.wait
              s1.update_attributes value: 2
            end
          end
        ensure
          thread.join
        end

      rescue ActiveRecord::StatementInvalid => e
        if /SAVEPOINT active_record_. does not exist: ROLLBACK TO SAVEPOINT/ =~ e.to_s
          assert nil, 'ROLLBACK TO SAVEPOINT query issued for savepoint that no longer exists due to deadlock'
        else
          raise e
        end
      end
    end

    test "raises TransactionTimeout when mysql raises ER_LOCK_WAIT_TIMEOUT" do
      assert_raises(ActiveRecord::TransactionTimeout) do
        ActiveRecord::Base.connection.execute("SIGNAL SQLSTATE 'HY000' SET MESSAGE_TEXT = 'Testing error', MYSQL_ERRNO = 1205;")
      end
    end
  end
end
