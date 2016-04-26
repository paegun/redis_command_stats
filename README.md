# Redis Command Stats
## Status
MVP, gathers count per command per time window

## Dependencies
* Ruby 1.9+, 2.0+ preferred
* redis-rb gem

## Usage
### Gather Stats
```shell
REDIS_COMMAND_STATS_COMMAND=start REDIS_STAT_WINDOW_STEP=15s \
                            ruby gather_redis_command_stats.rb
```
NOTE: kill (^C) to stop monitoring

### Print Stats
```shell
REDIS_COMMAND_STATS_COMMAND=print \
                            ruby gather_redis_command_stats.rb
```

### Clean Stats
```shell
REDIS_COMMAND_STATS_COMMAND=clean \
                            ruby gather_redis_command_stats.rb
```

## Environment Variables

| Key                        | Brief                                           |
|----------------------------|-------------------------------------------------|
| MONITOR_REDIS_HOST         | host to monitor, default: 127.0.0.1             |
| MONITOR_REDIS_HOST         | port to monitor, default: 6379                  |
| STATS_REDIS_HOST           | host to store stats, default: 127.0.0.1         |
| STATS_REDIS_HOST           | port to store stats, default: 6379              |
| REDIS_COMMMANDS_WHITE_LIST | csv list of commands to monitor, default: all   |
| REDIS_COMMMANDS_BLACK_LIST | csv list of commands to not monitor, default: none |
| REDIS_STAT_WINDOW_STEP     | window stepping, default: 1hr                   |
| REDIS_STAT_WINDOW_KEEP     | number of windows to keep, default: 5           |

## Technical Notes
1. The Monitor and Stats storage Redis instances may be the same or different.
1.a. Monitoring is aware of the keys and commands it uses, so ignores its commands.
1.b. Monitoring of several Redis instances, gathering Stats in a single Redis
     instance is supported.
2. A simplified timeseries using Redis is used.
2.a. A Set keyed 'stats:redis_commands:keys' contains the time windows.
2.b. A ZSet keyed 'stats:redis_commands:$window' contains the time window, with
     elements keyed on the upper-cased command with the score being the count.
2.b.i. An Expiry is set on the time window, TTL'ing out after the keep * step
       period has passed.

## License & Copyright
Copyright ©2015-2016 James Gorlick and Basho Technologies, Inc.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.
