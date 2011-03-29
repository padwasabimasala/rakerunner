spec = Gem::Specification.new do |s|
  s.name = "rakerunner"
  s.version = "#{`svn info |grep Revision |cut -c11-`}"
  s.summary = "Keeps rakes running"
  s.description = "Daemon process starts number of rakes and periodically check process list to keep number running"
  s.files = ["lib/rakerunner.rb", 'lib/rakerunner/daemonlib.rb', 'lib/rakerunner/nbfifo.rb', 'demo/rakerunner.conf', 'demo/Rakefile', ]
  s.bindir = "bin"
  s.executables = ['rakerunner']
  s.require_path = 'lib'
  s.has_rdoc = false
  s.author = "Global Based Technologies - Matthew Thorley"
  s.email = "mthorley@globalbased.com"
end
