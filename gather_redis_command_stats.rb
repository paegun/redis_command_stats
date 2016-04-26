# Usage:
#
# Start collection of count per command in 15 second windows, retaining only
# the last 5 (default) windows:
# ```shell
# REDIS_COMMAND_STATS_COMMAND=start REDIS_STAT_WINDOW_STEP=15s ruby gather_redis_command_stats.rb
# ```
#
# Print collected count per command, for retained windows:
# ```shell
# REDIS_COMMAND_STATS_COMMAND=print ruby gather_redis_command_stats.rb
# ```
#
# Clean collected counts:
# ```shell
# REDIS_COMMAND_STATS_COMMAND=clean ruby gather_redis_command_stats.rb
# ```

# Environment Variables
# MONITOR_REDIS_HOST - host to monitor, default: 127.0.0.1
# MONITOR_REDIS_HOST - port to monitor, default: 6379
# STATS_REDIS_HOST   - host to store stats, default: 127.0.0.1
# STATS_REDIS_HOST   - port to store stats, default: 6379
# REDIS_COMMMANDS_WHITE_LIST - csv list of commands to monitor, default: all
# REDIS_COMMMANDS_BLACK_LIST - csv list of commands to not monitor, default: none
# REDIS_STAT_WINDOW_STEP - window stepping, default: 1hr
# REDIS_STAT_WINDOW_KEEP - number of windows to keep, default: 5

require 'redis'
require 'set'

