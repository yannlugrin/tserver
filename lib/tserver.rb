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

# Show README[link://files/README.html] for implementation example or read
# Listener#process documentation.
class TServer

	# Show README[link://files/README.html] for implementation example.
	class Listener

		# Return current TCPSocket or nil.
		attr_reader :connection

		# Server logger instance (default level: Logger::WARN, default output: stderr).
		attr_reader :logger

		# Pptions hash is passed to init method.
		def initialize(server, listeners, listener_cond, connections, options = {}) #:nodoc:
			@server = server
			@logger = server.logger

			@listeners = listeners
			@listener_cond = listener_cond
			@connections = connections

			@terminate = false
			@connection = nil

			init(options)

			@thread = Thread.new do
				begin
					listener_spawned
					loop do
						begin
							listener_waiting_connection
							@connection = (@connections.empty? && (terminated? || @connections.num_waiting >= @server.min_listener)) ? exit : @connections.pop

							if @connection.is_a?(TCPSocket)
								connection_established
								process
								connection_normally_closed
							else
								exit
							end
						rescue => e
							connection_not_normally_closed(e)
						ensure
							close_connection
						end

						@listeners.synchronize { @listener_cond.signal }
					end
				ensure
					@listeners.synchronize { @listeners.delete(self) }
					listener_terminated
				end
			end
		end

		# Override this method to implement configuration of listener, options is
		# value of 'listener_options' key from TServer#new, TServer#start or
		# TServer#reload methods.
		#
		# List of existing instance variable (do not override): @connection, @connections,
		# @connection_addr, @listeners, @listener_cond, @logger, @server, @terminate, @thread.
		def init(options = {})
		end

		# Exit listener imediatly.
		def exit
			@thread.exit
		end

		# Mark listener to terminate processing of current connection.
		#
		# TODO: exit listener if don't have active connection (in thread exclusive block)
		def terminate
			@terminate = true
		end

		# Return array with information for current thread connection:
		# * address family: A string like "AF_INET" or "AF_INET6" if it is one of the commonly used families, the string "unknown:#" (where '#' is the address family number) if it is not one of the common ones. The strings map to the Socket::AF_* constants.
		# * port: The port number.
		# * name: Either the canonical name from looking the address up in the DNS, or the address in presentation format.
		# * address: The address in presentation format (a dotted decimal string for IPv4, a hex string for IPv6).
		def connection_addr
			@connection_addr ||= @connection.nil? ? [nil] * 4 : @connection.peeraddr
		end

		protected

			# Override this method to implement a server, conn is a TCPSocket instance and
			# is closed when this method return. Attribute 'connection' is available.
			#
			# Example (send 'Hello world!' string to client):
			#	def process
			#	  connection.puts 'Hello world!'
			#	end
			#
			# For persistant connection, use loop and Timeout.timeout or Tserver.terminated?
			# to break (and terminate listener) when server shutdown or reload. If server stop,
			# listener is killed but begin/ensure can be used to terminate current process.
			def process
			end

			# Callback (call when listener is spawned).
			def listener_spawned
				@logger.info do
					"listener:#{self} is spawned by server:#{@server} [#{@server.host}:#{@server.port}]"
				end
			end

			# Callback (call when listener exit).
			def listener_terminated
				@logger.info do
					"listener:#{self} is terminated"
				end
			end

			# Callback (call when listener wait connection - free listener).
			def listener_waiting_connection
				@logger.info do
					"listener:#{self} wait on connection from server:#{@server} [#{@server.host}:#{@server.port}]"
				end
			end

			# Callback (call when a connection is established with listener).
			def connection_established
				@logger.info do
					"client:#{connection_addr[1]} #{connection_addr[2]}<#{connection_addr[3]}> is connected to listener:#{self}"
				 end
			end

			# Callback (call when the connection with listener close normally).
			def connection_normally_closed
				@logger.info do
					"client:#{connection_addr[1]} #{connection_addr[2]}<#{connection_addr[3]}> is disconnected from listener:#{self}"
				 end
			end

			# Callback (call when the connection with listener do not close normally,
			# reveive 'error' instance from rescue).
			def connection_not_normally_closed(error)
				@logger.warn do
					"client:#{connection_addr[1]} #{connection_addr[2]}<#{connection_addr[3]}> make an error and is disconnected from listener:#{self}"
				end

				@logger.debug do
					"#{error.class.to_s}: #{error.to_s}\n" +
					error.backtrace.join("\n")
				end
			end

			# Close current connection.
			def close_connection
				@connection.close rescue nil
				@connection = nil
				@connection_addr = nil
			end

			# Return true if server ask listener to terminate (when shutdown or reload).
			def terminated?
				@terminate == true
			end

	end

	# Server port (default: 10001).
	attr_reader :port

	# Server host (default: 127.0.0.1).
	attr_reader :host

	# Maximum simultaneous connection can be established with server (default: 4, minimum: 1).
	attr_reader :max_connection

	# Minimum listener permanently spawned (default: 1, minimum: 0).
	attr_reader :min_listener

	# Server logger instance (default level: Logger::WARN, default output: stderr).
	attr_reader :logger

	DEFAULT_OPTIONS = {
		:port => 10001,
		:host => '127.0.0.1',
		:max_connection => 4,
		:min_listener => 1,
		:log_level => Logger::WARN,
		:stdlog => $stderr,
		:listener_options => {} }

	# Initialize a new server (use start to run the server).
	#
	# Options are:
	# * <tt>:port</tt>  - Port which the server listen on (default: 10001).
	# * <tt>:host</tt>  - IP which the server listen on (default: 127.0.0.1).
	# * <tt>:max_connection</tt>  - Maximum number of simultaneous connection to server (default: 4, minimum: 1).
	# * <tt>:min_listener</tt>  - Minimum number of listener thread (default: 1, minimum: 0).
	# * <tt>:log_level</tt>  - Use Logger constants DEBUG, INFO, WARN, ERROR or FATAL to set log level (default: Logger::WARN).
	# * <tt>:stdlog</tt>  - IO or filepath for log output (default: $stderr).
	# * <tt>:listener_options</tt>  - Hash of options for Listener#init (default: empty hash).
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

		@listeners = []
		@listeners.extend(MonitorMixin)
		@listener_cond = @listeners.new_cond

		@listener_options = options[:listener_options]

		@shutdown = false
	end

	# Start the server, if joined is set at true this method return only when
	# the server is stopped (you can also use join method after start). listener_options
	# is a Hash of options for Listener#init.
	def start(listener_options = {}, joined = false)
		@shutdown = false
		@tcp_server = TCPServer.new(@host, @port)

		@listener_options = listener_options
		@listeners.synchronize do
			@min_listener.times do
				@listeners << self.class::Listener.new(self, @listeners, @listener_cond, @connections, @listener_options)
			end
		end
		Thread.pass while @connections.num_waiting < @min_listener

		@tcp_server_thread = Thread.new do
			begin
				server_started

				loop do
					@listeners.synchronize do
						if @connections.num_waiting == 0 && @listeners.size >= @max_connection
							server_waiting_listener
							@listener_cond.wait
						end
					end

					server_waiting_connection
					@connections << @tcp_server.accept rescue Thread.exit

					@listeners.synchronize do
						@listeners << self.class::Listener.new(self, @listeners, @listener_cond, @connections, @listener_options) if !@connections.empty? && @connections.num_waiting == 0
					end
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
		@listeners.synchronize { @listeners.each {|l| l.exit} }
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

		@listeners.synchronize  do
			@listeners.each do |listener|
				listener.terminate
				@connections << false
			end
		end

		ThreadsWait.all_waits(*@listeners)
		@tcp_server_thread.exit rescue nil
		@tcp_server_thread = nil

		true
	end

	# Reload the server
	# * Spawn new listeners.
	# * Terminate existing listeners when current connection is closed.
	# listener_options is a Hash of options for Listener#init.
	def reload(listener_options = {})
		return if stopped?

		listeners_to_exit = nil
		@listeners.synchronize do
			listeners_to_exit = @listeners.dup
			@listeners.clear
			@listener_options = listener_options
		end

		listeners_to_exit.each do |listener|
			listener.terminate
		end

		@listeners.synchronize do
			@listeners << self.class::Listener.new(self, @listeners, @listener_cond, @connections, @listener_options) while @listeners.size < @min_listener
		end

		true
	end

	# Return the number of spawned listener.
	def listeners
		@listeners.synchronize { @listeners.size }
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
		@listeners.synchronize { @listeners.collect{|l| l.connection.nil? ? nil : l.connection.peeraddr } }.compact
	end

	# Return true if server running.
	def started?
		@listeners.synchronize { !@tcp_server_thread.nil? || @listeners.size > 0 }
	end

	# Return true if server dont running.
	def stopped?
		!started?
	end

	protected

		# Callback (call when server is started).
		def server_started
			@logger.info do
				"server:#{self} [#{@host}:#{@port}] is started"
			end
		end

		# Callback (call when server is stopped).
		def server_stopped
			@logger.info do
				"server:#{self} [#{@host}:#{@port}] is stopped"
			end
		end

		# Callback (call when server shutdown, before is stopped).
		def server_shutdown
			@logger.info do
				"server:#{self} [#{@host}:#{@port}] shutdown"
			end
		end

		# Callback (call when server wait new connection).
		def server_waiting_connection
			@logger.info do
				"server:#{self} [#{@host}:#{@port}] wait on connection"
			end
		end

		# Callback (call when server wait free listener, don't accept new connection).
		def server_waiting_listener
			@logger.info do
				"server:#{self} [#{@host}:#{@port}] wait on listener"
			end
		end
end