# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:sacct) do
      Integer :job_id, primary_key: true, null: false
      String :user
      String :partition
      String :state
      Integer :submit
      Integer :start
      Integer :end
      Integer :elapsed
      Double :queuetime
      Integer :alloccpus
      Double :totalcpus
      Double :cpueff
      Double :reqmem
      Double :maxrss
      Double :memeff
      Integer :exitcode
    end
  end
end
