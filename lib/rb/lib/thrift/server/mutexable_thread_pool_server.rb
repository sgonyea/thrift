# 
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements. See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership. The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License. You may obtain a copy of the License at
# 
#   http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied. See the License for the
# specific language governing permissions and limitations
# under the License.
# 

require 'thread'

module Thrift
  class MutexableThreadPoolServer < BaseServer
    attr_accessor :options, :threads, :thread_q, :exception_q, :mutex, :run_proc, :status, :status_mutex, :state, :state_mutex
    attr_reader   :processor, :server_transport, :transport_factory, :protocol_factory

    DEFAULT_OPTIONS = { :num => 20, :mutex => nil }
    
    # @todo: Docs
    def initialize(processor, server_transport, transport_factory=nil, protocol_factory=nil, opts={})
      super(processor, server_transport, transport_factory, protocol_factory)

      self.options  = DEFAULT_OPTIONS.merge(opts)
      self.thread_q = SizedQueue.new(options[:num])
      self.mutex    = options[:mutex]
    end

    # @return [Set<Thread>] The currently running Set of Threads
    def threads
      @threads ||= Set.new
    end

    # @return [true, false] Whether or not any threads are still running.
    def threads?
      !thread_q.empty?
    end

    # @return [Queue<Exception, Error>] A queue of exceptions, raised in child threads.
    def exception_q
      @exception_q ||= Queue.new
    end

    # @return [Hash{Thread => Symbol}] Thread instances, mapped to their current status
    # @see MutexableThreadPoolServer#status_mutex
    def status
      @status ||= Hash.new {|k,v| k[v] = :waiting}
    end

    # @param [Mutex, nil] Will assign the mutex instance variable. If a Mutex is supplied, #unlocked? will be overrided.
    # @return [Mutex, nil] The value of the mutex instance variable.
    # @raise [RuntimeError] Raised if neither a Mutex or a nil has been supplied
    def mutex=(mtx)
      case mtx
      when Mutex
        def unlocked?
          !self.mutex.locked?
        end
      when nil
        # Do nothing.
      else
        raise RuntimeError.new('You must specify a Mutex instance or nil (no Mutex)')
      end

      @mutex = mtx
    end

    # @return [Mutex] The Mutex used to (ideally) control access to the status Hash
    # @see MutexableThreadPoolServer#status
    def status_mutex
      @status_mutex ||= Mutex.new
    end

    # @return [Mutex] The Mutex used to (ideally) control access to the state instance variable
    # @see MutexableThreadPoolServer#state
    def state_mutex
      @state_mutex ||= Mutex.new
    end

    # @param [Thread] An instance of a Thread
    # @return [Symbol] The current status of the Thread. Defaults to :waiting.
    def get_thread_status(thread)
      status_mutex.synchronize {
        status[thread]
      }
    end

    # @param [Thread] An instance of a Thread
    # @return [true, false] Whether or not the Thread in question is marked as waiting.
    def thread_waiting?(thread)
      get_thread_status(thread) == :waiting
    end

    # @param [Thread] An instance of a Thread
    # @return [Symbol] :waiting
    def set_waiting_status(thread)
      status_mutex.synchronize {
        status[thread] = :waiting
      }
    end

    # @param [Thread] An instance of a Thread
    # @return [Symbol] :working
    def set_working_status(thread)
      status_mutex.synchronize {
        status[thread] = :working
      }
    end

    # @return [true, false] False if the passed in Mutex is locked, or if server state is not running. True otherwise.
    # @see #running?
    # @see #unlocked?
    def run_loop?
      unlocked? and running?
    end

    # This method will be overrided, if a Mutex is supplied during initialization of the MutexableThreadPoolServer instance.
    #   Locking the Mutex will prevent any new Threads from being created. However, it will not directly cause all Threads to die.
    # @return [true, false] Whether or not the MutexableThreadPoolServer#mutex is locked.
    def unlocked?
      return(true)
    end

    # @return [Symbol] The current state of the Server
    def state
      state_mutex.synchronize { @state ||= :stopped }
    end

    # @param [Symbol] sym The
    # @return [true, false]
    def state?(sym)
      self.state == sym
    end

    # @return [true, false] The current running status of the MutexableThreadPoolServer.
    def running?
      state? :running
    end

    # @return [Symbol] Sets the state to :running.
    def running!
      self.state = :running
    end

    # @return [Symbol] Sets the state to :stopping.
    def stopping!
      self.state = :stopping
    end

    # @return [Symbol] Sets the state to :stopped.
    def stopped!
      self.state = :stopped
    end

    # This will loop over all threads, killing any that may be waiting for work (and therefore blocking)
    # @see MutexableThreadPoolServer#wait_for_work
    def stop_threads
      stopping!

      while threads?
        threads.each do |thread|
          next unless thread_waiting?(thread)

          thread.kill
          threads.delete thread
        end

        threads.select!(&:alive?)
      end

      stopped!
    end

    # Blocks trying to push to the SizedQueue. Once successful, spins up a new thread.
    def queue_thread
      thread_q.push(:token)

      thread = Thread.new {
        begin
          start_processing(wait_for_work(thread)) while run_loop?
        rescue => e
          exception_q.push(e)
        ensure
          threads.delete thread

          thread_q.pop
        end
      }

      threads << thread
    end

    # Exceptions that happen in worker threads simply cause that thread to die and another to be spawned in its place.
    def serve
      server_transport.listen

      begin
        running!
        yield if block_given?

        queue_thread while run_loop?
      ensure
        server_transport.close
      end
    end

  protected
    # @param [Symbol] state The new state of the Server
    # @return [Symbol] The current state of the Server
    def state=(state)
      state_mutex.synchronize { @state = state }
    end

    # This will block, waiting for a client connection to be establish
    # @param [Thread] An instance of a Thread
    # @return [Socket] A Socket instance, connected to a remote client
    def wait_for_work(thread)
      set_waiting_status(thread)
      client = server_transport.accept
      set_working_status(thread)

      return(client)
    end

    # @param [Socket] A Socket instance, connected to a remote client
    def start_processing(client)
      trans = transport_factory.get_transport(client)
      prot = protocol_factory.get_protocol(trans)
      begin
        loop { processor.process(prot, prot) }
      rescue Thrift::TransportException, Thrift::ProtocolException => e
      ensure
        trans.close
      end
    end
  end
end
