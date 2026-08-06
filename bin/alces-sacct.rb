#!/usr/bin/env ruby
# frozen_string_literal: true

# This program is NOT y2k38 compliant, it will fail in 2038

require 'bundler/setup'
require 'csv'
require 'date'
require 'dry/cli'
require 'etc'
require_relative '../lib/sacct_cli'

# Unix Epoch: Jan 1, 1970
EPOCH_START = Date.new(1970, 1, 1)

# Y2K38 Limit: Jan 19, 2038 (32-bit signed integer max epoch offset)
Y2K38_LIMIT = Date.new(2038, 1, 19)

# CLI Commands namespace
module Commands
  extend Dry::CLI::Registry

  # Command handler for sacct reports
  class Report < Dry::CLI::Command
    desc 'Report based on flags sent to the cli'
    option :start,     aliases: ['-s'], type: :string, desc: 'Start date (YYYY-MM-DD)'
    option :end,       aliases: ['-e'], type: :string, desc: 'End date (YYYY-MM-DD)'
    option :csv,       aliases: ['-c'], type: :string, desc: 'Output CSV filename'
    option :user,      aliases: ['-u'], type: :boolean, desc: 'Filter by user'
    option :partition, aliases: ['-p'], type: :string, desc: 'Filter by partition'
    option :state,     aliases: ['-S'], type: :string, desc: 'Comma-separated states'
    option :verbose,   aliases: ['-v'], type: :boolean, desc: 'Give all values'

    def call(**opts)
      cli = SacctCli.new
      # cli.fetch_and_store
      cli.parse
      options = clean_inputs(**opts)
      results = fetch_data(cli, options)
      if results.any?
        put_results(cli, results, **opts)
      else
        puts 'No records found matching criteria.'
      end
    end

    private

    def clean_inputs(**opts)
      start_time, end_time = get_time(opts[:start], opts[:end])
      partition = opts[:partition] && !opts[:partition].empty? ? opts[:partition] : '%'
      state = opts[:state] && !opts[:state].empty? ? opts[:state] : 'all'
      target_user = parse_user_flag(opts[:user])
      [start_time, end_time, target_user, partition, state]
    end

    def fetch_data(cli, values)
      db = SacctCli.db
      if values[4] == 'all'
        query = 'SELECT * FROM sacct WHERE start >= ? AND end <= ? AND user LIKE ? AND partition LIKE ?'
        db.fetch(query, values[0], values[1], values[2], values[3])
      else
        state_list = cli.format_state(values[4])
        query = 'SELECT * FROM sacct WHERE start >= ? AND end <= ? AND user LIKE ? AND partition LIKE ? AND state IN ?'
        db.fetch(query, values[0], values[1], values[2], values[3], state_list)
      end
    end

    def get_time(start, end_date)
      start_safe = start ? parse_date!('start', start) : EPOCH_START
      end_safe   = end_date ? parse_date!('end', end_date) : Y2K38_LIMIT

      start_time = [start_safe.to_time.to_i, 0].max # Prevents negative epoch timestamps
      end_time   = end_safe.to_time.to_i
      [start_time, end_time]
    end

    def put_results(cli, results, **opts)
      puts '=== INDIVIDUAL JOBS TABLE ==='
      headers, rows = cli.tty_table(results, opts[:verbose])
      cli.metrics(results)
      csv = opts[:csv]
      return unless csv && !csv.strip.empty?

      write_csv(headers, rows, csv)
    end

    def write_csv(headers, rows, csv)
      csv_filename = csv_check!(csv)
      CSV.open(csv_filename, 'w') do |csv_out|
        csv_out << headers
        rows.each do |row|
          csv_out << row
        end
      end
      puts "Successfully exported report to #{csv_filename}"
    end

    def parse_date!(name, value)
      unless value =~ /^\d{4}-\d{2}-\d{2}$/
        raise ArgumentError, "Invalid format for --#{name}: '#{value}'. Expected YYYY-MM-DD."
      end

      Date.iso8601(value)
    rescue ArgumentError => e
      puts "Error: #{e.message}"
      exit 1
    end

    def csv_check!(filename)
      unless filename =~ /\.csv$/i
        puts "Error: Invalid CSV filename '#{filename}'. Must end with .csv"
        exit 1
      end

      filename
    end

    def parse_user_flag(user_flag_present)
      # Not called at all
      return '%' unless user_flag_present

      # Inspect ARGV to see if a string value followed -u or --user
      user_index = ARGV.index { |arg| ['--user', '-u'].include?(arg) }
      next_arg = user_index ? ARGV[user_index + 1] : nil

      # Called with a string value (and not another option flag)
      if next_arg && !next_arg.start_with?('-')
        next_arg
      else
        Etc.getlogin
      end
    end
  end

  register 'report', Report
end

Dry::CLI.new(Commands).call
