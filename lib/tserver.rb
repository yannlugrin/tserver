#--
# The MIT License
#
# Copyright (c) 2007 Yann Lugrin
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#++

require 'socket'
require 'thread'
require 'thwait'
require 'monitor'
require 'logger'

# Show README[link://files/README.html] for implementation example.
class TServer

	# Server port (default: 10001).
	attr_reader :port

	# Server host (default: 127.0.0.1).
	attr_reader :host

	# Maximum simultaneous connection can be established with server (default: 4, minimum: 1).
	attr_reader :max_connection

	# Minimum listener permanently spawned (default: 1, minimum: 0).
	attr_reader :min_listener

	# Server logger instance (default level: Logger:WARN, default output: stderr).
	attr_reader :logger

	DEFAULT_OPTIONS = {
		:port => 10001,
		:host => '127.0.0.1',
		:max_connection => 4,
		:min_listener => 1,
		:log_level => Logger::WARN,
		:stdlog => $stderr }

	# Initialize a new server (use start to run the server).
	#
	# Options are:
	# * <tt>:port</tt>  - Port which the server listen on (default: 10001).
	# * <tt>:host</tt>  - IP which the server listen on (default: 127.0.0.1).
	# * <tt>:max_connection</tt>  - Maximum number of simultaneous connection to server (default: 4, minimum: 1).
	# * <tt>:min_listener</tt>  - Minimum number of listener thread (default: 1, minimum: 0).
	# * <tt>:log_level</tt>  - Use Logger constants DEBUG, INFO, WARN, ERROR or FATAL to set log level (default: Logger:WARN).
	# * <tt>:stdlog</tt>  - IO or filepath for log output (default: $stderr).
	def initialize(options = {})
		options = DEFAULT_OPTIONS.merge(options)

		@port = options[:port]
		@host = options[:host]

		@max_connection = options[:max_connection] < 1 ? 1 : options[:max_connection]
		@min_listener = options[:min_listener] < 0 ? 0 : (options[:min_listener] > @max_connection ? @max_connection : options[:min_listener])

		@logger = Logger.new(options[:stdlog])
		@logger.level = options[:log_level]

		@tcp_server = nil
		@tcp_server_thread = nil
		@connections = Queue.new

		@listener_threads = []
		@listener_threads.extend(MonitorMixin)
		@listener_cond = @listener_threads.new_cond

		@shutdown = false
	end

	# Start the server, if joined is set at true this method return only when
	# the server is stopped (you can also use join method after start)
	def start(joined = false)
		@shutdown = false
		@tcp_server = TCPServer.new(@host, @port)

		@min_listener.times { spawn_listener }
		Thread.pass while @connections.num_waiting < @min_listener

		@tcp_server_thread = Thread.new do
			begin
				server_started

				loop do
					@listener_threads.synchronize do
						if @connections.num_waiting == 0 && @listener_threads.size >= @max_connection
							server_waiting_listener
							@listener_cond.wait
						end
					end

					server_waiting_connection
					@connections << @tcp_server.accept rescue Thread.exit
					spawn_listener if !@connections.empty? && @connections.num_waiting == 0
				end
			ensure
				@tcp_server = nil
				@tcp_server_thread = nil

				server_stopped
			end
		end

		join if joined
		true
	end

	# Join the main thread of the server and return only when the server is stopped.
	def join
		@tcp_server_thread.join if @tcp_server_thread
	end

	# Stop imediatly the server (all established connection is interrupted).
	def stop
		@tcp_server.close rescue nil
		@listener_threads.synchronize { @listener_threads.each {|l| l.exit} }
		@tcp_server_thread.exit rescue nil

		true
	end

	# Gracefull shutdown, the server can't accept new connection but wait current
	# connection before exit.
	def shutdown
		return if stopped?
		server_shutdown

		@tcp_server.close rescue nil
		Thread.pass until @connections.empty?

		@listener_threads.synchronize  do
			@listener_threads.each do |listener|
				listener[:terminate] = true
				@connections << false
			end
		end

		ThreadsWait.all_waits(*@listener_threads)
		@tcp_server_thread.exit rescue nil
		@tcp_server_thread = nil

		true
	end

	# Reload the server
	# * Spawn new listeners.
	# * Terminate existing listeners when current connection is closed.
	def reload
		return if stopped?

		listeners_to_exit = nil
		@listener_threads.synchronize do
			listeners_to_exit = @listener_threads.dup
			@listener_threads.clear
		end

		listeners_to_exit.each do |listener|
			listener[:connection].nil? ? listener.terminate : listener[:terminate] = true
		end

		@listener_threads.synchronize do
			spawn_listener while @listener_threads.size < @min_listener
		end

		true
	end

	# Return the number of spawned listener.
	def listeners
		@listener_threads.synchronize { @listener_threads.size }
	end

	# Return the number of spawned listener waiting on new connection.
	def waiting_listeners
		@connections.num_waiting
	end

	# Returns an array of arrays, where each subarray contains:
	# * address family: A string like "AF_INET" or "AF_INET6" if it is one of the commonly used families, the string "unknown:#" (where '#' is the address family number) if it is not one of the common ones. The strings map to the Socket::AF_* constants.
	# * port: The port number.
	# * name: Either the canonical name from looking the address up in the DNS, or the address in presentation format.
	# * address: The address in presentation format (a dotted decimal string for IPv4, a hex string for IPv6).
	def connections
		@listener_threads.synchronize { @listener_threads.collect{|l| l[:connection].nil? ? nil : l[:connection].peeraddr } }.compact
	end

	# Return true if server running.
	def started?
		@listener_threads.synchronize { !@tcp_server_thread.nil? || @listener_threads.size > 0 }
	end

	# Return true if server dont running.
	def stopped?
		!started?
	end

	protected

		# Override this method to implement a server, conn is a TCPSocket instance and
		# is closed when this method return. Attribute 'connection' is available.
		#
		# Example (send 'Hello world!' string to client):
		#	def process
		#		connection.puts 'Hello world!'
		#	end
		#
		# For persistant connection, use loop and Timeout.timeout or Tserver.terminate_listener?
		# to break (and terminate listener) when server shutdown or reload. If server stop,
		# listener is killed but begin/ensure can be used to terminate current process.
		def process
		end

		# Callback (call when server is started)
		def server_started
			@logger.info do
				"server:#{Thread.current} [#{@host}:#{@port}] is started"
			end
		end

		# Callback (call when server is stopped)
		def server_stopped
			@logger.info do
				"server:#{Thread.current} [#{@host}:#{@port}] is stopped"
			end
		end

		# Callback (call when server shutdown, before is stopped)
		def server_shutdown
			@logger.info do
				"server:#{Thread.current} [#{@host}:#{@port}] shutdown"
			end
		end

		# Callback (call when server wait new connection)
		def server_waiting_connection
			@logger.info do
				"server:#{Thread.current} [#{@host}:#{@port}] wait on connection"
			end
		end

		# Callback (call when server wait free listener, don't accept new connection)
		def server_waiting_listener
			@logger.info do
				"server:#{Thread.current} [#{@host}:#{@port}] wait on listener"
			end
		end

		# Callback (call when listener is spawned)
		def listener_spawned
			@logger.info do
				"listener:#{Thread.current} is spawned by server:#{Thread.current} [#{@host}:#{@port}]"
			end
		end

		# Callback (call when listener exit)
		def listener_terminated
			@logger.info do
				"listener:#{Thread.current} is terminated"
			end
		end

		# Callback (call when listener wait connection - free listener)
		def listener_waiting_connection
			@logger.info do
				"listener:#{Thread.current} wait on connection from server:#{Thread.current} [#{@host}:#{@port}]"
			end
		end

		# Callback (call when a connection is established with listener)
		def connection_established
			@logger.info do
				"client:#{connection_addr[1]} #{connection_addr[2]}<#{connection_addr[3]}> is connected to listener:#{Thread.current}"
			 end
		end

		# Callback (call when the connection with listener close normally)
		def connection_normally_closed
			@logger.info do
				"client:#{connection_addr[1]} #{connection_addr[2]}<#{connection_addr[3]}> is disconnected from listener:#{Thread.current}"
			 end
		end

		# Callback (call when the connection with listener do not close normally,
		# reveive 'error' instance from rescue)
		def connection_not_normally_closed(error)
			@logger.warn do
				"client:#{connection_addr[1]} #{connection_addr[2]}<#{connection_addr[3]}> make an error and is disconnected from listener:#{Thread.current}"
			end

			@logger.debug do
				"#{error.class.to_s}: #{error.to_s}\n" +
				error.backtrace.join("\n")
			end
		end

	private

		def spawn_listener #:nodoc:
			listener_thread = Thread.new do
				begin
					listener_spawned
					loop do
						begin
							listener_waiting_connection
							self.connection = (@connections.empty? && (terminate_listener? || @connections.num_waiting >= @min_listener)) ? Thread.exit : @connections.pop

							if connection.is_a?(TCPSocket)
								connection_established
								process
								connection_normally_closed
							else
								Thread.exit
							end
						rescue => e
							connection_not_normally_closed(e)
						ensure
							connection.close rescue nil
							self.connection = nil
						end

						@listener_threads.synchronize { @listener_cond.signal }
					end
				ensure
					@listener_threads.synchronize { @listener_threads.delete(Thread.current) }
					listener_terminated
				end
			end

			@listener_threads.synchronize { @listener_threads << listener_thread }
		end

		# Set connection for current Thread
		def connection=(conn) #:nodoc:
			Thread.current[:connection] = conn
		end

		# Return connection of current listener thread (or nil)
		def connection
			Thread.current[:connection]
		end

		# Return array with information for current thread connection:
		# * address family: A string like "AF_INET" or "AF_INET6" if it is one of the commonly used families, the string "unknown:#" (where '#' is the address family number) if it is not one of the common ones. The strings map to the Socket::AF_* constants.
		# * port: The port number.
		# * name: Either the canonical name from looking the address up in the DNS, or the address in presentation format.
		# * address: The address in presentation format (a dotted decimal string for IPv4, a hex string for IPv6).
		def connection_addr
			Thread.current[:connection_addr] ||= (Thread.current[:connection].nil? ? [nil] * 4 : Thread.current[:connection].peeraddr)
		end

		# Return true if server ask listener to exit (when shutdown or reload)
		def terminate_listener?
			Thread.current[:terminate] == true
		end
end