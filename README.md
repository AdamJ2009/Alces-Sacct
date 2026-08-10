Alces-Sacct

Run
```
bin/alces_sacct.rb report ARGV #Runs a live report
bin/alces_sacct.rb read_json JSON #Runs a report on existing json
```


Sub flags on all
```
--csv -c return a csv file
--verbose -v return all values being read
```

Sub flags only on report
```
--json -j Add a custom json file name
-- Allows adding of sacct arguments as an arbitrary argument after it is written

```
Filtering(Argmuments, after --)

```
-S start time
-E end time
-L all clusters
-M selected clusters
-a All users
-u Selected users
-r Partitions
-s states
