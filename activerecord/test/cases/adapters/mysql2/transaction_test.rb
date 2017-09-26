# frozen_string_literal: true

require "cases/helper"
require "support/connection_helper"
require "byebug"

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

    test "raises Deadlocked when a deadlock is encountered" do
      puts( capture_sql do
        assert_raises(ActiveRecord::Deadlocked) do
          begin
            cause_deadlock_1
          rescue StandardError => e
            byebug
            puts "rescue outside: #{e}"
            raise e
          ensure
            byebug
            puts "ensure outside: #{e}"
          end
        end
      end.join("\n"))
    end

    test "rolls back RealTransaction when a deadlock is encountered" do
      results = nil
      puts( capture_sql do
        results = @connection.transaction(:requires_new => false) do
          begin
            cause_deadlock_2
          rescue StandardError => e
            byebug
            puts "rescue inside Real: #{e}"
            raise e
          ensure
            byebug
            puts "ensure inside Real: #{e}"
          end
        end
      end.join("\n") )
      refute results
    end

    test "rolls back SavepointTransaction when a deadlock is encountered" do
      results = nil
      puts( capture_sql do
        results = @connection.transaction(:requires_new => true) do
          begin
            cause_deadlock_2
          rescue StandardError => e
            byebug
            puts "rescue inside Savepoint: #{e}"
            raise e
          ensure
            byebug
            puts "ensure inside Savepoint: #{e}"
          end
        end
      end.join("\n"))
      refute results
    end

    def cause_deadlock_1
      barrier = Concurrent::CyclicBarrier.new(2)

      s1 = Sample.create value: 1
      s2 = Sample.create value: 2

      thread = Thread.new do
        Sample.transaction do
          s1.lock!
          barrier.wait
          s2.update_attributes value: 1
        end
      end

      begin
        Sample.transaction do
          s2.lock!
          barrier.wait
          s1.update_attributes value: 2
        end
      ensure
        thread.join
      end
    end

    def cause_deadlock_2
      begin
        successes = 0
        threads = (0..1).map do
          Thread.new do
            result = deadlock_pair
            successes += 1 if result
          end
        end
        threads.each { |t| t.join }
      rescue StandardError => e
        assert false, "no unexpected exceptions were raised in main thread: #{e}"
      end
    end

    def deadlock_pair

      # This function is invoked in two threads, i.e., it will be called twice
      # and both invocations will run simultaneously. They use mutexes to
      # communicate -- :choose to make a binary choice, :sync_thread and
      # :ok_proceed to coordinate timing at a key point, and :sync_var to
      # update variables for reporting back to the main thread.

      success = nil
      first_time = true
      table_name = Sample.table_name

      # Each thread gets a separate connection from the pool.
      # "ConnectionPool is completely thread-safe, and will ensure
      # that a connection cannot be used by two threads at the same
      # time, as long as ConnectionPool's contract is correctly followed."
      ActiveRecord::Base.connection_pool.with_connection do |conn|

        # Just a safety check.
        assert_equal conn.owner, Thread.current, "thread owns Mysql2Adapter"

        # Try to grab a semaphore to see which half of the pair we're going to do.
        # In one of them -- whichever one MySQL decides to kill -- the
        # retry_deadlocks() block will be called more than once.

        if @mutexes[:choose].try_lock

          # We got the lock, we are the SHARE MODE half.
          conn.execute("SET AUTOCOMMIT=0")
          conn.execute("START TRANSACTION")
          conn.execute("SELECT * FROM #{table_name} WHERE i=1 LOCK IN SHARE MODE")
          success = Utils::Transaction.retry_deadlocks(connection: conn) do
            begin
              if first_time

                # Hand off control to the other thread.
                @mutexes[:sync_thread].lock
                sleep 0.001 until @mutexes[:ok_proceed].locked?

                # Sleep a half-second so the DELETE thread can issue its query.
                # (We can't wait for anything more specific, because the
                # execute() doesn't return until/unless the lock/deadlock occurs.)
                sleep 0.5

                # Next query causes deadlock.
                first_time = false
                conn.execute("DELETE FROM #{table_name} WHERE i=1")

                @mutexes[:sync_var].synchronize { @past_deadlock += 1 }
              else
                @mutexes[:sync_var].synchronize { @blocks_rerun += 1 }
              end
            rescue StandardError => e
              @mutexes[:sync_var].synchronize {
                (Utils::Transaction.exception_is_deadlock?(e) ?  @deadlocks : @unexpecteds) << e
              }
              raise e
            ensure
              @mutexes[:sync_thread].unlock if @mutexes[:sync_thread].locked?
            end
          end
          @mutexes[:choose].unlock

        else

          # We didn't get the lock, we are the DELETE half.
          success = Utils::Transaction.retry_deadlocks(connection: conn) do
            begin
              if first_time

                # Wait until the first thread is ready and hands off control.
                conn.execute("SET AUTOCOMMIT=0")
                conn.execute("START TRANSACTION")
                sleep 0.001 until @mutexes[:sync_thread].locked?
                @mutexes[:ok_proceed].lock

                # Next query goes into LOCK WAIT state until the above thread's
                # DELETE causes a deadlock which resolves them both.
                # <https://dev.mysql.com/doc/refman/5.5/en/innodb-trx-table.html>
                first_time = false
                conn.execute("DELETE FROM #{table_name} WHERE i=1")

                @mutexes[:sync_var].synchronize { @past_deadlock += 1 }
              else
                @mutexes[:sync_var].synchronize { @blocks_rerun += 1 }
              end
            rescue StandardError => e
              @mutexes[:sync_var].synchronize {
                (Utils::Transaction.exception_is_deadlock?(e) ?  @deadlocks : @unexpecteds) << e
              }
              raise e
            ensure
              @mutexes[:ok_proceed].unlock if @mutexes[:ok_proceed].locked?
            end
          end

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