class RedisCommandStats
    def initialize(opts = {})
        @monitor_redis = opts[:monitor_redis] ||
            create_redis_connection(redis_port: opts[:monitor_redis_port],
                                   redis_host: opts[:monitor_redis_host])
        @stat_redis = opts[:stat_redis] ||
            create_redis_connection(redis_port: opts[:stat_redis_port],
                                    redis_host: opts[:stat_redis_host])

        @line_out = opts[:line_out] || false
        @command_white_list = parse_command_list(opts[:command_white_list])
        @command_black_list = parse_command_list(opts[:command_black_list])
        @window_step = parse_window_step(opts[:window_step] || "1hr")
        @window_keep = (opts[:window_keep] || 5).to_i
    end

    def start
        @monitor_redis.monitor { |line| redis_monitor_cb(line) }
    end

    def stop
        raise 'There is no way to interrupt redis-rb MONITOR, `kill` the process'
    end

    def print
        windows = list_windows
        windows.each { |window| print_command_stats(window) }
    end

    def print_most_recent
        window = list_windows[-1]
        print_command_stats(window)
    end

    def clean
        windows = list_windows
        windows.each { |window|
            key = "stats:redis_commands:#{window}"
            @stat_redis.pipelined {
                @stat_redis.del(key)
                @stat_redis.srem("stats:redis_commands:keys", key)
            }
        }
    end

    private

    def normalize_command(command)
        command.upcase!
        command = strip_quotes(command)
        command
    end

    def strip_quotes(line)
        line = line[1..-1] if line.start_with?("\"")
        line = line[0..-2] if line.end_with?("\"")
        line
    end

    def parse_command_list(line)
        return Set.new() if line.nil?
        line.split(',').each {|command| normalize_command(command) } .to_set
    end

    def parse_window_step(line)
        return if line.nil?
        t = line.to_i
        unit = line[t.to_s.length..-1]
        coefficient_to_s =
            case unit
            when "s", "sec", "second", "seconds" then 1.0
            when "m", "min", "minute", "minutes" then 1.0 * 60.0
            when "h", "hr", "hour", "hours" then 1.0 * 60.0 * 60.0
            when "d", "day", "days" then 1.0 * 60.0 * 60.0 * 24.0
            else raise "invalid window stepping, specify in seconds, i.e. '60s'"
            end
        t * coefficient_to_s
    end

    # from Redis.monitor
    # @yieldparam [String] line timestamp and command that was executed
    def redis_monitor_cb(line)
        command = parse_command(line)
        return if command.nil? or is_command_filtered_out(command)

        redis_monitor_log_line(command) if @line_out
        redis_monitor_record_command_stat(command)
    end

    def parse_command(line)
        return if line == "OK"

        # monitor line is in the format:
        # $timestamp [$db $client_host_port] $command $arg0..argn
        # with the following example:
        # 1461627352.016587 [0 127.0.0.1:61190] "get" "test:food"
        parts = line.split(" ")

        {
            line: line,
            timestamp: parts[0],
            db: parts[1][1..-1].to_i, #<< ltrim the [
            client_host_port: parts[2][0..-2], #<< rtrim the ]
            command: normalize_command(parts[3]),
            args: parts[4..-1].map {|arg| strip_quotes(arg) }
        }
    end

    def redis_monitor_log_line(parsed_command)
        line = parsed_command[:line]
        puts line
    end

    def is_command_filtered_out(parsed_command)
        command = parsed_command[:command]

        return true if !@command_black_list.nil? and
            @command_black_list.member?(command)

        return true if is_command_from_self(parsed_command)

        return true if !@command_white_list.nil? and
            !@command_white_list.empty? and
            !@command_white_list.member?(command)

        false
    end

    def is_command_from_self(parsed_command)
        # command = parsed_command[:command]
        key = parsed_command[:args][0] || ''
        return true if key.start_with?("stats:redis_commands:")
        false
    end

    def redis_monitor_record_command_stat(parsed_command)
        window = current_window
        key = "stats:redis_commands:#{window}"
        element = parsed_command[:command]
        @stat_redis.pipelined {
            @stat_redis.sadd("stats:redis_commands:keys", key)
            @stat_redis.zincrby(key, 1.0, element)
            @stat_redis.expire(key, (@window_step * @window_keep).to_i)
        }
    end

    def current_window
        next_window = @next_window
        window = @current_window

        now = Time.now.utc.to_i
        if next_window.nil?
            window = now
        elsif next_window < now
            window = next_window
        end

        next_window = (window + @window_step).to_i

        if !@current_window.nil? and @current_window != window
            print_command_stats(@current_window)
        end

        @next_window = next_window
        @current_window = window
    end

    def list_windows
        results = @stat_redis.smembers("stats:redis_commands:keys")
        results.map {|key| key.split(':')[-1] }
    end

    def print_command_stats(window)
        key = "stats:redis_commands:#{window}"
        cursor = 0
        while cursor != "0"
            cursor, results = @stat_redis.zscan(key, cursor)
            puts key if results.length > 0
            results.sort { |lhs, rhs|
                lcount = lhs[1]
                rcount = rhs[1]
                rcount <=> lcount
            }.each { |command, count|
                puts "#{command}: #{count}"
            }
        end
    end

    def create_redis_connection(opts = {})
        host = opts[:redis_host] || '127.0.0.1'
        port = opts[:redis_port] || 6379
        Redis.new(:host => host, :port => port)
    end
end

if $0 == __FILE__
    rcs = RedisCommandStats.new(monitor_redis_host: ENV['MONITOR_REDIS_HOST'],
                                monitor_redis_port: ENV['MONITOR_REDIS_PORT'],
                                stat_redis_host: ENV['STAT_REDIS_HOST'],
                                stat_redis_port: ENV['STAT_REDIS_HOST'],
                                command_white_list: ENV['REDIS_COMMMANDS_WHITE_LIST'],
                                command_black_list: ENV['REDIS_COMMMANDS_BLACK_LIST'],
                                window_step: ENV['REDIS_STAT_WINDOW_STEP'],
                                window_keep: ENV['REDIS_STAT_WINDOW_KEEP'])

    case ENV['REDIS_COMMAND_STATS_COMMAND']
    when 'p', 'print' then rcs.print
    when 'c', 'clean' then rcs.clean
    else rcs.start
    end
end
