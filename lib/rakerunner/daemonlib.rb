#!/usr/bin/env ruby
# daemonlib.rb is based off of http://snippets.dzone.com/posts/show/2265
# 
# FEATURES
# ========
# - daemonizes a process (redirects STDIN, STDOUT, STDERR)
# - catches TERM signal and calls "shutdown" code before dieing
# - writes pid to file
# - logs to log file
# - supports reading and writing messages thru a FIFO
#
# Note: pid, log and fifo files are written dir containing the daemon script.
# To change this behavior for all files set the value of daemon_dir or 
# individually @pid_fn, @log_fn, @fifo_fn.
#
#
# USAGE
# =====
# To make use of daemonlib simply subclass Daemon::Base and define your own
# start and stop methods. Start should probably run as a loop and stop should
# contain any cleanup code you want run before terminating.
#
#
# SIMPLE EXAMPLE
# ==============
# Bare minimum required to get a working daemon
#
# require 'daemonlib'
#
# class MyDaemon < Daemon::Base
#   def start
#     loop do
#       log "mydaemon running on pid #{$$}"
#       sleep 1
#     end
#   end
#
#   def stop
#     log "mydaemon shutting down"
#   end
# end


require 'fileutils'
require 'pathname'
require 'timeout'
require 'rakerunner/nbfifo'


module Daemon
  class Base
    attr_reader :pid_fn
    attr_reader :fifo_fn
    #For the two defaults below the "calling script" is the top most script
    #which is executed to start the daemon.
    #File name of calling script
    DEFAULT_DAEMON_NAME = Pathname.new($0).split[-1]
    #Parent dir of calling script
    DEFAULT_DAEMON_DIR = File.expand_path(File.dirname($0))
    DEFAULT_READ_MSG_TIMEOUT = 0.5 

    def initialize(daemon_name=nil, daemon_dir=nil)
      daemon_name = DEFAULT_DAEMON_NAME if not daemon_name
      daemon_dir = DEFAULT_DAEMON_DIR if not daemon_dir
      @pid_fn = "#{daemon_dir}/#{daemon_name}.pid"
      @log_fn = "#{daemon_dir}/#{daemon_name}.log"
      @fifo_fn = "#{daemon_dir}/#{daemon_name}.fifo"
    end

    # Child class must implement start
    def start
      raise "NotImplemented"
    end

    # Child class must implement stop
    def stop
      raise "NotImplemented"
    end

    def run
      Controller.run(self)
    end

    def log(msg)
      # write msg to log file or stderr
      begin
        log = File::open(@log_fn, 'a')
      rescue Errno::ENOENT, TypeError
        log = $stderr
      end
      log.write("#{Time.new.strftime("%Y:%m:%d %H:%M:%S")} - #{msg}\n")
      log.flush
    end

    def write_pid(pid)
      # Write pid to PID_FILE or return false
      return false if File.exists?(@pid_fn)
      File.open(@pid_fn, 'w') {|f| f << pid}
    end

    def read_pid
      # return pid from PID_FILe or false
      return false if !File.exists?(@pid_fn)
      IO.read(@pid_fn).to_i rescue false
    end

    def read_msg(timeout=DEFAULT_READ_MSG_TIMEOUT)
      # read msg from fifo
      # TODO: the logic here is broken. 
      # - nil should probably be returned on timeout
      # - raise_eof should probably be a arg (so calling code can handle it if desired)
      # - I'm not sure what the implications of retry are, but it was in the example code
      fifo = NBFifo::new @fifo_fn
      begin 
        msg = nil
        Timeout::timeout(timeout) { msg = fifo.recv }
      rescue Timeout::Error #FIFO_FILE timed out
      rescue EOFError #FIFO_FILE read error
        fifo.reset
      end
      return msg
    end

    def write_msg(msg, eof=false)
      # write msg to fifo
      fifo = NBFifo::new @fifo_fn
      fifo.send msg
      fifo.send_eof
    end
  end

  module Controller
    # The controller module is a simple scheme to organize command 
    # interpretation. The run method looks for a command in the first command
    # line argument (ARGV[0]). If found it searches for a method with a 
    # matchnig name but prefixed with "cmd_", and passes it the daemon object
    # and any args passes to the command line at occur after the first arg.
    #
    # To create a new command open Daemon::Controller and add a method which 
    # follows the aforementioned naming convetion and accepts the arguments
    # "daemon" and "args". For instance:
    #
    # module Daemon
    #   module Controller
    #     def cmd_abandonship(daemon, args)
    #       seconds = args[0]
    #       if not seconds
    #         puts "Invalid command. Usage: abandonship <seconds>."
    #       end
    #       daemon.log("Abanoning ship in #{seconds} seconds.")
    #       sleep seconds
    #       daemon.stop
    #     end
    #   end
    # end
    def self.run(daemon)
      if !ARGV.empty? && ARGV[0] 
        begin
          method = self.method("cmd_#{ARGV[0]}".to_sym)
          args = ARGV.slice(1, ARGV.length)
          method.call(daemon, args)
          exit
        rescue NameError
        end
      end
      commands = []
      methods(false).each do |method_name|
        if method_name.slice(0,4) == 'cmd_'
          commands += [method_name.slice(4,method_name.length)]
        end
      end
      puts "Invalid command. Please specify #{commands.join(", ")}."
    end

    def self.cleanup(daemon)
      # remove pid and fifo files, but leave log
      FileUtils.rm(daemon.pid_fn)
      FileUtils.rm(daemon.fifo_fn)
    end

    def self.cmd_start(daemon, args)
      # more info about process daemonization at 
      # http://www-theorie.physik.unizh.ch/~dpotter/howto/daemonize
      # http://snippets.dzone.com/posts/show/2265
      $stderr.write("starting daemon\n")
      fork do
        Process.setsid
        exit if fork
        if !daemon.write_pid(Process.pid)
          $stderr.write("Pid file exists. Not starting.\n")
          exit
        end
        Dir.chdir '/'
        File.umask 0000
        STDIN.reopen "/dev/null"
        STDOUT.reopen "/dev/null", "a"
        STDERR.reopen STDOUT if not $DEBUG
        trap("TERM") { daemon.stop; cleanup(daemon); exit }
        daemon.start
      end
    end

    def self.cmd_stop(daemon, args)
      # send TERM to pid in PID_FILE
      $stderr.write("stopping daemon\n")
      pid = daemon.read_pid
      if not pid
        $stderr.write("Pid file not found. Is the daemon started?\n")
        exit
      end
      begin
        pid && Process.kill("TERM", pid)
      rescue Errno::ESRCH
        $stderr.write("No process running on pid #{$$}\n")
      end
    end

    def self.cmd_restart(daemon, args)
      self.cmd_stop(daemon, args)
      sleep 3
      self.cmd_start(daemon, args)
    end

    def self.cmd_status(daemon, args)
      pid = daemon.read_pid
      if pid
        begin
          pid && Process.kill(0, pid)
          $stderr.write("Daemon running on pid #{pid}\n")
        rescue Errno::ESRCH
          $stderr.write("No process running on pid #{$$}\n")
        end
      else
        $stderr.write("Daemon not running\n")
      end
    end
  end
end
