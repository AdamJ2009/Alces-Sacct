# frozen_string_literal: true

require 'json'
require 'tty-table'
require_relative '../config/application'
require_relative 'sacct_parser'
require_relative 'sacct_metrics'

# Command handler for CLI
class SacctCli
  attr_reader :db

  def initialize
    @parse = SacctParser.new
    @metrics = SacctMetrics.new
  end

  def fetch_and_store(sacct_args = [])
    extra_flags = Array(sacct_args).join(' ')

    cmd = "sacct #{extra_flags} --json > jobs.json"
    puts "Executing: #{cmd}"
    `#{cmd}`
  end

  def parse
    file = File.read('jobs.json')
    data = JSON.parse(file)
    @parse.parse(data)
  end

  def format_state(state)
    state.to_s.split(',').map(&:strip).reject(&:empty?)
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

  def render_section
    headers = ['Group', 'Count', 'Mean CPU', 'Mean Mem', 'Median CPU',
               'Median Mem', 'Queue Median', '95% Queue', 'Outcomes %', 'Exit Summary']
    lambda do |title, grouped_hash|
      puts "\n=== #{title} ==="
      rows = @metrics.build_rows(grouped_hash)

      table = TTY::Table.new(headers, rows)
      puts table.render(:unicode, multiline: true) { |r| r.border.separator = :each_row }
    end
  end

  private

  def verbose_row(val)
    verbose_identity_fields(val) + verbose_timing_fields(val) + verbose_metrics_fields(val)
  end

  def verbose_identity_fields(val)
    [val[:job_id], val[:user], val[:partition], val[:state]]
  end

  def verbose_timing_fields(val)
    [format_timestamp(val[:submit]),
     format_timestamp(val[:start]),
     format_end_time(val[:end]),
     "#{val[:elapsed]}s",
     "#{val[:queuetime]}s"]
  end

  def verbose_metrics_fields(val)
    [val[:alloccpus], "#{val[:totalcpus]}s", "#{val[:cpueff]}%",
     "#{val[:reqmem]}MB", "#{val[:maxrss] / 1024.0}MB", "#{val[:memeff]}%", val[:exitcode]]
  end

  def format_timestamp(time_s)
    Time.at(time_s).utc.iso8601
  end

  def format_end_time(end_time)
    end_time.positive? ? format_timestamp(end_time) : 'RUNNING'
  end

  def get_header(results, verbose)
    first_row = results.first
    headers = first_row.keys
    headers[10] = 'cputime'
    unless verbose
      headers = [headers[0], headers[1], headers[2], headers[3], headers[8], headers[10], headers[11], headers[14],
                 headers[15]]
    end
    headers
  end

  def verbose_table(results)
    results.map { |v| verbose_row(v) }
  end

  def clean_table(results)
    results.map do |v|
      [v[:job_id], v[:user], v[:partition], v[:state], "#{v[:queuetime]}s",
       "#{v[:totalcpus]}s", "#{v[:cpueff]}%", "#{v[:memeff]}%", v[:exitcode]]
    end
  end
end
