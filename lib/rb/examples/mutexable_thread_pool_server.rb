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
# Contains some contributions under the Thrift Software License.
# Please see doc/old-thrift-license.txt in the Thrift distribution for
# details.

#
# This is very rough and will not run. But it gives you an example
#   of how you might make use of the MutexableThreadPoolServer.
#
module MTPSExample
  def mutex
    @mutex ||= Mutex.new
  end

  def run_thrift_server
    handler   = MTPSExample::Thrift::GenericServiceHandler.new
    processor = MTPSExample::Thrift::GenericService::Processor.new(handler)
    transport = Thrift::ServerSocket.new(port)
    t_factory = Thrift::BufferedTransportFactory.new

    @server = Thrift::MutexableThreadPoolServer.new(processor, transport, t_factory, nil, {:num => 20, :mutex => mutex})

    info "Service 'mtps_example' started with Process ID #{$$}"

    info "Writing PID to #{pid_file}..."
    write_pid!
    handle_signals!
    info "Done."

    info "Starting the MTPSExample server..."

    info "Running Serve Loop..."
    @server.serve {
      info "Serve Callback Called. Enabling HAProxy..."
      enable_haproxy!
    }

    info "Done?"
  end

  def handle_signals!
    %w{INT TERM USR1}.each do |sig|
      ::Signal.trap(sig) {
        info "received signal #{sig}. Stopping..."

        # Tell HAProxy to stop sending traffic.
        disable_haproxy!

        info "Locking Mutex..."
        # Lock the Mutex, so the threads eventually die.
        mutex.lock

        # Give them 60 seconds to seppuku.
        Thread.new do
          info "Sleeping for 60-seconds, before hard exit."
          sleep(60)

          info "!! Done sleeping..."
          info "!! Begin hard exit... Deleting PID..."
          delete_pid!

          info "!! Hard Exiting."
          exit!
        end

        info "Stopping threads."
        # Exit early if they end before those 60-seconds. This is how it *should* happen.
        @server.stop_threads

        info "Deleting PID..."
        delete_pid!

        info "Exiting..."
        # Bye.
        exit!
      }
    end
  end

  def enable_haproxy!
    shell_command = %{echo "enable server mtps/#{name}" | socat unix-connect:/tmp/proxystats stdio}
    response = `#{shell_command}`
    return(true) if response == "\n"
    raise RuntimeError, "Failed to enable HAProxy. Received the message #{response}"
  end

  def disable_haproxy!
    shell_command = %{echo "disable server mtps/#{name}" | socat unix-connect:/tmp/proxystats stdio}
    `#{shell_command}` == "\n"
  end

  def pid_file
    @pid_file ||= begin
      pid  = ENV['PID_PATH'] || '/var/run/mtps_example'
      pid << "/mtps_example.pid"
    end
  end

  extend self
end
