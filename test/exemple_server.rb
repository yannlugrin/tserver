require File.expand_path(File.dirname(__FILE__) + '/../lib/tserver')

# Exemple server, lauch this script and open a telnet to communicate
# with the server. The server print logging information and received data
# in console. The client receive a copy of sending data.
#
# Syntax exemple :
# ruby exemple_server.rb
# ruby exemple_server.rb 127.0.0.1 10001
# ruby exemple_server.rb 127.0.0.1
# ruby exemple_server.rb 10001
# ruby exemple_server.rb 10001 127.0.0.1
#
# Default values :
host = '127.0.0.1'
port = 10001

ARGV.each do |argv|
	if argv =~ /^\d+$/
		port = argv.to_i
	elsif argv =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/
		host = argv
	end
end

#
class ExempleServer < TServer
	def process(conn)
		conn.each do |line|
			break if line =~ /(quit|exit|close)/

			log '> ' + line.chomp
			conn.puts Time.now.to_s + ' > ' + line.chomp
		end
	end
end

# Start server
server = ExempleServer.new(:port => port, :host => host)
server.verbose = true
server.debug = true

Signal.trap('SIGINT') do
	server.shutdown
end

server.start(true)