#!/usr/bin/ruby

require 'optparse'
require 'ostruct'
require 'json'
require 'open-uri'
require 'fileutils'
require 'net/http'
require 'time'
require 'date'
require 'yaml'
require 'set'

options = OpenStruct.new
options.update_from_chronos = false
options.force = false
options.delete_force = false
options.validate = false
options.delete_missing = false
options.skip_sync = false

opts = OptionParser.new do |o|
  o.banner = "Usage: #{$0} [options]"
  o.on("-u", "--uri URI", "URI for Chronos") do |t|
    options.uri = /^\/*(.*)/.match(t.reverse)[1].reverse
  end
  o.on("-p", "--config PATH", "Path to configuration") do |t|
    options.config_path = t
  end
  o.on("-c", "--update-from-chronos", "Update local job configuration from Chronos") do |t|
    options.update_from_chronos = true
  end
  o.on("-f", "--force", "Forcefully update data in Chronos from local configuration") do |t|
    options.force = true
  end
  o.on("-d", "--delete-force", "Delete data in Chronos without asking") do |t|
    options.delete_force = true
  end
  o.on("-V", "--validate", "Validate jobs, don't do anything else. Overrides other options.") do |t|
    options.validate = true
  end
  o.on("--http-auth", "--http-auth CRED", "Authentication credentials in the user:password form") do |t|
    cred_split = t.split(':')
    if cred_split.length != 2
      raise OptionParser::InvalidArgument
    end
    options.http_auth_user = cred_split[0].strip
    options.http_auth_pass = cred_split[1].strip
  end
  o.on("--delete-missing", "Delete missing jobs from chronos. Prompts for confirmation unless --force is also passed.") do
    options.delete_missing = true
  end
  o.on("--skip-sync", "Skip syncing local jobs") do
    options.skip_sync = true
  end
end

begin
  opts.parse(ARGV)
  raise OptionParser::MissingArgument if options.uri.nil? && !options.validate
  raise OptionParser::MissingArgument if options.config_path.nil?
rescue OptionParser::InvalidOption, OptionParser::MissingArgument
  $stderr.puts $!.to_s
  $stderr.puts opts
  abort
end

def parse_scheduler_jobs(file)
      data = file.readlines()
      JSON.parse(data.first)
end

json = nil
if !options.validate
  if (defined? options.http_auth_user) && (defined? options.http_auth_pass)
    open("#{options.uri}/v1/scheduler/jobs", :http_basic_authentication => ["#{options.http_auth_user}", "#{options.http_auth_pass}"]) do |f|
      json = parse_scheduler_jobs(f)
    end
  else
    open("#{options.uri}/v1/scheduler/jobs") do |f|
      json = parse_scheduler_jobs(f)
    end
  end
end

def set_defaults(job)
  newjob = job.dup
  newjob['highPriority'] = false unless job.include?('highPriority')
  newjob
end

def raise_if_missing(job, field)
  if !job.include?(field)
    raise"Job #{job['name']} is missing required field `#{field}`"
  end
end

def has_required_fields?(job, typeField)
  if !job.include?('name')
    raise("Job #{job.to_s} is missing required field `name`")
  end
  raise_if_missing(job, 'command')
  raise_if_missing(job, 'owner')
  raise_if_missing(job, 'cpus')
  raise_if_missing(job, 'disk')
  raise_if_missing(job, 'mem')
  raise_if_missing(job, 'runAsUser')
  raise_if_missing(job, typeField)
  true
end

def normalize_job(job)
  newjob = job.dup
  newjob.delete 'successCount'
  newjob.delete 'errorCount'
  newjob.delete 'lastSuccess'
  newjob.delete 'lastError'
  newjob.delete 'errorsSinceLastSuccess'

  # Define optional fields, if not present
  newjob['uris'] = [] if !newjob.include?('uris')

  # Sort these guys
  if newjob.include?('parents')
    newjob['parents'] = newjob['parents'].sort
  end
  newjob['uris'] = newjob['uris'].sort

  newjob
end

def sanitize_name(name)
  r = name.dup
  r.gsub!(/^.*(\\|\/)/, '')
  r.gsub!(/[^0-9A-Za-z.\-]/, '_')
  r
end

scheduled_jobs = {}
dependent_jobs = {}

if !options.validate
  json.each do |j|
    stripped_job = normalize_job(j)
    if j.include? 'schedule'
      scheduled_jobs[j['name']] = stripped_job
    else
      dependent_jobs[j['name']] = stripped_job
    end
  end

  def write_job(f, job)
    f.puts "## This file was automatically generated by `#{$0}`."
    f.puts "## If you edit it, please remove these lines as a courtesy."
    f.puts "#"
    f.puts "# Chronos configuration for `#{job['name']}`"
    f.puts "#"
    f.puts "# For details on Chronos configuration, see:"
    f.puts "#  https://github.com/mesos/chronos/blob/master/README.md#job-configuration"
    f.puts "#"
    f.puts YAML.dump(job)
  end

  if options.update_from_chronos
    Dir.chdir(options.config_path) do
      FileUtils.mkdir_p('dependent')
      Dir.chdir('dependent') do
        dependent_jobs.each do |name,job|
          File.open("#{sanitize_name(name)}.yaml", 'w') do |f|
            write_job(f, job)
          end
        end
      end

      FileUtils.mkdir_p('scheduled')
      Dir.chdir('scheduled') do
        scheduled_jobs.each do |name,job|
          File.open("#{sanitize_name(name)}.yaml", 'w') do |f|
            write_job(f, job)
          end
        end
      end
    end
    exit 0
  end
end

def load_job(fn, lines, prefix, typeName)
  begin
    parsed = YAML.load(lines)
    parsed = set_defaults(parsed)
    # Verify that job has all the required fields
    has_required_fields?(parsed, typeName)
    if fn.gsub(/\.ya?ml$/, '') != sanitize_name(parsed['name'].gsub(/\.ya?ml$/, ''))
      puts "Name from '#{prefix}/#{fn}' doesn't match job name of '#{parsed['name']}'"
      puts "  expected '#{prefix}/#{sanitize_name(parsed['name'])}.yaml'"
      nil
    elsif prefix == 'dependent'
      if parsed.include? 'schedule'
        puts "Dependent job from '#{dependent}/#{fn}' must not contain a schedule!"
        nil
      else
        parsed
      end
    elsif prefix == 'scheduled'
      if parsed.include? 'parents'
        puts "Scheduled job from '#{prefix}/#{fn}' must not contain parents!"
        nil
      else
        parsed
      end
    end
  rescue Psych::SyntaxError => e
    $stderr.puts "Parsing error when reading '#{prefix}/#{fn}'"
    nil
  rescue => e
    $stderr.puts "Failed to load job from '#{prefix}/#{fn}':"
    $stderr.puts "  #{e.to_s}"
    $stderr.puts
    nil
  end
end

valid = true
jobs = {}
Dir.chdir(options.config_path) do
  Dir.chdir('dependent') do
    paths = Dir.glob('*.yaml') + Dir.glob('*.yml')
    paths.each do |fn|
      lines = File.open(fn).readlines().join
      job = load_job(fn, lines, 'dependent', 'parents')
      if job.nil?
        valid = false
      else
        jobs[job['name']] = job
      end
    end
  end

  Dir.chdir('scheduled') do
    paths = Dir.glob('*.yaml') + Dir.glob('*.yml')
    paths.each do |fn|
      lines = File.open(fn).readlines().join
      job = load_job(fn, lines, 'scheduled', 'schedule')
      if job.nil?
        valid = false
      else
        jobs[job['name']] = job
      end
    end
  end
end

if options.validate
  jobs.each do |name,job|
    if job.include? 'schedule'
      begin
        start_time = DateTime.iso8601(/^R\d*\/([^\/]+)\//.match(job['schedule'])[1])
      rescue => e
        $stderr.puts "Couldn't parse schedule for job '#{name}'"
        $stderr.puts e
        valid = false
      end
    elsif job.include? 'parents'
      job['parents'].each do |parent|
        if !jobs.include?(parent)
          $stderr.puts "Job '#{name}' has parent '#{parent}' which is not defined."
          valid = false
        end
      end
    else
      $stderr.puts "Job '#{name}' has neither a schedule or parents defined."
      valid = false
    end
  end
  if valid
    exit 0
  else
    $stderr.puts
    $stderr.puts "There were validation errors."
    exit 1
  end
end

if !options.skip_sync
  jobs_to_be_updated = []

  cur_datetime = Time.now.utc.to_datetime

  # Update scheduled jobs first
  jobs.each do |name,job|
    if job.include? 'schedule'
      if scheduled_jobs.include? name
        existing_job = scheduled_jobs[name]
        new_job = job
        # Caveat: when comparing scheduled jobs, we have to ignore part of the
        # schedule field because it gets updated by chronos.
        existing_job['schedule'] = existing_job['schedule'].gsub(/^R\d*\/[^\/]+\//, '')
        new_schedule = new_job['schedule']
        new_job['schedule'] = new_job['schedule'].gsub(/^R\d*\/[^\/]+\//, '')
        # Fields not defined in new_job, but present in existing_job, should be dropped from existing_job
        existing_job.each do |k,v|
          if !new_job.include?(k)
            existing_job.delete(k)
          end
        end
        if options.force || !scheduled_jobs.include?(name) || normalize_job(existing_job).to_a.sort_by{|x|x[0]} != normalize_job(new_job).to_a.sort_by{|x|x[0]}
          new_job['schedule'] = new_schedule
          jobs_to_be_updated << {
            :new => job,
            :old => scheduled_jobs[name],
          }
        end
      else
        jobs_to_be_updated << {
          :new => job,
          :old => nil,
        }
      end
    end
  end

  # The order for updating dependent jobs matters.
  dependent_jobs_to_be_updated = []
  dependent_jobs_to_be_updated_set = Set.new
  jobs.each do |name,job|
    if job.include? 'parents'
      if dependent_jobs.include? name
        existing_job = dependent_jobs[name]
        new_job = job
        if options.force || !dependent_jobs.include?(name) || normalize_job(existing_job).to_a.sort_by{|x|x[0]} != normalize_job(new_job).to_a.sort_by{|x|x[0]}
          dependent_jobs_to_be_updated_set.add(job['name'])
          dependent_jobs_to_be_updated << {
            :new => job,
            :old => dependent_jobs[name],
          }
        end
      else
        dependent_jobs_to_be_updated << {
          :new => job,
          :old => nil,
        }
      end
    end
  end

  # TODO: detect circular dependencies more intelligently
  remaining_attempts = 100
  while !dependent_jobs_to_be_updated.empty? && remaining_attempts > 0
    remaining_attempts -= 1
    these_jobs = dependent_jobs_to_be_updated.dup
    to_delete = []
    these_jobs.each_index do |idx|
      job = these_jobs[idx][:new]
      parents = job['parents']
      # Add only the jobs for which their parents have already been added.
      can_be_added = true
      parents.each do |p|
        if dependent_jobs_to_be_updated_set.include?(p)
          # This job can't be added yet.
          can_be_added = false
        end
      end
      if can_be_added
        jobs_to_be_updated << these_jobs[idx]
        to_delete << idx
        dependent_jobs_to_be_updated_set.delete(job['name'])
      end
    end
    to_delete = to_delete.sort.reverse
    to_delete.each do |idx|
      dependent_jobs_to_be_updated.delete_at idx
    end
  end

  if !dependent_jobs_to_be_updated.empty?
    jobs_to_be_updated += dependent_jobs_to_be_updated
  end

  if !jobs_to_be_updated.empty?
    puts "These jobs will be updated:"
  end

  jobs_to_be_updated.each do |j|
    puts "About to update #{j[:new]['name']}"
    puts
    puts "Old job:", YAML.dump(j[:old])
    puts
    puts "New job:", YAML.dump(j[:new])
    puts
  end

  jobs_to_be_updated.each do |j|
    job = j[:new]
    method = nil
    if job.include? 'schedule'
      method = 'iso8601'
    else
      method = 'dependency'
    end
    uri = URI("#{options.uri}/v1/scheduler/#{method}")
    req = Net::HTTP::Post.new(uri.request_uri)
    req.body = JSON.generate(job)
    req.content_type = 'application/json'
    req.basic_auth options.http_auth_user, options.http_auth_pass if (defined? options.http_auth_user)

    puts "Sending POST for `#{job['name']}` to #{uri.request_uri}"

    begin
      res = Net::HTTP.start(uri.hostname, uri.port, :use_ssl => uri.scheme == 'https') do |http|
        http.request(req)
      end

      case res
      when Net::HTTPSuccess, Net::HTTPRedirection
        # OK
      end
    rescue Timeout::Error, Errno::EINVAL, Errno::ECONNRESET, EOFError,
      Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError => e
      $stderr.puts "Error updating job #{job['name']}!"
      $stderr.puts res.value
    end

    # Pause after each request so we don't explode chronos
    sleep 0.1
  end

  puts "Finished checking/updating jobs"
  puts
end

def delete_job(options, job_name)
  uri = URI("#{options.uri}/v1/scheduler/job/#{job_name}")
  req = Net::HTTP::Delete.new(uri.request_uri)
  req.basic_auth options.http_auth_user, options.http_auth_pass if (defined? options.http_auth_user)

  puts "Sending DELETE for `#{job_name}` to #{uri.request_uri}"

  begin
    res = Net::HTTP.start(uri.hostname, uri.port, :use_ssl => uri.scheme == 'https') do |http|
      http.request(req)
    end
    raise Net::HTTPBadResponse if !res.is_a?(Net::HTTPNoContent)
  rescue Timeout::Error, Errno::EINVAL, Errno::ECONNRESET, EOFError,
    Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError => e
    $stderr.puts "Error deleting job #{job_name}!"
    $stderr.puts res.inspect
  end
end

# Look for jobs in chronos which don't exist here, print a warning
def check_if_defined(jobs, name, options)
  if !jobs.include?(name)
    if options.delete_missing
      $stdout.print "The job #{name} exists in chronos, but is not defined! "
      $stdout.print "Delete [yN]? " unless options.delete_force
      delete_job(options, name) if (options.delete_force || $stdin.gets.chomp.downcase == "y")
    else
      $stderr.puts "The job #{name} exists in chronos, but is not defined!"
    end
  end
end

dependent_jobs.each do |name, job|
  check_if_defined(jobs, name, options)
end

scheduled_jobs.each do |name, job|
  check_if_defined(jobs, name, options)
end
