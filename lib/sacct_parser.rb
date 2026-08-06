# frozen_string_literal: true

require 'json'
require_relative 'sacct_cli'

# To get the special metrics from cli
class SacctParser
  def initialize
    @db = SacctCli.db
  end

  def parse
    file = File.read('jobs_last_7days.json')
    data = JSON.parse(file)
    data['jobs']&.each do |job|
      formatted = get_formatted(job)
      payload = get_payload(job, formatted)
      load_to_database(payload)
    end
  end

  private

  def get_formatted(job)
    total_cpu = get_total_cpu(job)
    maxrss_kb = get_max_rss(job)
    req_mem_mb = job.dig('required', 'memory_per_cpu', 'number').to_f
    alloc_cpus = job.dig('required', 'CPUs').to_i
    elapsed_sec = job.dig('time', 'elapsed').to_i
    cpueff = get_cpueff(elapsed_sec, alloc_cpus, total_cpu)
    memeff = get_memeff(req_mem_mb, maxrss_kb)
    [total_cpu, maxrss_kb, req_mem_mb, alloc_cpus, elapsed_sec, cpueff, memeff]
  end

  def get_total_cpu(job)
    sec  = (job.dig('time', 'total', 'seconds') || 0).to_f
    usec = (job.dig('time', 'total', 'microseconds') || 0).to_f
    sec + (usec / 1_000_000.0)
  end

  def get_max_rss(job)
    step = job['steps']&.first
    mem_tres = step&.dig('tres', 'requested', 'max')&.find { |t| t['type'] == 'mem' }
    mem_tres ? (mem_tres.fetch('count', 0).to_f / 1024.0) : 0.0
  end

  def get_memeff(req_mem_mb, maxrss_kb)
    req_mem_kb = req_mem_mb * 1024.0
    req_mem_kb.positive? ? (maxrss_kb / req_mem_kb) * 100.0 : 0.0
  end

  def get_cpueff(elapsed_sec, alloc_cpus, total_cpu)
    if elapsed_sec.positive? && alloc_cpus.positive?
      (total_cpu / (elapsed_sec * alloc_cpus)) * 100.0
    else
      0.0
    end
  end

  def get_payload(job, formatted)
    sub_time = job.dig('time', 'submission').to_i
    start_time = job.dig('time', 'start').to_i

    timing_payload(job, formatted, sub_time, start_time)
      .merge(metrics_payload(job, formatted))
  end

  def load_to_database(payload)
    existing_state = @db[:sacct].where(job_id: payload[:job_id]).get(:state)
    if existing_state.nil?
      @db[:sacct].insert(payload)
    elsif existing_state == 'RUNNING'
      @db[:sacct].where(job_id: payload[:job_id]).update(payload)
    end
  end

  def calculate_queuetime(sub_time, start_time)
    start_time.positive? && sub_time.positive? ? (start_time - sub_time).to_f : 0.0
  end

  def timing_payload(job, formatted, sub_time, start_time)
    {
      job_id: job['job_id'], user: job['user'], partition: job['partition'],
      state: job.dig('state', 'current'), submit: sub_time, start: start_time,
      end: job.dig('time', 'end').to_i, elapsed: formatted[4],
      queuetime: calculate_queuetime(sub_time, start_time).round(4)
    }
  end

  def metrics_payload(job, formatted)
    {
      alloccpus: formatted[3], totalcpus: formatted[0].round(4),
      cpueff: formatted[5].round(4), reqmem: formatted[2].round(4),
      maxrss: formatted[1].round(4), memeff: formatted[6].round(4),
      exitcode: job.dig('exit_code', 'return_code').to_i
    }
  end
end
