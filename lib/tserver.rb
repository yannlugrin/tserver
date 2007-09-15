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

require "socket"
require "thread"
require 'thwait'
require 'monitor'

# Show README[link://files/README.html] for more information and exemple.
class TServer
	# Return or change the status (value can be set at 'true' or 'false').
	attr_accessor :verbose, :debug

	# Return current value of the option.
	attr_reader :port, :host, :max_connection, :min_listener

	DEFAULT_OPTIONS = {
		:port => 10001,
		:host => '127.0.0.1',
		:max_connection => 4,
		:min_listener => 1,
		:verbose => false,
		:debug => false,
		:stdlog => $stderr }

	# Initialize a new server (use start to run the server).
	#
  # Options are:
	# * <tt>:port</tt>  - Port which the server listen on (default: 10001).
	# * <tt>:host</tt>  - IP which the server listen on (default: 127.0.0.1).
	# * <tt>:max_connection</tt>  - Maximum number of simultaneous connection to server (default: 4, minimum: 1).
	# * <tt>:min_listener</tt>  - Minimum number of listener thread (default: 1, minimum: 0).
	# * <tt>:verbose</tt>  - Set at true to enable logging (default: false). Verbose mode can slow down the server.
	# * <tt>:debug</tt>  - Set at true to enable debuging (default: false).
	# * <tt>:stdlog</tt>  - IO for log and error output (default: $stderr).
	def initialize(options = {})
		options = DEFAULT_OPTIONS.merge(options)

		@port = options[:port]
		@host = options[:host]

		@max_connection = options[:max_connection] < 1 ? 1 : options[:max_connection]
		@min_listener = options[:min_listener] < 0 ? 0 : (options[:min_listener] > @max_connection ? @max_connection : options[:min_listener])

		@stdlog = options[:stdlog]
		@verbose = options[:verbose]
		@debug = options[:debug]

		@tcp_server = nil
		@tcp_server_thread = nil
		@connections = Queue.new

		@listener = []
		@listener.extend(MonitorMixin)
		@listener_cond = @listener.new_cond

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
				log("server:#{Thread.current} is started") if @verbose

				loop do
					@listener.synchronize do
						if @connections.num_waiting == 0 && @listener.size >= @max_connection
							log("server:#{Thread.current} wait on listener") if @verbose
							@listener_cond.wait
						end
					end

					log("server:#{Thread.current} wait on connection") if @verbose
					@connections << @tcp_server.accept rescue Thread.exit
					spawn_listener if !@connections.empty? && @connections.num_waiting == 0
				end
			ensure
				@tcp_server = nil
				@tcp_server_thread = nil
				@connections.clear
				@listener.synchronize { @listener.clear }

				log("server:#{Thread.current} is stopped") if @verbose
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
		@listener.synchronize { @listener.each {|l| l.exit} }
		@tcp_server_thread.exit rescue nil

		true
	end

	# Gracefull shutdown, the server can't accept new connection but wait current
	# connection before exit.
	def shutdown
		return true if @shutdown
		@shutdown = true
		log("server:#{Thread.current} shutdown") if @verbose

		@tcp_server.close rescue nil
		Thread.pass until @connections.empty?

		@listener.size.times { @connections << false }

		ThreadsWait.all_waits(*@listener)
		@tcp_server_thread.exit rescue nil

		true
	end

	# Return the number of spawned listener.
	def listener
		@listener.synchronize { @listener.size }
	end

	# Return the number of spawned listener waiting on new connection.
	def waiting_listener
		@connections.num_waiting
	end

	# Returns an array of arrays, where each subarray contains:
	# * address family: A string like "AF_INET" or "AF_INET6" if it is one of the commonly used families, the string "unknown:#" (where '#' is the address family number) if it is not one of the common ones. The strings map to the Socket::AF_* constants.
	# * port: The port number.
	# * name: Either the canonical name from looking the address up in the DNS, or the address in presentation format.
	# * address: The address in presentation format (a dotted decimal string for IPv4, a hex string for IPv6).
	def connections
		@listener.synchronize { @listener.collect{|l| l[:conn].peeraddr} }
	end

	# Return true if server running.
	def started?
		!stopped?
	end

	# Return true if server dont running.
	def stopped?
		@tcp_server_thread.nil?
	end

	protected

		# Override this method to implement a server, conn is a TCPSocket instance and
		# is closed when this method return.
		#
		# Exemple (send 'Hello world!' string to client):
		#	def process(conn)
		#		conn.puts 'Hello world!'
		#	end
		#
		# Use loop if you want persistant connection, if you wait on client input, use
		# Timeout#timeout with TCPSocket.read or test @shutdown with IO#select to exit
		# loop when server shutdown.
		#--
		# TODO: Exemple with "Timeout#timeout / TCPSocket.read" and  "@shutdown / IO#select"
		#++
		def process(conn)
		end

		# Send error backtrace to stdlog output.
		def error(e)
			if @stdlog
				@stdlog.puts '---'
				@stdlog.puts "#{e.class.to_s}: #{e.to_s}"
				@stdlog.puts e.backtrace.join("\n")
				@stdlog.puts '---'
			end
  	end

		# Send message to stdlog output.
		def log(message)
			if @stdlog
				@stdlog.puts("[#{Time.now}] #{self.class.to_s} #{@host}:#{@port} %s" % message)
				@stdlog.flush
			end
  	end

	private

		def spawn_listener #:nodoc:
			listener = Thread.new do
				begin
					log("listener:#{Thread.current} is spawned") if @verbose
					loop do
						begin
							log("listener:#{Thread.current} wait on connection") if @verbose
							conn = Thread.current[:conn] = (@connections.empty? && (@shutdown || @connections.num_waiting >= @min_listener)) ? Thread.exit : @connections.pop

							if conn.is_a?(TCPSocket)
								addr = conn.peeraddr if @verbose
								log("client:#{addr[1]} #{addr[2]}<#{addr[3]}> is connected to listener:#{Thread.current}") if @verbose

								process(conn)

								log("client:#{addr[1]} #{addr[2]}<#{addr[3]}> is disconnected from listener:#{Thread.current}") if @verbose
							end
						rescue => e
							log("client:#{addr[1]} #{addr[2]}<#{addr[3]}> make an error and is disconnected from listener:#{Thread.current}") if @verbose
							error(e) if @debug
						ensure
							conn.close rescue nil
							Thread.current[:conn] = nil
						end

						@listener.synchronize { @listener_cond.signal }
					end
				ensure
					@listener.synchronize { @listener.delete(Thread.current) }
					log("listener:#{Thread.current} is terminated") if @verbose
				end
			end

			@listener.synchronize { @listener << listener }
		end
end