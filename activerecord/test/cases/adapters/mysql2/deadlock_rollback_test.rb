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

      @deadlocks = []
      @unexpecteds = []
      @past_deadlock = 0
      @mutexes = [:choose, :sync_var, :sync_thread, :ok_proceed].inject({}) do |h, k|
        h[k] = Mutex.new;
        h
      end
    end

    teardown do
      @connection.drop_table "samples", if_exists: true
      Thread.abort_on_exception = @abort
    end

    test "detects and processes standard Deadlock" do
      begin
        successes = 0
        threads = (0..1).map do
          Thread.new do
            result = deadlock_pair(require_new: false)
            successes += 1 if result
          end
        end
        threads.each { |t| t.join }
      rescue StandardError => e
        byebug
        assert false, "no unexpected exceptions were raised in main thread: #{e}"
      end

      byebug
      assert_equal 0, @unexpecteds.count, "no unexpected exceptions were raised in threads: #{@unexpecteds}"
      assert_equal 1, @deadlocks.count, "exactly one deadlock was raised"
      assert_equal 1, @past_deadlock, "exactly one query made it past the deadlock"
      assert_equal 0, @mutexes.values.count { |m| m.locked? }, "no mutexes remain locked"
      assert_equal 2, successes, "both conn.transaction halves returned true"
    end

    def deadlock_pair(require_new: false)

      # This function is invoked in two threads, i.e., it will be called twice
      # and both invocations will run simultaneously. They use mutexes to
      # communicate -- :choose to make a binary choice, :sync_thread and
      # :ok_proceed to coordinate timing at a key point, and :sync_var to
      # update variables for reporting back to the main thread.

      success = nil
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
          puts Thread.current.object_id.to_s.last(5) + "\t" + "starting SHARE MODE half"
          success = conn.transaction(:requires_new => require_new) do
            begin
              conn.execute("SELECT * FROM #{table_name} WHERE value=1 LOCK IN SHARE MODE")

              # Hand off control to the other thread.
              @mutexes[:sync_thread].lock
              sleep 0.001 until @mutexes[:ok_proceed].locked?

              # Sleep a half-second so the DELETE thread can issue its query.
              # (We can't wait for anything more specific, because the
              # execute() doesn't return until/unless the lock/deadlock occurs.)
              sleep 0.5

              # Next query causes deadlock.
              conn.execute("DELETE FROM #{table_name} WHERE value=1")

              @mutexes[:sync_var].synchronize do
                @past_deadlock += 1;
                puts Thread.current.object_id.to_s.last(5) + "\t" + "SHARE MODE past_deadlock"
              end

            rescue StandardError => e
              @mutexes[:sync_var].synchronize {
                (exception_is_deadlock?(e) ?  @deadlocks : @unexpecteds) << e
              }
              raise e
            ensure
              @mutexes[:sync_thread].unlock if @mutexes[:sync_thread].locked?
            end
          end
          @mutexes[:choose].unlock

        else

          # We didn't get the lock, we are the DELETE half.
          puts Thread.current.object_id.to_s.last(5) + "\t" + "starting DELETE half"
          success = conn.transaction(:requires_new => require_new) do
            begin

              # Wait until the first thread is ready and hands off control.
              sleep 0.001 until @mutexes[:sync_thread].locked?
              @mutexes[:ok_proceed].lock

              # Next query goes into LOCK WAIT state until the above thread's
              # DELETE causes a deadlock which resolves them both.
              # <https://dev.mysql.com/doc/refman/5.5/en/innodb-trx-table.html>
              conn.execute("DELETE FROM #{table_name} WHERE value=1")

              @mutexes[:sync_var].synchronize do
                @past_deadlock += 1
                puts Thread.current.object_id.to_s.last(5) + "\t" + "SHARE MODE past_deadlock"
              end

            rescue StandardError => e
              @mutexes[:sync_var].synchronize {
                (exception_is_deadlock?(e) ?  @deadlocks : @unexpecteds) << e
              }
              raise e
            ensure
              @mutexes[:ok_proceed].unlock if @mutexes[:ok_proceed].locked?
            end
          end

        end
      end
    end

    def exception_is_deadlock?(e)
      e.is_a?(ActiveRecord::StatementInvalid) &&
        /Deadlock found when trying to get lock; try restarting transaction/ =~ e.to_s
    end

    class SQLPrinter
      def call(name, start, finish, message_id, values)
        return if values[:cached]
        puts Thread.current.object_id.to_s.last(5) + "\t" + values[:sql]
      end
    end
    ActiveSupport::Notifications.subscribe("sql.active_record", SQLPrinter.new)
  end
end
