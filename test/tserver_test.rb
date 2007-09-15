require 'test/unit'
require 'timeout'
require 'thread'

require File.expand_path(File.dirname(__FILE__) + '/../lib/tserver')

SERVER_READER = Queue.new

# The test server can send received data to an IO
class TestServer < TServer
	def initialize(options= {})
		super(options)
	end

	protected

		# Send received data on IO and return the data to client
		def process(conn)
			loop do
				SERVER_READER << string = conn.readline.chomp
				conn.puts string
			end
		end
end

# The test client can send and receive data to a server
class TestClient
	def initialize(host, port)
		@host = host
		@port = port

		@socket = nil
	end

	def connect
		@socket = TCPSocket.new(@host, @port)
	end

	def close
		@socket.close if @socket
	end

	def send(string)
		@socket.puts string
		Thread.pass
	end

	def receive
		@socket.readline.chomp
	end
end

class TServerTest < Test::Unit::TestCase
	def setup
		SERVER_READER.clear

		@server = TestServer.new
		@client = TestClient.new(@server.host, @server.port)
	end

	def teardown
		@client.close rescue nil

		@server.stop rescue nil
		@server.join rescue nil # join the server to ensure is stopped before start the next test
	end

	def test_should_can_create_with_default_values
		server = TServer.new

		assert_equal 10001, server.port
		assert_equal '127.0.0.1', server.host

		assert_equal 4, server.max_connection
		assert_equal 1, server.min_listener

		assert_equal false, server.verbose
		assert_equal false, server.debug

		assert_equal $stderr, server.instance_variable_get(:@stdlog)
	end

	def test_should_can_create_with_custom_values
		# Set all options
		server = TServer.new(:port => 10002, :host => '192.168.1.1', :max_connection => 10, :min_listener => 2, :verbose => true, :debug => true, :stdlog => $stdout)

		assert_equal 10002, server.port
		assert_equal '192.168.1.1', server.host

		assert_equal 10, server.max_connection
		assert_equal 2, server.min_listener

		assert_equal true, server.verbose
		assert_equal true, server.debug

		assert_equal $stdout, server.instance_variable_get(:@stdlog)
	end

	def test_should_dont_have_more_min_listener_that_of_max_connection
		server = TServer.new(:max_connection => 5, :min_listener => 6)

		assert_equal 5, server.max_connection
		assert_equal 5, server.min_listener
	end

	def test_should_dont_have_minimum_max_connection_and_min_listener
		server = TServer.new(:max_connection => 0, :min_listener => -1)

		assert_equal 1, server.max_connection
		assert_equal 0, server.min_listener
	end

	def test_should_change_verbose_status
		server = TServer.new
		assert_equal false, server.verbose

		server.verbose = true
		assert_equal true, server.verbose
	end

	def test_should_change_debug_status
		server = TServer.new
		assert_equal false, server.debug

		server.debug = true
		assert_equal true, server.debug
	end

	def test_should_be_started
		# Start a server
		assert_nothing_raised do
			Timeout.timeout(2) do
				@server.start
			end
		end
		assert @server.started?
		assert !@server.stopped?

		# Wait on listener
		assert_nothing_raised 'Listener isn\'t spawned' do
			Timeout.timeout(2) do
				sleep 0.1 while @server.waiting_listener < @server.min_listener
			end
		end

		# Listener is spawned
		assert_equal @server.min_listener, @server.listener
		assert_equal @server.min_listener, @server.waiting_listener
	end

	def test_should_be_stopped
		# Stop a non started server
		assert_nothing_raised do
			Timeout.timeout(2) do
				assert @server.stop
			end
		end

		# Start the server
		assert_nothing_raised do
			Timeout.timeout(2) do
				@server.start
			end
		end

		# Stop the server
		assert_nothing_raised do
			Timeout.timeout(2) do
				assert @server.stop
			end
		end

		# The server is stopped and dont accept connection
		assert !@server.started?
		assert @server.stopped?
		assert_raise(RUBY_PLATFORM =~ /win32/ ? Errno::EBADF : Errno::ECONNREFUSED) do
			@client.connect
		end
	end

	def test_should_be_stopped_with_established_connection
		# Start the server and a client
		assert_nothing_raised do
			@server.start
			@client.connect
		end

		# Shutdown the server
		assert_nothing_raised do
			Timeout.timeout(2) do
				assert @server.stop
			end
		end

		# Wait on listener
		assert_nothing_raised 'Listener isn\'t terminated' do
			Timeout.timeout(2) do
				sleep 0.1 while @server.listener > 0
			end
		end

		# The server is stopped and dont accept connection
		assert !@server.started?
		assert @server.stopped?
		assert_raise(RUBY_PLATFORM =~ /win32/ ? Errno::EBADF : Errno::ECONNREFUSED) do
			@client.connect
		end
	end

	def test_should_be_shutdown
		# Shutdown a non started server
		assert_nothing_raised do
			Timeout.timeout(2) do
				assert @server.shutdown
			end
		end

		# Start the server
		assert_nothing_raised 'Server isn\'t started' do
			Timeout.timeout(2) do
				@server.start
			end
		end

		# Shutdown the server
		assert_nothing_raised 'Server isn\'t shutdowned' do
			Timeout.timeout(2) do
				assert @server.shutdown
			end
		end

		# The server is stopped and dont accept connection
		assert !@server.started?
		assert @server.stopped?
		assert_raise(RUBY_PLATFORM =~ /win32/ ? Errno::EBADF : Errno::ECONNREFUSED) do
			@client.connect
		end

		# Shutdown a shutdowned server
		assert_nothing_raised 'Server isn\'t shutdowned' do
			Timeout.timeout(2) do
				assert @server.shutdown
			end
		end
	end

	def test_should_be_shutdown_with_established_connection
		# Start the server and a client
		assert_nothing_raised 'Server and client can\'t start' do
			Timeout.timeout(2) do
				@server.start
				@client.connect
			end
		end

		# Wait on listener
		assert_nothing_raised 'Connection isn\'t established' do
			Timeout.timeout(2) do
				sleep 0.1 while @server.waiting_listener > 0
			end
		end

		# Shutdown the server
		shutdown_thread = nil
		shutdown_thread = Thread.new do
			assert_nothing_raised 'Server can\'t shutdown' do
				Timeout.timeout(2) do
					assert @server.shutdown
				end
			end
		end

		# The server isn't stopped because a client is connected'
		assert @server.started?, 'Server isn\'t started'
		assert !@server.stopped?, 'Server is stopped'

		# The client work
		assert_nothing_raised 'Client can\'t communicate' do
			Timeout.timeout(2) do
				@client.send 'test string'
				assert_equal 'test string', SERVER_READER.pop.chomp
				assert_equal 'test string', @client.receive
			end
		end

		# Close the client
		assert_nothing_raised 'Client can\'t close' do
			Timeout.timeout(2) do
				@client.close
			end
		end

		# Wait on listener
		assert_nothing_raised 'Listener isn\'t terminated' do
			Timeout.timeout(2) do
				sleep 0.1 while @server.listener > 0
			end
		end

		assert_nothing_raised 'Shutdown isn\'t terminated' do
			Timeout.timeout(2) do
				shutdown_thread.join
			end
		end

		# The server is stopped and dont accept connection
		assert !@server.started?
		assert @server.stopped?
		assert_raise(RUBY_PLATFORM =~ /win32/ ? Errno::EBADF : Errno::ECONNREFUSED) do
			@client.connect
		end
	end

	def test_should_be_receive_connection
		# Start the server and a client
		assert_nothing_raised do
			@server.start
			@client.connect
		end

		# Client can communicate with the server
		@client.send 'test string'
		assert_equal 'test string', SERVER_READER.pop.chomp
		assert_equal 'test string', @client.receive
	end

	def test_should_be_receive_multiple_connection
		# Create multiple clients
		@client_2 = TestClient.new(@server.host, @server.port)
		@client_3 = TestClient.new(@server.host, @server.port)
		@client_4 = TestClient.new(@server.host, @server.port)
		@client_5 = TestClient.new(@server.host, @server.port)

		# Start the server and a clients
		assert_nothing_raised 'Server and clients isn\'t started' do
			@server.start
			@client.connect
			@client_2.connect
			@client_3.connect
			@client_4.connect
			@client_5.connect
		end

		# Wait on listener (only 4 listerner for 5 client)
		assert_nothing_raised 'Listener isn\'t spawned' do
			Timeout.timeout(2) do
				sleep 0.1 while @server.listener < 4 || @server.waiting_listener > 0
			end
		end
		assert_equal 0, @server.waiting_listener
		assert_equal 4, @server.listener

		# All clients send data to server
		@client.send 'test string 1'
		@client_2.send 'test string 2'
		@client_3.send 'test string 3'
		@client_4.send 'test string 4'
		@client_5.send 'test string 5'

		# Server receive data from 4 clients (but the last client waiting)
		1.upto(4) do |i|
			assert_match(/test string [1-4]/, SERVER_READER.pop)
		end
		assert SERVER_READER.empty?

		# Close a client
		@client.close

		# Server can recerive data from last client
		assert_equal 'test string 5', SERVER_READER.pop

		# Close all clients [<client>, <number of listener after close>]
		[[@client_2, 4], [@client_3, 3], [@client_4, 2], [@client_5, 1]].each do |client, num_listener|
			client.close

			# Wait on listener (listener is terminated if num_listener waiting connection)
			assert_nothing_raised 'Listener isn\'t terminated' do
				Timeout.timeout(2) do
					sleep 0.1 while @server.listener > num_listener
				end

				Timeout.timeout(2) do
					sleep 0.1 while @server.waiting_listener < @server.min_listener
				end
			end
		end

		# min_listener waiting connection
		assert_equal @server.min_listener, @server.listener
		assert_equal @server.min_listener, @server.waiting_listener
	end

	def test_should_works_with_min_listener_at_0
		@server = TestServer.new(:min_listener => 0)

		# Start the server and a client
		assert_nothing_raised do
			@server.start
			@client.connect
		end

		# Client can communicate with the server
		@client.send 'test string'
		assert_nothing_raised 'Listener do not respond' do
			Timeout.timeout(2) do
				assert_equal 'test string', SERVER_READER.pop.chomp
				assert_equal 'test string', @client.receive
			end
		end

		# Close a client
		@client.close

		# Wait on listener
		assert_nothing_raised 'Listener isn\'t terminated' do
			Timeout.timeout(2) do
				sleep 0.1 while @server.listener > 0
			end
		end

		# min_listener
		assert_equal 0, @server.listener
		assert_equal 0, @server.waiting_listener
	end

	def test_should_have_connection_list
		# Start the server and a client
		assert_nothing_raised do
			@server.start
			@client.connect
		end

		# Wait on connection
		assert_nothing_raised 'Connection isn\'t established' do
			Timeout.timeout(2) do
				sleep 0.1 while @server.connections.first == nil
			end
		end

		assert_equal 'AF_INET', @server.connections.first[0]
		assert_match(/^\d+$/, @server.connections.first[1].to_s)
		assert_match(/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/, @server.connections.first[3])
	end
end
