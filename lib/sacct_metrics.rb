# frozen_string_literal: true

require 'json'
require_relative 'sacct_cli'

# To get the special metrics from cli
class SacctMetrics
  def initialize
    @db = SacctCli.db
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

  private

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
