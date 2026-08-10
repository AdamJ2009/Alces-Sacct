# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'date'
require 'sequel'

# Require the application file AFTER spec_helper
require_relative '../bin/alces_sacct'

RSpec.describe Commands::Report do
  subject(:command) { described_class.new }

  before do
    # 1. Allow fetch_and_store to be called without doing real network/system work
    allow_any_instance_of(SacctCli).to receive(:fetch_and_store)

    # 2. Intercept File.read specifically when SacctCli tries to open 'jobs_last_7days.json'
    #    and force it to read 'testing.json' instead.
    allow(File).to receive(:read).and_call_original # Keep standard File.read working
    allow(File).to receive(:read).with('jobs_last_7days.json').and_return(
      File.read(File.expand_path('fixtures/testing.json', __dir__))
    )

    # 4. Bypass TTY table & metrics formatting to avoid terminal ioctl errors
    allow_any_instance_of(SacctCli).to receive(:tty_table)
      .and_return([%w[JobID User State], [%w[1001 alice COMPLETED]]])
    allow_any_instance_of(SacctCli).to receive(:metrics)
  end

  describe '#call' do
    context 'when default options are passed' do
      it 'runs the real SacctCli parse, database queries, and table rendering using testing.json' do
        expect { command.call }.to output(/=== INDIVIDUAL JOBS TABLE ===/).to_stdout
      end
    end
  end
end
