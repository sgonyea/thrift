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
  class ProcessPoolServer < BaseServer
    class ChildProcess
      def self.fork(master, worker_number, io_read, io_write)
        Process.fork do
          new(master, worker_number, io_read, io_write).call
        end
      end

      attr_reader :master, :worker_number, :io_read, :io_write, :command_queue
      def initialize(master, worker_number, io_read, io_write)
        @master, @worker_number, @io_read, @io_write = master, worker_number, io_read, io_write
        @command_queue = Queue.new
        start_command_queue
        handle_at_exit
        io_read.close
        create_child_pid_file
        watch_master_process
        @thread_q = SizedQueue.new(thread_pool_size)
      end

      def call
        begin
          thread = Thread.start do
            loop do
              @thread_q.push(:token)
              Thread.new do
                begin
                  loop do
                    client = server_transport.accept
                    trans = transport_factory.get_transport(client)
                    prot = protocol_factory.get_protocol(trans)
                    processor_process(trans, prot)
                  end
                ensure
                  @thread_q.pop # thread died!
                end
              end
            end
          end
          thread.join
          Process.exit 0
        rescue => e
          io_write.puts [Marshal.dump(e)].pack("m")
          io_write.flush
          Process.exit 1
        end
      end

      def processor_process(trans, prot)
        begin
          loop do
            processor.process(prot, prot) do |process_message|
              thread_block_queue = SizedQueue.new(1)
              thread_block_queue.push(:token)
              command_queue.enq(lambda do
                process_message.call
                thread_block_queue.pop
              end)
              thread_block_queue.push(:token)
            end
          end
        rescue Thrift::TransportException, Thrift::ProtocolException => e
        rescue => e
          raise e
        ensure
          trans.close
        end
      end

      def start_command_queue
        Thread.start do
          begin
            loop do
              while command = command_queue.deq
                command.call
              end
            end
          ensure
            Process.exit
          end
        end
      end

      def handle_at_exit
        at_exit do
          command_queue.enq(lambda do
            exit!
          end)
        end
      end

      def watch_master_process
        @watch_master_process_watcher = Thread.new do
          loop do
            unless master_is_running?
              command_queue.enq(lambda do
                exit!
              end)
            end
          end
        end
      end

      def master_is_running?
        begin
          Process.kill("USR1", master_pid)
          true
        rescue Errno::ESRCH => e
          # Process does not exist
          false
        end
      end

      def thread_pool_size
        master.thread_pool_size
      end

      def server_transport
        master.server_transport
      end

      def transport_factory
        master.transport_factory
      end

      def protocol_factory
        master.protocol_factory
      end

      def processor
        master.processor
      end

      def master_pid
        master.pid
      end

      def pid_dir
        master.pid_dir
      end

      def pid
        Process.pid
      end

      def create_child_pid_file
        worker_pid_file = "#{pid_dir}/worker_#{worker_number}.pid"
        File.open(worker_pid_file, "w") do |f|
          f.write pid
        end
        at_exit do
          FileUtils.rm_f(worker_pid_file)
        end
      end
    end

    attr_reader :process_pool_size, :thread_pool_size, :pid_dir, :processor, :server_transport, :transport_factory, :protocol_factory, :pid

    def initialize(processor, server_transport, transport_factory=nil, protocol_factory=nil, params={})
      super(processor, server_transport, transport_factory, protocol_factory)
      @pool_size = 0
      @process_pool_size = params[:process_pool_size] || 10
      @thread_pool_size = params[:thread_pool_size] || 20
      @pid_dir = params[:pid_dir] || "#{root_dir}/tmp/pids"
      @exception_q = Queue.new
      @running = false
      @child_processes = {}
      @pid = Process.pid
      enable_serving
    end

    ## exceptions that happen in worker threads will be relayed here and
    ## must be caught. 'retry' can be used to continue. (threads will
    ## continue to run while the exception is being handled.)
    def rescuable_serve
      Thread.new { serve } unless @running
      @running = true
      raise @exception_q.pop
    end

    ## exceptions that happen in worker process simply cause that thread
    ## to die and another to be spawned in its place.
    def serve
      write_master_pid
      signal_handlers
      fork_child_process_loop
    end

    def signal_handlers
      at_exit do
        if File.exists?(master_pid) && File.read(master_pid).strip == Process.pid.to_s
          puts "Exiting..."
          disable_serving
          kill_child_processes # We need this so there are no zombies when the master is killed (i.e. monit)
          rm_master_pid
        end
      end
      ["INT", "TERM"].each do |sig|
        ::Signal.trap(sig) do
          exit
        end
      end

      ::Signal.trap("USR1") do
        # noop
      end
    end

    def fork_child_process_loop
      @server_transport.listen
      begin
        worker_number = 0
        loop do
          break unless @serving_enabled
          io_read, io_write = IO.pipe
          pid = ChildProcess.fork(self, worker_number, io_read, io_write)
          io_write.close
          @child_processes[pid] = lambda do
            Marshal.load(io_read.read.unpack("m")[0])
          end
          if @child_processes.length >= @process_pool_size
            finished_pid, finished_status = Process.wait2 # Wait until a child process terminates
            if finished_status.exitstatus && finished_status.exitstatus > 0
              @exception_q.push(@child_processes[finished_pid].call)
            end
            @child_processes.delete finished_pid
          end
          worker_number += 1
        end
      ensure
        @server_transport.close
      end
    end

    def enable_serving
      @serving_enabled = true
    end

    def disable_serving
      @serving_enabled = false
    end

    def kill_child_processes
      @child_processes.keys.each do |pid|
        begin
          Process.kill("INT", pid)
        rescue Errno::ESRCH => e
          # Process does not exist
        end
      end
    end

    protected
    def write_master_pid
      File.open(master_pid, "w") do |f|
        f.write(Process.pid)
      end
    end

    def rm_master_pid
      FileUtils.rm_f(master_pid)
    end

    def master_pid
      "#{pid_dir}/master.pid"
    end
  end
end
