Alces-Sacct

Main command
```
bin/alces_sacct.rb report
```

Commands
```
  alces_sacct.rb read_csv CSV                          # Read existing CSV output
  alces_sacct.rb read_json [JSON]                      # Read existing json sacct output
  alces_sacct.rb report [SACCT_ARGS]                   # Report based on flags sent to the cli
```

Report help
```
Command:
  alces_sacct.rb report

Usage:
  alces_sacct.rb report [SACCT_ARGS]

Description:
  Report based on flags sent to the cli

Arguments:
  SACCT_ARGS                        # Direct flags to pass to sacct

Options:
  --csv=VALUE, -c VALUE             # Output CSV filename
  --[no-]verbose, -v                # Give all values
  --json=VALUE, -j VALUE            # Custom Json File, default jobs.json
  --[no-]no-save, -n, --no, --delete, -d  # Elimates json file after running
```

Read JSON help

```
  alces_sacct.rb read_json

Usage:
  alces_sacct.rb read_json [JSON]

Description:
  Read existing json sacct output

Arguments:
  JSON                              # Path to JSON file

Options:
  --csv=VALUE, -c VALUE             # Output CSV filename
  --[no-]verbose, -v                # Give all values
```

CSV help
```
Command:
  alces_sacct.rb read_csv

Usage:
  alces_sacct.rb read_csv CSV

Description:
  Read existing CSV output

Arguments:
  CSV                               # REQUIRED Path to csv file
```
Useful argument sub flags for alces_sacct.rb report

```
-S start time
-E end time
-L all clusters
-M selected clusters
-a All users
-u Selected users
-r Partitions
-s states
