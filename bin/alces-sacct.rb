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

    def call(start: nil, end: nil, user: false, partition: '%', state: 'all', csv: nil, verbose: false, **)
      target_user = parse_user_flag(user)

      cli = SacctCli.new
      cli.fetch_and_store # Turn on on offical server
      cli.parse
      db = SacctCli.db

      # Unix time conversion algorithm
      end_date   = binding.local_variable_get(:end)
      start_safe = start ? parse_date!('start', start) : EPOCH_START
      end_safe   = end_date ? parse_date!('end', end_date) : Y2K38_LIMIT

      start_time = [start_safe.to_time.to_i, 0].max # Prevents negative epoch timestamps
      end_time   = end_safe.to_time.to_i

      # Execute raw parameterized query with Sequel
      if state == 'all'
        query = 'SELECT * FROM sacct WHERE start >= ? AND end <= ? AND user LIKE ? AND partition LIKE ?'
        results = db.fetch(query, start_time, end_time, target_user, partition)
      else
        state_list = cli.format_state(state)
        query = 'SELECT * FROM sacct WHERE start >= ? AND end <= ? AND user LIKE ? AND partition LIKE ? AND state IN ?'
        results = db.fetch(query, start_time, end_time, target_user, partition, state_list)
      end

      if results.any?
        puts '=== INDIVIDUAL JOBS TABLE ==='
        headers, rows = cli.tty_table(results, verbose)
        cli.metrics(results)

        if csv && !csv.strip.empty?
          csv_filename = csv_check!(csv)

          CSV.open(csv_filename, 'w') do |csv_out|
            # Write header row
            csv_out << headers

            # Stream each row to disk individually
            rows.each do |row|
              csv_out << row
            end
          end
          puts "Successfully exported report to #{csv_filename}"
        end
      else
        puts 'No records found matching criteria.'
      end
    end

    private

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
