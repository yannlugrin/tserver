require 'test/unit'
require 'timeout'
require 'thread'

require File.expand_path(File.dirname(__FILE__) + '/../lib/tserver')

TEST_LOG = 'test.log'
SERVER_READER = Queue.new

# The test server can send received data to an IO
class TestServer < TServer

  class Listener < TServer::Listener
    protected

    # Send received data on IO and return the data to client
    def process
      loop do
        SERVER_READER << string = @connection.readline.chomp
        @connection.puts string
      end
    end
  end

  def initialize(options= {})
    super(options)
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
    Thread.pass
  end

  def close
    @socket.close if @socket
    Thread.pass
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

    @server = TestServer.new(:log_level => Logger::DEBUG, :stdlog => TEST_LOG)
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

    assert_kind_of Logger, server.logger
    assert_equal Logger::WARN, server.logger.level
  end

  def test_should_can_create_with_custom_values
    # Set all options
    server = TServer.new(:port => 10002, :host => '192.168.1.1', :max_connection => 10, :min_listener => 2, :log_level => Logger::DEBUG)

    assert_equal 10002, server.port
    assert_equal '192.168.1.1', server.host

    assert_equal 10, server.max_connection
    assert_equal 2, server.min_listener

    assert_kind_of Logger, server.logger
    assert_equal Logger::DEBUG, server.logger.level
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

  def test_should_be_started
    # Start a server
    assert_not_timeout('Server do not start') { @server.start }
    assert @server.started?
    assert !@server.stopped?

    # Listener is spawned
    assert_equal @server.min_listener, @server.listeners
    assert_equal @server.min_listener, @server.waiting_listeners
  end

  def test_should_be_stopped
    # Stop a non started server
    assert_not_timeout('Server do not stop') { @server.stop }

    # Start the server
    assert_not_timeout('Server do not start') { @server.start }

    # Stop the server
    assert_not_timeout('Server do not stop'){ @server.stop }

    # The server is stopped and dont accept connection
    assert !@server.started?
    assert @server.stopped?
    assert_raise(RUBY_PLATFORM =~ /win32/ ? Errno::EBADF : Errno::ECONNREFUSED) do
      @client.connect
    end
  end

  def test_should_be_stopped_with_established_connection
    # Start the server and a client
    assert_not_timeout('Server do not start') { @server.start }
    assert_not_timeout('Client do not connect') { @client.connect }

    # Shutdown the server
    assert_not_timeout('Server do not stop') { @server.stop }

    # The server is stopped and dont accept connection
    assert !@server.started?
    assert @server.stopped?
    assert_raise(RUBY_PLATFORM =~ /win32/ ? Errno::EBADF : Errno::ECONNREFUSED) do
      @client.connect
    end
  end

  def test_should_be_shutdown
    # Shutdown a non started server
    assert_not_timeout('Server do not shutdown') { @server.shutdown }

    # Start the server
    assert_not_timeout('Server do not start') { @server.start }

    # Shutdown the server
    assert_not_timeout('Server do not shutdown') { @server.shutdown }

    # The server is stopped and dont accept connection
    assert !@server.started?
    assert @server.stopped?
    assert_raise(RUBY_PLATFORM =~ /win32/ ? Errno::EBADF : Errno::ECONNREFUSED) do
      @client.connect
    end

    # Shutdown a shutdowned server
    assert_not_timeout('Server do not shutdown') { @server.shutdown }
  end

  def test_should_be_shutdown_with_established_connection
    # Start server and client
    assert_not_timeout('Server do not start') { @server.start }
    assert_not_timeout('Client do not connect') { @client.connect }
    wait_connections

    # Shutdown the server
    shutdown_thread = nil
    shutdown_thread = Thread.new do
      assert_not_timeout('Server do not shutdown') { @server.shutdown }
    end

    # The server isn't stopped because a connection is established
    assert @server.started?
    assert !@server.stopped?

    # The client can communicate with server
    assert_not_timeout 'Client do not communicate with server' do
      @client.send 'test string'
      assert_equal 'test string', SERVER_READER.pop.chomp
      assert_equal 'test string', @client.receive
    end

    # Close client
    assert_not_timeout('Client do not close connection') { @client.close }
    wait_listeners 0

    # Wait server shutdown
    assert_not_timeout('Server do not shutdown') { shutdown_thread.join }

    # The server is stopped and dont accept connection
    assert !@server.started?
    assert @server.stopped?
    assert_raise(RUBY_PLATFORM =~ /win32/ ? Errno::EBADF : Errno::ECONNREFUSED) do
      @client.connect
    end
  end

  def test_should_be_restart
    # Restart a non started server
    assert_not_timeout('Server do not restart') { @server.restart }

    # Do not spawn listeners!
    assert_equal 0, @server.instance_variable_get(:@listeners).size

    # Start the server
    assert_not_timeout('Server do not start') { @server.start }

    # The server is started and accept connection
    assert_not_timeout('Client do not connect') { @client.connect }
    wait_connections

    # Copy list of current listeners
    listeners_to_exit = @server.instance_variable_get(:@listeners).dup

    # Restart the server
    assert_not_timeout('Server do not reload') { @server.restart }

    # Old listener is exited
    wait_listeners 1
    assert_nil listeners_to_exit.first.thread
    assert_nil listeners_to_exit.first.connection

    # The client can't communicate with server
    assert_raise(RUBY_PLATFORM =~ /win32/ ? Errno::ECONNABORTED : Errno::EPIPE) do
      @client.send 'test string'
    end

    # The server is started and accept connection
    assert_not_timeout('Client do not connect') { @client.connect }

    # The client can communicate with server
    assert_not_timeout 'Client do not communicate with server' do
      @client.send 'test string'
      assert_equal 'test string', SERVER_READER.pop.chomp
      assert_equal 'test string', @client.receive
    end
  end

  def test_should_be_reload
    # Reload a non started server
    assert_not_timeout('Server do not reload') { @server.reload }

    # Do not spawn listeners!
    assert_equal 0, @server.instance_variable_get(:@listeners).size

    # Start the server
    assert_not_timeout('Server do not start') { @server.start }

    # The server is started and accept connection
    assert_not_timeout('Client do not connect') { @client.connect }
    wait_connections

    # Copy list of current listeners
    listeners_to_exit = @server.instance_variable_get(:@listeners).dup

    # Reload the server
    assert_not_timeout('Server do not reload') { @server.reload }

    # Old listener is not terminated (connection with a client is established)
    wait_listeners 1
    assert_not_equal listeners_to_exit.first, @server.instance_variable_get(:@listeners).first
    assert_not_equal listeners_to_exit.first.connection, @server.instance_variable_get(:@listeners).first.connection

    # The client can communicate with server
    assert_not_timeout 'Client do not communicate with server' do
      @client.send 'test string'
      assert_equal 'test string', SERVER_READER.pop.chomp
      assert_equal 'test string', @client.receive
    end

    # Close client
    assert_not_timeout('Client do not close connection') { @client.close }

    # Old listeners exit
    ThreadsWait.all_waits(*listeners_to_exit)

    # The server is started and accept connection
    assert_not_timeout('Client do not connect') { @client.connect }

    # The client can communicate with server
    assert_not_timeout 'Client do not communicate with server' do
      @client.send 'test string'
      assert_equal 'test string', SERVER_READER.pop.chomp
      assert_equal 'test string', @client.receive
    end
  end

  def test_should_be_receive_connection
    # Start server and client
    assert_not_timeout('Server do not start') { @server.start }
    assert_not_timeout('Client do not connect') { @client.connect }

    # Client can communicate with the server
    assert_not_timeout 'Client do not communicate with server' do
      @client.send 'test string'
      assert_equal 'test string', SERVER_READER.pop.chomp
      assert_equal 'test string', @client.receive
    end
  end

  def test_should_be_receive_multiple_connection
    # Create multiple clients
    @client_2 = TestClient.new(@server.host, @server.port)
    @client_3 = TestClient.new(@server.host, @server.port)
    @client_4 = TestClient.new(@server.host, @server.port)
    @client_5 = TestClient.new(@server.host, @server.port)

    # Start server and clients
    assert_not_timeout('Server do not start') { @server.start }
    assert_not_timeout('Client do not connect') { @client.connect }
    assert_not_timeout('Client do not connect') { @client_2.connect }
    assert_not_timeout('Client do not connect') { @client_3.connect }
    assert_not_timeout('Client do not connect') { @client_4.connect }
    assert_not_timeout('Client do not connect') { @client_5.connect }
    wait_listeners 4

    # Only 4 listerner for 5 client
    assert_equal 0, @server.waiting_listeners
    assert_equal 4, @server.listeners

    # All clients send data to server
    assert_not_timeout('Client do not communicate with server') { @client.send 'test string 1' }
    assert_not_timeout('Client do not communicate with server') { @client_2.send 'test string 2' }
    assert_not_timeout('Client do not communicate with server') { @client_3.send 'test string 3' }
    assert_not_timeout('Client do not communicate with server') { @client_4.send 'test string 4' }
    assert_not_timeout('Client do not communicate with server') { @client_5.send 'test string 5' }

    # Server receive data from 4 clients (but the last client waiting)
    1.upto(4) do |i|
      assert_not_timeout 'Do not receive data from client' do
        assert_match(/test string [1-4]/, SERVER_READER.pop)
      end
    end
    assert SERVER_READER.empty?, 'Server receive data from client 5'

    # Close client
    assert_not_timeout('Client do not close connection') { @client.close }


    # Server can recerive data from last client
    assert_not_timeout 'Do not receive data from client' do
      assert_equal 'test string 5', SERVER_READER.pop
    end

    # Close all clients [<client>, <number of listener after close>]
    [@client_2, @client_3, @client_4, @client_5].each do |client|
      assert_not_timeout('Client do not close connection') { client.close }
    end
    wait_listeners

    # min_listener waiting connection
    assert_equal @server.min_listener, @server.listeners
    assert_equal @server.min_listener, @server.waiting_listeners
  end

  def test_should_be_receive_connection_with_log_level_to_debug
    @server.logger.level = Logger::DEBUG

    # Start server and client
    assert_not_timeout('Server do not start') { @server.start }
    assert_not_timeout('Client do not connect') { @client.connect }

    # Client can communicate with the server
    assert_not_timeout 'Client do not communicate with server' do
      @client.send 'test string'
      assert_equal 'test string', SERVER_READER.pop.chomp
      assert_equal 'test string', @client.receive
    end
  end

  def test_should_works_with_min_listener_at_0
    @server = TestServer.new(:min_listener => 0, :stdlog => TEST_LOG)
    assert_equal 0, @server.min_listener

    # Start server and client
    assert_not_timeout('Server do not start') { @server.start }
    assert_not_timeout('Client do not connect') { @client.connect }

    # Client can communicate with the server
    assert_not_timeout 'Client do not communicate with server' do
      @client.send 'test string'
      assert_equal 'test string', SERVER_READER.pop.chomp
      assert_equal 'test string', @client.receive
    end

    # Close client
    assert_not_timeout('Client do not close connection') { @client.close }
    wait_listeners

    # min_listener
    assert_equal @server.min_listener, @server.listeners
    assert_equal @server.min_listener, @server.waiting_listeners
  end

  def test_should_have_connection_list
    # Start server
    assert_not_timeout('Server do not start') { @server.start }

    # Zero connection
    assert_equal @server.min_listener, @server.listeners
    assert_equal @server.min_listener, @server.waiting_listeners
    assert_equal [], @server.connections

    # Start client
    assert_not_timeout('Client do not connect') { @client.connect }
    wait_connections

    # Connection information
    assert_equal 1, @server.connections.size
    assert_equal 'AF_INET', @server.connections.first[0]
    assert_match(/^\d+$/, @server.connections.first[1].to_s)
    assert_match(/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/, @server.connections.first[3])
  end

  protected

  def assert_not_timeout(msg = 'Timeout')
    assert_nothing_raised(msg) do
      Timeout.timeout(5) do
        yield
      end
    end
  end

  # Wait listener spawn
  def wait_listeners(number = @server.min_listener)
    assert_not_timeout do
      sleep 0.1 until @server.listeners == number
    end
  end

  # Wait connection established with listener
  def wait_connections(number = @server.listeners)
    assert_not_timeout do
      sleep 0.1 until @server.connections.size == number
    end
  end
end