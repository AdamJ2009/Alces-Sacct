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
      formatted = get_formatted(job)
      payload = get_payload(job, formatted)
      load_to_database(payload)
    end
  end

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

  def format_state(state)
    state.to_s.split(',').map(&:strip).reject(&:empty?)
  end

  def verbose_table(results)
    results.map { |v| verbose_row(v) }
  end

  def clean_table(results)
    results.map do |v|
      [
        v[:job_id], v[:user], v[:partition], v[:state], "#{v[:queuetime]}s",
        "#{v[:totalcpus]}s", "#{v[:cpueff]}%", "#{v[:memeff]}%", v[:exitcode]
      ]
    end
  end

  def get_header(results, verbose)
    first_row = results.first
    headers = first_row.keys
    headers[10] = 'cputime'
    if verbose
      headers = [headers[0], headers[1], headers[2], headers[3], headers[8], headers[10], headers[11], headers[14],
                 headers[15]]
    end
    headers
  end

  def tty_table(results, verbose)
    headers = get_header(results, verbose)
    rows = if verbose
             verbose_table(results)
           else
             clean_table(results)
           end
    table = TTY::Table.new(headers, rows)
    puts table.render(:unicode)
    [headers, rows]
  end

  def calc_median
    lambda do |arr|
      len = arr.length
      return 0.0 if len.zero?

      (arr[(len - 1) / 2] + arr[len / 2]) / 2.0
    end
  end

  def calc_p95
    lambda do |arr|
      return 0.0 if arr.empty?

      rank = (0.95 * arr.length).ceil - 1
      arr[[rank, 0].max]
    end
  end

  def get_simple_metrics(jobs)
    count = jobs.size.to_f

    cpu_effs   = jobs.map { |j| j[:cpueff] || 0.0 }.sort
    mem_effs   = jobs.map { |j| j[:memeff] || 0.0 }.sort
    queuetimes = jobs.map { |j| j[:queuetime] || 0.0 }.sort
    [count, cpu_effs, mem_effs, queuetimes]
  end

  def get_outcomes(jobs, count)
    [format_outcomes(jobs, count), format_exit_summary(jobs)]
  end

  def calculate_metrics(jobs)
    return nil if jobs.empty?

    metrics = get_simple_metrics(jobs)
    outcomes = get_outcomes(jobs, metrics.first)

    build_metrics_hash(jobs.size, metrics, outcomes)
  end

  def build_metrics_hash(size, metrics, outcomes)
    count, cpus, mems, queues = metrics
    mean_and_med_metrics(count, cpus, mems)
      .merge(queue_metrics(queues))
      .merge(count: size, outcomes_str: outcomes[0], exit_str: outcomes[1])
  end

  def format_pct(val)
    "#{val.round(2)}%"
  end

  def format_sec(val)
    "#{val.round(2)}s"
  end

  def build_rows(grouped_hash)
    grouped_hash.filter_map do |group_name, jobs|
      m = calculate_metrics(jobs)
      next unless m

      [
        group_name.to_s, m[:count], m[:mean_cpu], m[:mean_mem], m[:med_cpu],
        m[:med_mem], m[:queue_med], m[:queue_p95], m[:outcomes_str], m[:exit_str]
      ]
    end
  end

  def render_section
    headers = [
      'Group', 'Count', 'Mean CPU', 'Mean Mem', 'Median CPU',
      'Median Mem', 'Queue Median', '95% Queue', 'Outcomes %', 'Exit Summary'
    ]
    lambda do |title, grouped_hash|
      puts "\n=== #{title} ==="
      rows = build_rows(grouped_hash)

      table = TTY::Table.new(headers, rows)
      puts table.render(:unicode, multiline: true) { |r| r.border.separator = :each_row }
    end
  end

  def metrics(results)
    results = results.to_a
    if results.empty?
      puts 'No records found matching query.'
      return
    end
    render_section.call('OVERALL METRICS', { 'Overall' => results })
    by_partition = results.group_by { |j| j[:partition] || 'Unknown' }
    render_section.call('METRICS BY PARTITION', by_partition)
    by_user = results.group_by { |j| j[:user] || 'Unknown' }
    render_section.call('METRICS BY USER', by_user)
  end

  private

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

  def verbose_row(val)
    verbose_identity_fields(val) + verbose_timing_fields(val) + verbose_metrics_fields(val)
  end

  def verbose_identity_fields(val)
    [val[:job_id], val[:user], val[:partition], val[:state]]
  end

  def verbose_timing_fields(val)
    [
      format_timestamp(val[:submit]),
      format_timestamp(val[:start]),
      format_end_time(val[:end]),
      "#{val[:elapsed]}s",
      "#{val[:queuetime]}s"
    ]
  end

  def verbose_metrics_fields(_val)
    [
      val[:alloccpus], "#{val[:totalcpus]}s", "#{val[:cpueff]}%",
      "#{val[:reqmem]}MB", "#{val[:maxrss] / 1024.0}MB", "#{val[:memeff]}%", val[:exitcode]
    ]
  end

  def format_timestamp(time_s)
    Time.at(time_s).utc.iso8601
  end

  def format_end_time(end_time)
    end_time.positive? ? format_timestamp(end_time) : 'RUNNING'
  end

  def format_outcomes(jobs, count)
    state_counts = jobs.group_by { |j| j[:state] }
    outcomes_pct = state_counts.transform_values do |state_jobs|
      ((state_jobs.size / count) * 100).round(2)
    end
    outcomes_pct.map { |k, v| "#{k}: #{v}%" }.join("\n")
  end

  def format_exit_summary(jobs)
    jobs.group_by { |j| j[:exitcode] }
        .transform_values(&:size)
        .map { |k, v| "Code #{k}: #{v}" }
        .join("\n")
  end

  def mean_and_med_metrics(count, cpus, mems)
    {
      mean_cpu: format_pct(cpus.sum / count),
      mean_mem: format_pct(mems.sum / count),
      med_cpu: format_pct(calc_median.call(cpus)),
      med_mem: format_pct(calc_median.call(mems))
    }
  end

  def queue_metrics(queues)
    {
      queue_med: format_sec(calc_median.call(queues)),
      queue_p95: format_sec(calc_p95.call(queues))
    }
  end
end
