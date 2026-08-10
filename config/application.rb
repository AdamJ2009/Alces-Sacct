# frozen_string_literal: true

require 'dotenv/load'
require 'yaml'
require 'sequel'

# Load setttings and set db
class SacctCli
  def self.settings
    @settings ||= begin
      yaml = YAML.load_file('config/settings.yml', symbolize_names: true)
      env = ENV.fetch('RACK_ENV', 'development').to_sym
      yaml[:default].merge(yaml[env] || {})
    end
  end
end
