# frozen_string_literal: true

require 'json'
require 'tty-table'
require_relative '../config/application'

# Command handler for CLI
class SacctCli
  attr_reader :db

  def initialize
    @db = SacctCli.db
  end

  def fetch_and_store
    cmd = 'sacct -a -S now-7days --json > jobs_last_7days.json'
    `#{cmd}`
  end

  def parse
    file = File.read('jobs_last_7days.json')
    data = JSON.parse(file)

    data['jobs']&.each do |job|
      sec  = (job.dig('time', 'total', 'seconds') || 0).to_f
      usec = (job.dig('time', 'total', 'microseconds') || 0).to_f
      total_cpu = sec + (usec / 1_000_000.0)

      step = job['steps']&.first
      mem_tres = step&.dig('tres', 'requested', 'max')&.find { |t| t['type'] == 'mem' }
      maxrss_kb = mem_tres ? (mem_tres.fetch('count', 0).to_f / 1024.0) : 0.0

      req_mem_mb = job.dig('required', 'memory_per_cpu', 'number').to_f
      alloc_cpus = job.dig('required', 'CPUs').to_i
      elapsed_sec = job.dig('time', 'elapsed').to_i

      cpueff = if elapsed_sec.positive? && alloc_cpus.positive?
                 (total_cpu / (elapsed_sec * alloc_cpus)) * 100.0
               else
                 0.0
               end

      req_mem_kb = req_mem_mb * 1024.0
      memeff = req_mem_kb.positive? ? (maxrss_kb / req_mem_kb) * 100.0 : 0.0

      sub_time = job.dig('time', 'submission').to_i
      start_time = job.dig('time', 'start').to_i
      queuetime = start_time.positive? && sub_time.positive? ? (start_time - sub_time).to_f : 0.0

      ret_code = job.dig('exit_code', 'return_code').to_i

      payload = {
        job_id: job['job_id'],
        user: job['user'],
        partition: job['partition'],
        state: job.dig('state', 'current'),
        submit: sub_time,
        start: start_time,
        end: job.dig('time', 'end').to_i,
        elapsed: elapsed_sec,
        queuetime: queuetime.round(4),
        alloccpus: alloc_cpus,
        totalcpus: total_cpu.round(4),
        cpueff: cpueff.round(4),
        reqmem: req_mem_mb.round(4),
        maxrss: maxrss_kb.round(4),
        memeff: memeff.round(4),
        exitcode: ret_code
      }

      existing_state = @db[:sacct].where(job_id: payload[:job_id]).get(:state)

      if existing_state.nil?
        # 1. Job doesn't exist -> Add to database
        @db[:sacct].insert(payload)
      elsif existing_state == 'RUNNING'
        # 3. Job exists and was last listed as running -> Overwrite it with new values
        @db[:sacct].where(job_id: payload[:job_id]).update(payload)
      end
    end
  end

  def format_state(state)
    state.to_s.split(',').map(&:strip).reject(&:empty?)
  end

  def tty_table(results, verbose)
    first_row = results.first
    headers = first_row.keys
    headers[10] = 'cputime'
    if verbose
      rows = results.map do |v|
        [
          v[:job_id],
          v[:user],
          v[:partition],
          v[:state],
          Time.at(v[:submit]).utc.iso8601,
          Time.at(v[:start]).utc.iso8601,
          v[:end].positive? ? Time.at(v[:end]).utc.iso8601 : 'RUNNING',
          "#{v[:elapsed]}s",
          "#{v[:queuetime]}s",
          v[:alloccpus],
          "#{v[:totalcpus]}s",
          "#{v[:cpueff]}%",
          "#{v[:reqmem]}MB",
          "#{v[:maxrss] / 1024.0}MB",
          "#{v[:memeff]}%",
          v[:exitcode]
        ]
      end
    else
      headers = [headers[0], headers[1], headers[2], headers[3], headers[8], headers[10], headers[11], headers[14],
                 headers[15]]
      rows = results.map do |v|
        [
          v[:job_id],
          v[:user],
          v[:partition],
          v[:state],
          "#{v[:queuetime]}s",
          "#{v[:totalcpus]}s",
          "#{v[:cpueff]}%",
          "#{v[:memeff]}%",
          v[:exitcode]
        ]
      end
    end
    table = TTY::Table.new(headers, rows)
    puts table.render(:unicode)
    [headers, rows]
  end

  def calculate_metrics(jobs)
    return nil if jobs.empty?

    count = jobs.size.to_f

    cpu_effs   = jobs.map { |j| j[:cpueff] || 0.0 }.sort
    mem_effs   = jobs.map { |j| j[:memeff] || 0.0 }.sort
    queuetimes = jobs.map { |j| j[:queuetime] || 0.0 }.sort

    calc_median = lambda do |arr|
      len = arr.length
      return 0.0 if len.zero?

      (arr[(len - 1) / 2] + arr[len / 2]) / 2.0
    end

    calc_p95 = lambda do |arr|
      return 0.0 if arr.empty?

      rank = (0.95 * arr.length).ceil - 1
      arr[[rank, 0].max]
    end

    # Calculate Outcomes %
    state_counts = jobs.group_by { |j| j[:state] }
    outcomes_pct = state_counts.transform_values do |state_jobs|
      ((state_jobs.size / count) * 100).round(2)
    end
    outcomes_str = outcomes_pct.map { |k, v| "#{k}: #{v}%" }.join("\n")

    # Calculate Exit Summary
    exit_summary = jobs.group_by { |j| j[:exitcode] }.transform_values(&:size)
    exit_str = exit_summary.map { |k, v| "Code #{k}: #{v}" }.join("\n")

    {
      count: jobs.size,
      mean_cpu: "#{(cpu_effs.sum / count).round(2)}%",
      mean_mem: "#{(mem_effs.sum / count).round(2)}%",
      med_cpu: "#{calc_median.call(cpu_effs).round(2)}%",
      med_mem: "#{calc_median.call(mem_effs).round(2)}%",
      queue_med: "#{calc_median.call(queuetimes).round(2)}s",
      queue_p95: "#{calc_p95.call(queuetimes).round(2)}s",
      outcomes_str: outcomes_str,
      exit_str: exit_str
    }
  end

  def metrics(results)
    results = results.to_a
    if results.empty?
      puts 'No records found matching query.'
      return
    end

    headers = [
      'Group', 'Count', 'Mean CPU', 'Mean Mem', 'Median CPU',
      'Median Mem', 'Queue Median', '95% Queue', 'Outcomes %', 'Exit Summary'
    ]

    # Helper method to print a formatted TTY::Table
    render_section = lambda do |title, grouped_hash|
      puts "\n=== #{title} ==="

      rows = grouped_hash.map do |group_name, jobs|
        m = calculate_metrics(jobs)
        next unless m

        [
          group_name.to_s,
          m[:count],
          m[:mean_cpu],
          m[:mean_mem],
          m[:med_cpu],
          m[:med_mem],
          m[:queue_med],
          m[:queue_p95],
          m[:outcomes_str],
          m[:exit_str]
        ]
      end.compact

      table = TTY::Table.new(headers, rows)
      puts table.render(:unicode, multiline: true) { |r| r.border.separator = :each_row }
    end

    # 1. Overall Summary
    render_section.call('OVERALL METRICS', { 'Overall' => results })

    # 2. By Partition
    by_partition = results.group_by { |j| j[:partition] || 'Unknown' }
    render_section.call('METRICS BY PARTITION', by_partition)

    # 3. By User
    by_user = results.group_by { |j| j[:user] || 'Unknown' }
    render_section.call('METRICS BY USER', by_user)
  end
end
