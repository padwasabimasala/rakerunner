#!/usr/bin/env ruby
require 'yaml'
require 'socket'
require 'pathname'
require 'thread'
require 'set'
require 'rakerunner/daemonlib'

# rakerunner is a rake manager that runs as a daemon. 
# Unlike cron which runs a rake at a give time or interval rakerunner 
# does it's best to ensure that a given number of rakes are running all 
# the time.
#
# TODO
# - consider the implications of making RakeRunnerUtil.find_conf a 'self' method
# - check rakerunner for instances of find_conf
# - ensure that find_conf checks env, cwd and etc for config in that order
# - rename rakerunner file to rake_runner or RakeRunner to Rakerunner so naming matches convention
#

$DEBUG = false || ENV['DEBUG']

class RakeRunner < Daemon::Base
  RAKE = %x(which rake).rstrip
  RUBY = %x(which ruby).rstrip
  DEFAULT_CONF_RELOAD_WAIT = 60*10 # ten minutes between conf reloads
  DEFAULT_COMMAND_CHECK_WAIT = 0.25

  def initialize(conf_file='/etc/rakeruner/rakerunner.conf', daemon_name=nil)
    @conf_file = File.expand_path(conf_file)
    @conf_dir = Pathname.new(@conf_file).parent.to_s #parent dir of conf_file
    @daemon_name = daemon_name
    @daemon_dir = nil 
    @rake_file = nil 
    @env_vars = nil
    @configured_rakes = nil #set by load_runtime_conf
    @started_rakes = Set.new
    @ignore_rakes = []
    @rake_logging = false
    @rake_log_dir = nil
    @conf_reload_wait = DEFAULT_CONF_RELOAD_WAIT
    @fifo_observer_running = false #used during shutdown to mark when fifo observer has stopped
    exit if not load_startup_conf
    super(@daemon_name, @daemon_dir)
    load_runtime_conf
    #TODO sanity check howmany matching rakes are already running
  end

  def get_confs
    # open and sanity check and parse conf
    #TODO what if the conf is not valid yaml?
    begin
      ymlcnf = YAML::load(File::open(@conf_file))
    rescue Errno::ENOENT => e #conf file not found
      log "conf error: #{e}"
      return nil
    rescue ArgumentError => e
      log "conf error: #{e}"
      return nil
    end

    # get global and local confs from conf_file
    hostname = Socket.gethostname
    global_conf = ymlcnf['*']
    local_conf = ymlcnf[hostname]
    if not (global_conf or local_conf)
      log "conf error: No entry for #{hostname} or * found."
      return nil
    end
    global_conf = {} if !global_conf
    local_conf = {} if !local_conf

    return [global_conf, local_conf]
  end

  def load_startup_conf 
    global_conf, local_conf = get_confs
    $DEBUG = true if global_conf['debug'] == true
    log "DEBUG: #{$DEBUG}"

    @rake_logging = global_conf['rake_logging']
    @rake_log_dir = global_conf['rake_log_dir']

    #get absolute path to rake_file from either conf giving local presidence
    rake_file = nil
    [local_conf, global_conf].each { |conf| rake_file = conf['rake_file'] if conf['rake_file'] && !rake_file }
    if !rake_file
      log "conf error: No rakefile specified."
      return nil
    end
    rake_file = abspath(rake_file)
    if not File.exist?(rake_file) # skip this error if rake_file already set
      log "conf error: rake file #{rake_file} does not exist."
      return nil
    end
    @rake_file = rake_file

    #get absolute path to daemon_dir from either conf giving local presidence
    daemon_dir = nil
    [local_conf, global_conf].each { |conf| daemon_dir = conf['daemon_dir'] if conf['daemon_dir'] && !daemon_dir }
    if !daemon_dir
      log "conf error: No daemon_dir specified."
      return nil
    end
    daemon_dir = abspath(daemon_dir)
    if not File.exist?(daemon_dir) 
      log "conf error: daemon_dir #{daemon_dir} does not exist."
      return nil
    end
    if not File.directory?(daemon_dir) 
      log "conf error: daemon_dir #{daemon_dir} is not a directory."
      return nil
    end
    #TODO check that the daemon_dir is writable
    @daemon_dir = daemon_dir

    #Ensure that there's something to do at startup
    rakes = nil
    [global_conf, local_conf].each { |cnf| rakes = cnf['rakes'] if cnf['rakes'] }
    if !rakes
      log "conf error: No rakes specified."
      return nil
    end
    @rake = rakes

    return true
  end

  def load_runtime_conf
    global_conf, local_conf = get_confs

    @env_vars = (local_conf['env_vars'] or global_conf['env_vars'])
    @conf_reload_wait = (local_conf['conf_reload_wait'] or global_conf['conf_reload_wait']) or DEFAULT_CONF_RELOAD_WAIT

    @configured_rakes = {} 
    rakes_conf = (local_conf['rakes'] or global_conf['rakes'])
    rakes_conf.each do |rakeopts|
      rake, qty, log = rakeopts['rake'], (rakeopts['qty'] or 1), rakeopts['log']
      if !rake
        log "conf error no rake for rake like: #{rakeopts.inspect}"
        next
      end
      @configured_rakes[rake] = {:qty => qty, :log => log}
    end
    log "Warning: configured_rakes is empty." if @configured_rakes.empty?

    rake_file = abspath( (local_conf['rake_file'] or global_conf['rake_file']) )
    daemon_dir = abspath( (local_conf['daemon_dir'] or global_conf['daemon_dir']) )

    if rake_file != @rake_file 
      log "Warning: rake_file changed while running. Restart required for change to take effect. Keeping rake_file set at startup."
      log "startup rake_file: #{@rake_file} config rake_file: #{rake_file}"
    end
    if daemon_dir != @daemon_dir
      log "Warning: daemon_dir changed while running. Restart required for change to take effect. Keeping daemon_dir set at startup."
    end
  end

  def abspath(path)
    return nil if !path
    # convert relative paths to absolutes paths relative to location of conf_file
    if path.slice(0,1) != '/'
      path = File.expand_path(@conf_dir + "/" + path)
    end
    return path
  end

  def start
    begin
      log "starting daemon on pid #{Process.pid}"
      log "conf_file: #{@conf_file}"
      log "daemon_name: #{@daemon_name}"
      log "daemon_dir: #{@daemon_dir}"
      log "rake_file: #{@rake_file}"
      log "rakes_conf: #{@rakes_conf.inspect}"
  
      start_fifo_observer
      # initial rake start up
      check_rakes
      #Main loop reloads config and starts and stops child processes
      last_conf_reload = Time.new
      loop do
        if (Time.new - last_conf_reload) >= @conf_reload_wait
          log "reloading conf"
          load_runtime_conf
          check_rakes
          last_conf_reload = Time.new
        end
        sleep 5
      end
    rescue StandardError => exception
      log "Caught Exception"
      log exception
      log exception.backtrace
      log "retrying"
      retry
    end 
  end
    
  def stop
    # must signal shutdown to other processes wait until finished appears on fifo
    log "stopping daemon"
    # send stop command to fifo (with eof?)
    log "sending 'shutdown' to command watch thread. waiting for fifo to clear."
    write_msg('shutdown')
    # wait for fifo observer to terminate
    while @fifo_observer_running
      sleep 1
    end
    # send KILL signal to all child processes
    log "sending KILL to all children"
    @started_rakes.each do |rake|
      stop_rake(rake)
    end
    log "daemon stopped"
  end


  def start_fifo_observer
    #this thread watches the fifo for commands
    Thread.abort_on_exception = true #abort parent thread if exception raised in this
    fifo_observer = Thread.new do
      log "starting fifo observer thread on pid #{Process.pid}"
      @fifo_observer_running = true
      alias :log_ :log
      log = lambda {|msg|} #prevent thread from writing duplicate log msgs
      loop do
        sleep DEFAULT_COMMAND_CHECK_WAIT
        cmd = read_msg
        next if !cmd
        log_ "received command: #{cmd}"
        if cmd =~ /^stoprake /
          rake = cmd.slice(9,10_000)
          @ignore_rakes << rake
          stop_rake(rake)
          @started_rakes.delete(rake)
        elsif cmd =~ /^startrake /
          rake = cmd.slice(10,10_000)
          rakeopts = @configured_rakes[rake]
          if rakeopts
            qty = rakeopts[:qty]
          else
            qty = 1
          end
          start_rake(rake, qty)
          @ignore_rakes.delete(rake)
        elsif cmd =~ /^clearignores/
          @ignore_rakes = []
        elsif cmd =~ /^shutdown/
          @fifo_observer_running = false
          log_ "stopping fifo observer thread"
          break
        else
          log_ "invalid command '#{cmd}'"
        end
      end
    end
  end
  

  # this is the main body of work
  def check_rakes
    #pids of all configured rakes keyed by rake
    rakes_pids = get_rakes_pids(@configured_rakes.keys)
    #start and stop rakes as necessary so that number running equals qty in config
    @configured_rakes.each do |rake, rakeopts|
      if @ignore_rakes.include?(rake)
        log "rake #{rake} in ignore rakes. skipping."
        next
      end
      qty = rakeopts[:qty] #reassigning vars for readability
      #cnd of processes running rake
      running_cnt = rakes_pids[rake].length
      #start/stop rakes if running cnt </> qty in config
      if running_cnt < qty
        log "rake #{rake} process count #{running_cnt} less than #{qty}"
        start_rake(rake, (qty - running_cnt))
      elsif running_cnt > qty
        log "rake #{rake} process count #{running_cnt} greater than #{qty}"
        stop_rake(rake, (running_cnt - qty))
      end
    end
    #stop all started_rakes not found in configured_rakes (because they were removed from the config)
    @started_rakes.each do |rake|
      if !@configured_rakes.keys.include?(rake) and !@ignore_rakes.include?(rake)
        log "rake #{rake} no longer in config"
        stop_rake(rake) 
        @started_rakes.delete(rake)
      end
    end
  end

  def start_rake(rake, qty=nil)
    # start qty number of child proceses running rake
    log "starting #{qty} instances of #{rake}"
    @started_rakes.add(rake)
    qty = 1 if not qty #nil may be passed in if no qty given in config
    qty.times do
      # start and fork a rake
      pid = fork do
        #set enviroment vars specified in config
        @env_vars.each { |var,val| ENV[var] = val } if @env_vars
        cmd = build_cmd(rake)
        #redirect stdout to log if logging enabled
        rakeopts = @configured_rakes[rake]
        log_file = rakeopts[:log] if !log_file and rakeopts
        if log_file || @rake_logging
          #TODO check that log file exists and is writeable
          log_file = "#{@rake_log_dir or ''}/#{rake}.log" if !log_file
          cmd = "#{cmd} >> #{abspath(log_file)}"
        end
        log "running: " + cmd
        exec(cmd)
      end
      Process.detach(pid)
    end
  end

  def stop_rake(rake, qty=nil)
    # stop qty number of child processes running rake
    log "stopping #{qty or 'all'} instances of #{rake}"
    qty = 10_000 if not qty
    #array of arrays where each subarray begins with pid of parent process running rake, followed by any child pids
    pid_arrs = get_rakes_pids([rake])[rake]
    if pid_arrs.empty?
      log "no pids for rake #{rake}"
      return
    end
    #parent and child pids
    pid_sets = pid_arrs.slice(0,qty)
    for pid_set in pid_sets
      parent, *children = pid_set
      log "stopping rake #{rake} sending TERM to pid #{parent}"
      safe_term parent
      for pid in children
        log "stopping rake #{rake} sending TERM to pid #{pid} (child of #{parent})"
        safe_term pid
      end
    end
  end

  def build_cmd(rake)
    [RAKE, '-f', @rake_file, rake].join(' ')
  end

  def safe_term(pid)
    # send TERM to pid and ignore if pid does not exist
    begin # may have already died
      Process.kill("TERM", pid)
    rescue Errno::ESRCH
      log "pid #{pid} no longer running"
    end
    sleep 1
    # check if the process is still running
    begin # may have already died
      Process.kill(0, pid)
      log "pid #{pid} still running. Sending SIGKILL"
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
    rescue Errno::ESRCH
      nil
    end
  end

  def get_rakes_pids(rakes)
    process_list = `ps -eo pid,ppid,cmd`
    pid_ppid = {}
    ppid_pids = {}
    cmd_pids = {}
    process_list.each do |line|
      pid, ppid, *cmd = line.split(' ')
      pid, ppid, cmd = pid.to_i, ppid.to_i, cmd.join(' ')
      
      pid_ppid[pid] = ppid

      ppid_pids[ppid] ||= []
      ppid_pids[ppid] << pid

      cmd_pids[cmd] ||= []
      cmd_pids[cmd] << pid
      puts cmd if cmd =~ /rake/
    end

    # keyed by rake. value is array of arrays
    # each sub array begins with the pid of the rake task, 
    # followed by all child process of that process
    rakes_pids = {}

    rakes.each do |rake|
      rakes_pids[rake] ||= []
      rakecmd = build_cmd(rake)
      #get pids of all process of rake
      cmd_pids.each do |cmd, pids|
        if cmd =~ /#{rakecmd}/
          #keep pid, (and all child pids) if child of this process
          pids.each do |pid|
            if pid_ppid[pid] == Process.pid
              rakes_pids[rake] << [pid, ppid_pids[pid]].flatten.compact
            end
          end
        end
      end
    end
    rakes_pids
  end
