require 'rake'
require 'rake/testtask'
require 'rake/rdoctask'
require 'rake/gempackagetask'
require 'rubygems'

require  File.join(File.dirname(__FILE__), 'lib', 'tserver')

TSERVER_VERSION = '0.2.0'

task :default => ['test']

# Test
Rake::TestTask.new do |t|
  t.libs << 'test'
  t.libs << 'lib'

  t.test_files = FileList['test/*_test.rb']

  t.verbose = true
  t.warning = true
end

# Exemple server
desc 'Run \'test/example_server.rb\', accept IP and PORT argument (default: 127.0.0.1 10001)'
task :server do
  require 'test/example_server'
end


# Doc
Rake::RDocTask.new do |rdoc|
  rdoc.title = "TServer - #{TSERVER_VERSION} - RDOC Documentation"
  rdoc.main = 'README'

  rdoc.options << '--inline-source'

  rdoc.rdoc_files.include('README', 'CHANGELOG', 'LICENSE', 'lib/*')
  rdoc.rdoc_dir = 'doc'
end

# Create gem
Gem::manage_gems
spec = Gem::Specification.new do |s|
  s.platform  =   Gem::Platform::RUBY

  s.name          = 'tserver'
  s.version       = TSERVER_VERSION

  s.author        = 'Yann Lugrin'
  s.email         = 'yann.lugrin@sans-savoir.net'
  s.summary       = 'A persistant multithread TCP server'
  s.homepage      = 'http://github.com/yannlugrin/tserver/wikis'

  s.files         = FileList['lib/*.rb', 'test/*'].to_a

  s.require_path  = 'lib'
  s.test_files    = Dir.glob('tests/*_test.rb')

  s.has_rdoc = true
  s.extra_rdoc_files = ['README', 'CHANGELOG', 'LICENSE']
end

Rake::GemPackageTask.new(spec) do |pkg|
  pkg.need_tar = true
end

task :create_gem => "pkg/#{spec.name}-#{spec.version}.gem" do
  puts 'generated latest version'
end
