# frozen_string_literal: true

require_relative 'lib/sacct_cli'
require 'sequel'

namespace :db do
  desc 'Migrate or setup SQLite database'
  task :migrate do
    db = SacctCli.db

    migration_path = File.expand_path('db/migrations', __dir__)

    if Dir.exist?(migration_path) && !Dir.empty?(migration_path)
      Sequel.extension :migration
      puts "Running migrations on #{SacctCli.settings[:db_path]}..."
      Sequel::Migrator.run(db, migration_path)
      puts 'Migrated successfully!'
    else
      puts 'No migration directory found.'
    end
  end
end