end

  
module Daemon
  module Controller
    def self.cmd_stoprake(daemon, args)
      if !args.empty?
        args.each { |arg| daemon.write_msg("stoprake #{arg}", eof=true) }
      else
        puts "Invalid arguments. Please specify rakename argument."
      end
    end

    def self.cmd_startrake(daemon, args)
      if !args.empty?
        args.each { |arg| daemon.write_msg("startrake #{arg}", eof=true) }
      else
        puts "Invalid arguments. Please specify rakename argument."
      end
    end

    def self.cmd_clearignores(daemon, args)
      daemon.write_msg("clearignores", eof=true)
    end
  end
end


module RakeRunnerUtil
  def find_conf
    # check environment first
    conf_file = ENV['RAKERUNNER_CONF']
    return File.expand_path(conf_file) if conf_file && File.exists?(conf_file)
    # check current working dir for rakerunner.conf
    conf_file = File.expand_path(File.dirname(__FILE__)) + '/rakerunner.conf'
    return File.expand_path(conf_file) if conf_file && File.exists?(conf_file)
    # check /etc
    conf_file = '/etc/rakerunner.conf'
    return File.expand_path(conf_file) if conf_file && File.exists?(conf_file)
    # try and find a conf anywhere beneath the current working dir
    if Dir.pwd != '/'
      conf_file = (`find ./ -name rakerunner.conf`).split()[0]
    end
    return File.expand_path(conf_file) if conf_file && File.exists?(conf_file)
    return nil
  end
end


module RakeRunnerConfParser
  extend RakeRunnerUtil

  def self.hosts_rakes
    parse if !defined? @@parsed
    @@hosts_rakes
  end

  def self.rakes_hosts
    parse if !defined? @@parsed
    @@rakes_hosts
  end

  private
  def self.parse
    @@hosts_rakes = {} 
    @@rakes_hosts = {}
    @@rakerunner_conf_path = find_conf
    if @@rakerunner_conf_path && !defined? @@parsed
      YAML::load(File::open(@@rakerunner_conf_path)).each { |host, spec|
        rakes = []
        if spec && spec['rakes']
          spec['rakes'].each { |rakecnf| 
            rake = rakecnf['rake']
            rakes << rake
            @@rakes_hosts[rake] ||= []
            @@rakes_hosts[rake] << host
          }
        end
        @@hosts_rakes[host] = rakes.sort
      }
      @@parsed = true
    end
  end
end 
