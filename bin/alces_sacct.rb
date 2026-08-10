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

    option :csv,       aliases: ['-c'], type: :string, desc: 'Output CSV filename'
    option :verbose,   aliases: ['-v'], type: :boolean, desc: 'Give all values'
    option :json,      aliases: ['-j'], type: :string, desc: 'Custom Json File, default jobs.json'
    option :no_save,   aliases: ['-n', '--no', '--delete', '-d'], type: :boolean,
                       desc: 'Elimates json file after running'

    argument :sacct_args, type: :array, required: false, desc: 'Direct flags to pass to sacct'

    def call(sacct_args: [], json: 'jobs.json', no_save: false, **opts)
      cli = SacctCli.new
      json = json_check!(json)
      cli.fetch_and_store(json, sacct_args)
      results = cli.parse(no_save, json)
      if results.any?
        put_results(cli, results, **opts)
      else
        puts 'No records found matching criteria.'
      end
    end

    def read_json_only(json, **opts)
      cli = SacctCli.new
      json = json_check!(json)
      results = cli.parse(false, json)
      if results.any?
        put_results(cli, results, **opts)
      else
        puts 'No records found matching criteria.'
      end
    end

    def put_results(cli, results, **opts)
      puts '=== INDIVIDUAL JOBS TABLE ==='
      headers, rows = cli.tty_table(results, opts[:verbose])
      cli.metrics(results)
      csv = opts[:csv]
      return unless csv && !csv.strip.empty?

      write_csv(headers, rows, csv)
    end

    private

    def json_check!(filename)
      unless filename =~ /\.json$/i
        puts "Error: Invalid json filename '#{filename}'. Must end with .json"
        exit 1
      end
      filename
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

    def csv_check!(filename)
      unless filename =~ /\.csv$/i
        puts "Error: Invalid CSV filename '#{filename}'. Must end with .csv"
        exit 1
      end

      filename
    end
  end

  # Only reads an existing json
  class Read < Dry::CLI::Command
    desc 'Read existing json sacct output'

    argument :json, required: false, desc: 'Path to JSON file'

    option :csv,       aliases: ['-c'], type: :string, desc: 'Output CSV filename'
    option :verbose,   aliases: ['-v'], type: :boolean, desc: 'Give all values'

    def call(json: 'jobs.json', **opts)
      Report.new.read_json_only(json, **opts)
    end
  end

  # Reads an existing csv already created
  class CSVREAD < Dry::CLI::Command
    desc 'Read existing CSV output'

    argument :csv, required: true, desc: 'Path to csv file'

    def call(csv:, **opts)
      cli = SacctCli.new
      cleaned_rows = clean(csv)

      return puts 'CSV file is empty.' if cleaned_rows.empty?

      results = parse_rows(cleaned_rows)

      if results.any?
        opts[:csv] = opts[:csv_out] # Align option key with put_results
        Report.new.put_results(cli, results, **opts)
      else
        puts 'No records found matching criteria.'
      end
    end

    private

    def clean(csv)
      File.foreach(csv).map do |line|
        clean_line = line.gsub(/(\d)[a-zA-Z%]+(?=,|$)/, '\1')
        CSV.parse_line(clean_line)
      end.compact
    end

    def parse_rows(cleaned_rows)
      raw_headers = cleaned_rows.shift.map(&:to_sym)

      cleaned_rows.map do |row|
        row_hash = raw_headers.zip(row).to_h
        build_job_hash(row_hash)
      end
    end

    def parse_time(val)
      return 0 if val.nil? || val.to_s.strip.empty? || val.to_s == 'RUNNING'

      Time.parse(val.to_s).to_i
    rescue ArgumentError
      val.to_i
    end

    def build_job_hash(row_hash)
      identity_fields(row_hash)
        .merge(timestamp_fields(row_hash))
        .merge(metrics_fields(row_hash))
    end

    def identity_fields(row_hash)
      {
        job_id: row_hash[:job_id].to_i,
        user: row_hash[:user].to_s,
        partition: row_hash[:partition].to_s,
        state: row_hash[:state].to_s
      }
    end

    def timestamp_fields(row_hash)
      {
        submit: parse_time(row_hash[:submit]),
        start: parse_time(row_hash[:start]),
        end: parse_time(row_hash[:end]),
        elapsed: row_hash[:elapsed].to_i,
        queuetime: row_hash[:queuetime].to_f
      }
    end

    def metrics_fields(row_hash)
      {
        alloccpus: row_hash[:alloccpus].to_i,
        totalcpus: (row_hash[:cputime] || row_hash[:totalcpus]).to_f,
        cpueff: row_hash[:cpueff].to_f,
        reqmem: row_hash[:reqmem].to_f,
        maxrss: row_hash[:maxrss].to_f * 1024.0,
        memeff: row_hash[:memeff].to_f,
        exitcode: row_hash[:exitcode].to_i
      }
    end
  end

  register 'report', Report
  register 'read_json', Read
  register 'read_csv', CSVREAD
end

Dry::CLI.new(Commands).call if $PROGRAM_NAME == __FILE__
