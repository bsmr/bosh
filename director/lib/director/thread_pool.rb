module Bosh::Director

  class ThreadPool

    def initialize(options = {})
      @actions = []
      @lock = Mutex.new
      @max_threads = options[:max_threads] || 1
      @available_threads = @max_threads
      @logger = Config.logger
      @boom = nil
      @original_thread = Thread.current
      @threads = []
      @state = :open
    end

    def wrap
      begin
        yield self
        wait
      ensure
        shutdown
      end
    end

    def process(&block)
      @lock.synchronize do
        @actions << block
        if @available_threads > 0
          @logger.debug("Creating new thread")
          @available_threads -= 1
          create_thread
        else
          @logger.debug("All threads are currently busy, queuing action")
        end
      end
    end

    def create_thread
      thread = Thread.new do
        begin
          loop do
            action = nil
            @lock.synchronize do
              action = @actions.shift
              if action
                @logger.debug("Found an action that needs to be processed")
              else
                @logger.debug("Thread is no longer needed, cleaning up")
                @available_threads += 1
                @threads.delete(thread) if @state == :open
              end
            end

            break unless action

            begin
              action.call
            rescue Exception => e
              raise_worker_exception(e)
            end
          end
        end
      end
      @threads << thread
    end

    def raise_worker_exception(exception)
      if exception.respond_to?(:backtrace)
        @logger.debug("Worker thread raised exception: #{exception} - #{exception.backtrace.join("\n")}")
      else
        @logger.debug("Worker thread raised exception: #{exception}")
      end
      @lock.synchronize do
        if @boom.nil?
          Thread.new do
            @boom = exception
            @logger.debug("Re-raising: #{@boom}")
            @original_thread.raise(@boom)
          end
        end
      end
    end

    def working?
      @boom.nil? && (@available_threads != @max_threads || !@actions.empty?)
    end

    def wait(interval = 0.1)
      @logger.debug("Waiting for tasks to complete")
      sleep(interval) while working?
    end

    def shutdown
      return if @state == :closed
      @logger.debug("Shutting down pool")
      @lock.synchronize do
        return if @state == :closed
        @state = :closed
        @actions.clear
      end
      @threads.each { |t| t.join }
    end

  end

end