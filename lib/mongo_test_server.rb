# coding: UTF-8
#begin
#  require 'mongo'
#rescue LoadError => e
#  require 'moped'
#end
require 'fileutils'
require 'erb'
require 'yaml'
require 'tempfile'
require "mongo_test_server/version"
require "mongo_test_server/tmp_storage"
require "mongo_test_server/ram_disk_storage"

if defined?(Rails)
  require 'mongo_test_server/railtie'
  require 'mongo_test_server/engine'
end

module MongoTestServer

  class Mongod

    class << self

      def configure(options={}, &block)
        options.each do |k,v|
          server.send("#{k}=",v) if server.respond_to?("#{k}=")
        end
        yield(server) if block_given?
      end

      def server
        @mongo_test_server ||= new
      end

      def start_server
        unless @mongo_test_server.nil?
          @mongo_test_server.start
        else
          puts "MongoTestServer not configured properly!"
        end
      end

      def stop_server
        unless @mongo_test_server.nil?
          @mongo_test_server.stop
        end
      end

    end

    attr_writer :port
    attr_writer :path
    attr_writer :name
    attr_reader :mongo_instance_id
    attr_reader :use_ram_disk

    def initialize(port=nil, name=nil, path=nil)
      self.port = port
      self.path = path
      self.name = name
      @mongo_process_or_thread = nil
      @mongo_instance_id = "#{Time.now.to_i}_#{Random.new.rand(100000..900000)}"
      @oplog_size = 200
      @configured = true
    end

    def use_ram_disk=(bool)
      @use_ram_disk = bool && RamDiskStorage.supported?
    end

    def use_ram_disk?
      @use_ram_disk
    end

    def storage
      @storage ||= if use_ram_disk?
        $stderr.puts "MongoTestServer: using ram disk storage"
        RamDiskStorage.new(@name)
      else
        $stderr.puts "MongoTestServer: using tmp disk storage"
        TmpStorage.new(@name)
      end
    end

    def mongo_storage
      storage.path
    end

    def mongo_log
      "#{storage.path}/mongo_log"
    end

    def port
      @port ||= 27017
    end

    def path
      @path ||= `which mongod`.chomp
    end

    def name
      @name ||= "#{Random.new.rand(100000..900000)}"
    end

    def mongo_cmd_line
      "#{self.path} --port #{self.port} --profile 2 --dbpath #{self.mongo_storage} --syncdelay 0 --nojournal --noauth --nohttpinterface --nssize 1 --oplogSize #{@oplog_size} --smallfiles --logpath #{self.mongo_log}"
    end

    def before_start
      storage.create
    end

    def after_stop
      storage.delete
    end

    def running?
      pids = `ps ax | grep mongod | grep #{self.port} | grep #{self.mongo_storage} | grep -v grep | awk '{print \$1}'`.chomp
      !pids.empty?
    end

    def started?
      File.directory?(self.mongo_storage) && File.exists?("#{self.mongo_storage}/started")
    end

    def killed?
      !File.directory?(self.mongo_storage) || File.exists?("#{self.mongo_storage}/killed")
    end

    def started=(running)
      if File.directory?(self.mongo_storage)
        running ? FileUtils.touch("#{self.mongo_storage}/started") : FileUtils.rm_f("#{self.mongo_storage}/started")
      end
    end

    def killed=(killing)
      if File.directory?(self.mongo_storage)
        killing ? FileUtils.touch("#{self.mongo_storage}/killed") : FileUtils.rm_f("#{self.mongo_storage}/killed")
      end
    end

    def error?
      File.exists?("#{self.mongo_storage}/error")
    end

    def configured?
      @configured
    end

    def start
      unless started?
        before_start
        if RUBY_PLATFORM=='java'
          @mongo_process_or_thread = Thread.new { run(mongo_cmd_line) }
        else
          @mongo_process_or_thread = fork { run(mongo_cmd_line) }
        end
        wait_until_ready
      end
      self
    end

    def run(command, *args)
      error_file = Tempfile.new('error')
      error_filepath = error_file.path
      error_file.close
      args = args.join(' ') rescue ''
      command << " #{args}" unless args.empty?
      result = `#{command} 2>"#{error_filepath}"`
      unless killed? || $?.success?
        error_message = <<-ERROR
          <#{self.class.name}> Error executing command: #{command}
          <#{self.class.name}> Result is: #{IO.binread(self.mongo_log) rescue "No mongo log on disk"}
          <#{self.class.name}> Error is: #{File.read(error_filepath) rescue "No error file on disk"}
        ERROR
        File.open("#{self.mongo_storage}/error", 'w') do |f|
          f << error_message
        end
        self.killed=true
      end
      result
    end

    def test_connection!
      if defined?(Mongo)
        c = Mongo::Connection.new("localhost", self.port)
        c.close
      elsif defined?(Moped)
        session = Moped::Session.new(["localhost:#{self.port}"])
        session.disconnect
      else
        raise Exeption.new "No mongo driver loaded! Only the official mongo driver and the moped driver are supported"
      end
    end

    def wait_until_ready
      retries = 10
      begin
        self.started = true
        test_connection!
      rescue Exception => e
        if retries>0 && !killed? && !error?
          retries -= 1
          sleep 0.5
          retry
        else
          self.started = false
          error_lines = []
          error_lines << "<#{self.class.name}> cmd was: #{mongo_cmd_line}"
          error_lines << "<#{self.class.name}> ERROR: Failed to connect to mongo database: #{e.message}"
          begin
            IO.binread(self.mongo_log).split("\n").each do |line|
              error_lines << "<#{self.class.name}> #{line}"
            end
          rescue Exception => e
            error_lines << "No mongo log on disk at #{self.mongo_log}"
          end
          stop
          raise Exception.new error_lines.join("\n")
        end
      end
    end

    def pids
      pids = `ps ax | grep mongod | grep #{self.port} | grep #{self.mongo_storage} | grep -v grep | awk '{print \$1}'`.chomp
      pids.split("\n").map {|p| (p.nil? || p=='') ? nil : p.to_i }
    end

    def stop
      mongo_pids = pids
      self.killed = true
      self.started = false
      mongo_pids.each { |ppid| `kill -9 #{ppid} 2> /dev/null` }
      after_stop
      self
    end

    def mongoid_options(options={})
      options = {host: "localhost", port: self.port, database: "#{self.name}_test_db", use_utc: false, use_activesupport_time_zone: true}.merge(options)
    end

    def mongoid3_options(options={})
      options = {hosts: ["localhost:#{self.port}"], database: "#{self.name}_test_db", use_utc: false, use_activesupport_time_zone: true}.merge(options)
    end

    def mongoid_yml(options={})
      options = mongoid_options(options)
      mongo_conf_yaml = <<EOY
host: #{options[:host]}
port: #{options[:port]}
database : #{options[:database]}
use_utc: #{options[:use_utc]}
use_activesupport_time_zone: #{options[:use_activesupport_time_zone]}
EOY
    end

    def mongoid3_yml(options={})
      options = mongoid3_options(options)
      mongo_conf_yaml = <<EOY
sessions:
  default:
    hosts:
      - #{options[:hosts].first}
    database: #{options[:database]}
    use_utc: #{options[:use_utc]}
    use_activesupport_time_zone: #{options[:use_activesupport_time_zone]}
EOY
    end

  end
end