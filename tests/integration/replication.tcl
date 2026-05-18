#
# Copyright (c) 2009-Present, Redis Ltd.
# All rights reserved.
#
# Copyright (c) 2024-present, Valkey contributors.
# All rights reserved.
#
# Licensed under your choice of (a) the Redis Source Available License 2.0
# (RSALv2); or (b) the Server Side Public License v1 (SSPLv1); or (c) the
# GNU Affero General Public License v3 (AGPLv3).
#
# Portions of this file are available under BSD3 terms; see REDISCONTRIBUTIONS for more information.
#

proc log_file_matches {log pattern} {
    set fp [open $log r]
    set content [read $fp]
    close $fp
    string match $pattern $content
}

# test "diskless no replicas drop during rdb pipe" {
#     start_server {tags {"repl external:skip tsan:skip"} overrides {save ""}} {
#         set master [srv 0 client]
#         $master config set repl-diskless-sync yes
#         $master config set repl-diskless-sync-delay 5
#         $master config set repl-diskless-sync-max-replicas 2
#         set master_host [srv 0 host]
#         set master_port [srv 0 port]
#         set master_pid [srv 0 pid]
#         # Put enough data in the db that the RDB is comfortably larger than the
#         # pipe and socket buffers so the primary can hit the blocked writer path,
#         # but keep it small enough that slow TLS CI runners don't spend minutes
#         # draining an oversized transfer (~40 MB uncompressed).
#         $master debug populate 4000 test 10000
#         $master config set rdbcompression no
#         $master config set repl-rdb-channel no
#         # If running on Linux, we also measure utime/stime to detect possible I/O handling issues
#         set os [catch {exec uname}]
#         set measure_time [expr {$os == "Linux"} ? 1 : 0]

#         set replicas {}
#         set replicas_alive {}
#         # start one replica that will read the rdb fast, and one that will be slow
#         start_server {overrides {save ""}} {
#             lappend replicas [srv 0 client]
#             lappend replicas_alive [srv 0 client]
#             start_server {overrides {save ""}} {
#                 lappend replicas [srv 0 client]
#                 lappend replicas_alive [srv 0 client]

#                 # start replication. Both replicas finish normally; no kills.
#                 # No throttle here — the rate-limited diskless pipe (issue
#                 # #14983) under throttling can turn the happy-path transfer
#                 # into a multi-minute run on CI, and this subcase doesn't
#                 # need to exercise the pipe-stall path.
#                 set loglines [count_log_lines -2]
#                 [lindex $replicas 0] config set repl-diskless-load swapdb
#                 [lindex $replicas 1] config set repl-diskless-load swapdb
#                 [lindex $replicas 0] replicaof $master_host $master_port
#                 [lindex $replicas 1] replicaof $master_host $master_port

#                 # wait for the replicas to start reading the rdb
#                 # using the log file since the replica only responds to INFO once in 2mb
#                 wait_for_log_messages -1 {"*Loading DB in memory*"} 0 1500 10

#                 if {$measure_time} {
#                     set master_statfile "/proc/$master_pid/stat"
#                     set master_start_metrics [get_cpu_metrics $master_statfile]
#                     set start_time [clock seconds]
#                 }

#                 after 500
#                 # add some command to be present in the command stream after the rdb.
#                 $master incr no

#                 # wait for rdb child to exit. Generous budget for heavily
#                 # loaded CI; successful runs exit early.
#                 wait_for_condition 6000 100 {
#                     [s -2 rdb_bgsave_in_progress] == 0
#                 } else {
#                     fail "rdb child didn't terminate"
#                 }

#                 wait_for_log_messages -2 {"*Diskless rdb transfer, done reading from pipe, 2 replicas still up*"} $loglines 1 1

#                 # make sure we don't have a busy loop going through epoll_wait
#                 if {$measure_time} {
#                     set master_end_metrics [get_cpu_metrics $master_statfile]
#                     set time_elapsed [expr {[clock seconds]-$start_time}]
#                     set master_cpu [compute_cpu_usage $master_start_metrics $master_end_metrics]
#                     set master_utime [lindex $master_cpu 0]
#                     set master_stime [lindex $master_cpu 1]
#                     if {$::verbose} {
#                         puts "elapsed: $time_elapsed"
#                         puts "master utime: $master_utime"
#                         puts "master stime: $master_stime"
#                     }
#                     if {!$::no_latency} {
#                         assert {$master_utime < 15}
#                         assert {$master_stime < 15}
#                     }
#                 }

#                 # verify the data integrity. Both replicas are alive and
#                 # must reach ONLINE; on slow runners the transition can
#                 # lag, so be very generous (300s per replica).
#                 foreach replica $replicas_alive {
#                     wait_for_condition 3000 100 {
#                         [lindex [$replica role] 3] eq {connected}
#                     } else {
#                         fail "replicas still not connected after some time"
#                     }
#                     wait_for_condition 50 100 {
#                         [$master dbsize] == [$replica dbsize]
#                     } else {
#                         fail "Different number of keys between master and replicas after too long time."
#                     }
#                     set digest [$master debug digest]
#                     set digest0 [$replica debug digest]
#                     assert {$digest ne 0000000000000000000000000000000000000000}
#                     assert {$digest eq $digest0}
#                 }
#             }
#         }
#     }
# }

# test "diskless slow replicas drop during rdb pipe" {
#     start_server {tags {"repl external:skip tsan:skip"} overrides {save ""}} {
#         set master [srv 0 client]
#         $master config set repl-diskless-sync yes
#         $master config set repl-diskless-sync-delay 5
#         $master config set repl-diskless-sync-max-replicas 2
#         set master_host [srv 0 host]
#         set master_port [srv 0 port]
#         set master_pid [srv 0 pid]
#         # Put enough data in the db that the RDB is comfortably larger than the
#         # pipe and socket buffers so the primary can hit the blocked writer path,
#         # but keep it small enough that slow TLS CI runners don't spend minutes
#         # draining an oversized transfer (~40 MB uncompressed).
#         $master debug populate 4000 test 10000
#         $master config set rdbcompression no
#         $master config set repl-rdb-channel no
#         # If running on Linux, we also measure utime/stime to detect possible I/O handling issues
#         set os [catch {exec uname}]
#         set measure_time [expr {$os == "Linux"} ? 1 : 0]

#         set replicas {}
#         set replicas_alive {}
#         # start one replica that will read the rdb fast, and one that will be slow
#         start_server {overrides {save ""}} {
#             lappend replicas [srv 0 client]
#             lappend replicas_alive [srv 0 client]
#             start_server {overrides {save ""}} {
#                 lappend replicas [srv 0 client]
#                 lappend replicas_alive [srv 0 client]

#                 # start replication
#                 # it's enough for just one replica to be slow, and have it's write handler enabled
#                 # so that the whole rdb generation process is bound to that
#                 set loglines [count_log_lines -2]
#                 [lindex $replicas 0] config set repl-diskless-load swapdb
#                 [lindex $replicas 1] config set repl-diskless-load swapdb
#                 # Throttle replica 0 so the master's writes EAGAIN on it,
#                 # installing the per-replica write handler and setting
#                 # repl_last_partial_write — that's the diskless pipe stall
#                 # path we want to exercise before killing the replica.
#                 [lindex $replicas 0] config set key-load-delay 300
#                 [lindex $replicas 0] replicaof $master_host $master_port
#                 [lindex $replicas 1] replicaof $master_host $master_port

#                 wait_for_log_messages -1 {"*Loading DB in memory*"} 0 1500 10

#                 if {$measure_time} {
#                     set master_statfile "/proc/$master_pid/stat"
#                     set master_start_metrics [get_cpu_metrics $master_statfile]
#                     set start_time [clock seconds]
#                 }

#                 # wait a while so that the pipe socket writer will be blocked
#                 # on write (since replica 0 is slow to read from the socket)
#                 after 500
#                 $master incr slow

#                 # SIGKILL the slow replica. Avoid SIGTERM so we don't wait
#                 # for Redis's graceful shutdown path before the master sees
#                 # the dead connection.
#                 exec kill -9 [srv -1 pid]
#                 set replicas_alive [lreplace $replicas_alive 0 0]

#                 # Wait for the master to detect and free the dead replica.
#                 # When the killed peer's TCP receive buffer was full, the
#                 # master's kernel may take a long time to deliver EPOLL
#                 # events for the dead peer (no ACKs → retransmit loop).
#                 wait_for_condition 600 100 {
#                     [regexp -all {id=\d+} [$master client list type replica]] == 1
#                 } else {}

#                 wait_for_condition 6000 100 {
#                     [s -2 rdb_bgsave_in_progress] == 0
#                 } else {
#                     fail "rdb child didn't terminate"
#                 }

#                 wait_for_log_messages -2 {"*Diskless rdb transfer, done reading from pipe, 1 replicas still up*"} $loglines 1 1

#                 if {$measure_time} {
#                     set master_end_metrics [get_cpu_metrics $master_statfile]
#                     set time_elapsed [expr {[clock seconds]-$start_time}]
#                     set master_cpu [compute_cpu_usage $master_start_metrics $master_end_metrics]
#                     set master_utime [lindex $master_cpu 0]
#                     set master_stime [lindex $master_cpu 1]
#                     if {$::verbose} {
#                         puts "elapsed: $time_elapsed"
#                         puts "master utime: $master_utime"
#                         puts "master stime: $master_stime"
#                     }
#                     if {!$::no_latency} {
#                         assert {$master_utime < 70}
#                         assert {$master_stime < 70}
#                     }
#                 }

#                 # verify the data integrity (only the surviving fast replica)
#                 foreach replica $replicas_alive {
#                     wait_for_condition 150 100 {
#                         [lindex [$replica role] 3] eq {connected}
#                     } else {
#                         fail "replicas still not connected after some time"
#                     }
#                     wait_for_condition 50 100 {
#                         [$master dbsize] == [$replica dbsize]
#                     } else {
#                         fail "Different number of keys between master and replicas after too long time."
#                     }
#                     set digest [$master debug digest]
#                     set digest0 [$replica debug digest]
#                     assert {$digest ne 0000000000000000000000000000000000000000}
#                     assert {$digest eq $digest0}
#                 }
#             }
#         }
#     }
# }

# test "diskless fast replicas drop during rdb pipe" {
#     start_server {tags {"repl external:skip tsan:skip"} overrides {save ""}} {
#         set master [srv 0 client]
#         $master config set repl-diskless-sync yes
#         $master config set repl-diskless-sync-delay 5
#         $master config set repl-diskless-sync-max-replicas 2
#         set master_host [srv 0 host]
#         set master_port [srv 0 port]
#         set master_pid [srv 0 pid]
#         # Put enough data in the db that the RDB is comfortably larger than the
#         # pipe and socket buffers so the primary can hit the blocked writer path,
#         # but keep it small enough that slow TLS CI runners don't spend minutes
#         # draining an oversized transfer (~40 MB uncompressed).
#         $master debug populate 4000 test 10000
#         $master config set rdbcompression no
#         $master config set repl-rdb-channel no
#         # If running on Linux, we also measure utime/stime to detect possible I/O handling issues
#         set os [catch {exec uname}]
#         set measure_time [expr {$os == "Linux"} ? 1 : 0]

#         set replicas {}
#         set replicas_alive {}
#         start_server {overrides {save ""}} {
#             lappend replicas [srv 0 client]
#             lappend replicas_alive [srv 0 client]
#             start_server {overrides {save ""}} {
#                 lappend replicas [srv 0 client]
#                 lappend replicas_alive [srv 0 client]

#                 set loglines [count_log_lines -2]
#                 [lindex $replicas 0] config set repl-diskless-load swapdb
#                 [lindex $replicas 1] config set repl-diskless-load swapdb
#                 [lindex $replicas 0] config set key-load-delay 300
#                 [lindex $replicas 0] replicaof $master_host $master_port
#                 [lindex $replicas 1] replicaof $master_host $master_port

#                 wait_for_log_messages -1 {"*Loading DB in memory*"} 0 1500 10

#                 if {$measure_time} {
#                     set master_statfile "/proc/$master_pid/stat"
#                     set master_start_metrics [get_cpu_metrics $master_statfile]
#                     set start_time [clock seconds]
#                 }

#                 after 500
#                 $master incr fast

#                 # SIGKILL the fast replica; the slow one continues.
#                 exec kill -9 [srv 0 pid]
#                 set replicas_alive [lreplace $replicas_alive 1 1]

#                 wait_for_condition 600 100 {
#                     [regexp -all {id=\d+} [$master client list type replica]] == 1
#                 } else {}

#                 wait_for_condition 6000 100 {
#                     [s -2 rdb_bgsave_in_progress] == 0
#                 } else {
#                     fail "rdb child didn't terminate"
#                 }

#                 wait_for_log_messages -2 {"*Diskless rdb transfer, done reading from pipe, 1 replicas still up*"} $loglines 1 1

#                 if {$measure_time} {
#                     set master_end_metrics [get_cpu_metrics $master_statfile]
#                     set time_elapsed [expr {[clock seconds]-$start_time}]
#                     set master_cpu [compute_cpu_usage $master_start_metrics $master_end_metrics]
#                     set master_utime [lindex $master_cpu 0]
#                     set master_stime [lindex $master_cpu 1]
#                     if {$::verbose} {
#                         puts "elapsed: $time_elapsed"
#                         puts "master utime: $master_utime"
#                         puts "master stime: $master_stime"
#                     }
#                     if {!$::no_latency} {
#                         assert {$master_utime < 15}
#                         assert {$master_stime < 15}
#                     }
#                 }

#                 foreach replica $replicas_alive {
#                     wait_for_condition 150 100 {
#                         [lindex [$replica role] 3] eq {connected}
#                     } else {
#                         fail "replicas still not connected after some time"
#                     }
#                     wait_for_condition 50 100 {
#                         [$master dbsize] == [$replica dbsize]
#                     } else {
#                         fail "Different number of keys between master and replicas after too long time."
#                     }
#                     set digest [$master debug digest]
#                     set digest0 [$replica debug digest]
#                     assert {$digest ne 0000000000000000000000000000000000000000}
#                     assert {$digest eq $digest0}
#                 }
#             }
#         }
#     }
# }

test "diskless all replicas drop during rdb pipe" {
    start_server {tags {"repl external:skip tsan:skip"} overrides {save ""}} {
        set master [srv 0 client]
        $master config set repl-diskless-sync yes
        $master config set repl-diskless-sync-delay 5
        $master config set repl-diskless-sync-max-replicas 2
        set master_host [srv 0 host]
        set master_port [srv 0 port]
        set master_pid [srv 0 pid]
        # Put enough data in the db that the RDB is comfortably larger than the
        # pipe and socket buffers so the primary can hit the blocked writer path,
        # but keep it small enough that slow TLS CI runners don't spend minutes
        # draining an oversized transfer (~40 MB uncompressed).
        $master debug populate 4000 test 10000
        $master config set rdbcompression no
        $master config set repl-rdb-channel no
        # If running on Linux, we also measure utime/stime to detect possible I/O handling issues
        set os [catch {exec uname}]
        set measure_time [expr {$os == "Linux"} ? 1 : 0]

        set replicas {}
        set replicas_alive {}
        start_server {overrides {save ""}} {
            lappend replicas [srv 0 client]
            lappend replicas_alive [srv 0 client]
            start_server {overrides {save ""}} {
                lappend replicas [srv 0 client]
                lappend replicas_alive [srv 0 client]

                set loglines [count_log_lines -2]
                [lindex $replicas 0] config set repl-diskless-load swapdb
                [lindex $replicas 1] config set repl-diskless-load swapdb
                # Slow down the master's RDB generation so that the child
                # keeps producing data when both replicas are killed,
                # exercising the last-replica-dropped path instead of
                # racing with normal completion.
                $master config set rdb-key-save-delay 1000
                [lindex $replicas 0] config set key-load-delay 300
                [lindex $replicas 0] replicaof $master_host $master_port
                [lindex $replicas 1] replicaof $master_host $master_port

                wait_for_log_messages -1 {"*Loading DB in memory*"} 0 1500 10

                if {$measure_time} {
                    set master_statfile "/proc/$master_pid/stat"
                    set master_start_metrics [get_cpu_metrics $master_statfile]
                    set start_time [clock seconds]
                }

                after 500
                $master incr all

                # SIGKILL both replicas while the rdb child is still active.
                exec kill -9 [srv 0 pid]
                set replicas_alive [lreplace $replicas_alive 1 1]
                exec kill -9 [srv -1 pid]
                set replicas_alive [lreplace $replicas_alive 0 0]

                wait_for_condition 600 100 {
                    [regexp -all {id=\d+} [$master client list type replica]] == 0
                } else {}

                wait_for_condition 6000 100 {
                    [s -2 rdb_bgsave_in_progress] == 0
                } else {
                    fail "rdb child didn't terminate"
                }

                wait_for_log_messages -2 {"*Diskless rdb transfer, last replica dropped, killing fork child*"} $loglines 1 1

                if {$measure_time} {
                    set master_end_metrics [get_cpu_metrics $master_statfile]
                    set time_elapsed [expr {[clock seconds]-$start_time}]
                    set master_cpu [compute_cpu_usage $master_start_metrics $master_end_metrics]
                    set master_utime [lindex $master_cpu 0]
                    set master_stime [lindex $master_cpu 1]
                    if {$::verbose} {
                        puts "elapsed: $time_elapsed"
                        puts "master utime: $master_utime"
                        puts "master stime: $master_stime"
                    }
                    if {!$::no_latency} {
                        assert {$master_utime < 70}
                        assert {$master_stime < 70}
                    }
                }

                # Reset the master-side throttle so it does not leak into
                # the next test running against this master.
                $master config set rdb-key-save-delay 0

                # No replicas alive; nothing to verify on data integrity.
            }
        }
    }
}

# OK
# test "diskless timeout replicas drop during rdb pipe" {
#     start_server {tags {"repl external:skip tsan:skip"} overrides {save ""}} {
#         set master [srv 0 client]
#         $master config set repl-diskless-sync yes
#         $master config set repl-diskless-sync-delay 5
#         $master config set repl-diskless-sync-max-replicas 2
#         set master_host [srv 0 host]
#         set master_port [srv 0 port]
#         set master_pid [srv 0 pid]
#         # Put enough data in the db that the RDB is comfortably larger than the
#         # pipe and socket buffers so the primary can hit the blocked writer path,
#         # but keep it small enough that slow TLS CI runners don't spend minutes
#         # draining an oversized transfer (~40 MB uncompressed).
#         $master debug populate 4000 test 10000
#         $master config set rdbcompression no
#         $master config set repl-rdb-channel no
#         # If running on Linux, we also measure utime/stime to detect possible I/O handling issues
#         set os [catch {exec uname}]
#         set measure_time [expr {$os == "Linux"} ? 1 : 0]

#         set replicas {}
#         set replicas_alive {}
#         start_server {overrides {save ""}} {
#             lappend replicas [srv 0 client]
#             lappend replicas_alive [srv 0 client]
#             start_server {overrides {save ""}} {
#                 lappend replicas [srv 0 client]
#                 lappend replicas_alive [srv 0 client]

#                 set loglines [count_log_lines -2]
#                 [lindex $replicas 0] config set repl-diskless-load swapdb
#                 [lindex $replicas 1] config set repl-diskless-load swapdb
#                 [lindex $replicas 0] config set key-load-delay 300
#                 [lindex $replicas 0] replicaof $master_host $master_port
#                 [lindex $replicas 1] replicaof $master_host $master_port

#                 wait_for_log_messages -1 {"*Loading DB in memory*"} 0 1500 10

#                 if {$measure_time} {
#                     set master_statfile "/proc/$master_pid/stat"
#                     set master_start_metrics [get_cpu_metrics $master_statfile]
#                     set start_time [clock seconds]
#                 }

#                 # Pause the slow replica IMMEDIATELY (before the 500ms wait)
#                 # so the master is guaranteed to be mid-transfer when its
#                 # writes start to EAGAIN. Otherwise on a fast box the master
#                 # can finish streaming the entire RDB into the slow replica's
#                 # kernel buffer before we get a chance to pause it, leaving
#                 # the slave past WAIT_BGSAVE_END so the repl-timeout check
#                 # in replicationCron no longer applies.
#                 pause_process [srv -1 pid]
#                 after 500
#                 $master incr timeout

#                 # Drop repl-timeout to 2s and wait for the master to log the
#                 # timed-out disconnect for the paused slow replica, then
#                 # restore a generous repl-timeout: when one replica throttles
#                 # the diskless pipe (issue #14983) the OTHER replica's writes
#                 # are also partial, so it too has repl_last_partial_write
#                 # set and would time out on the next replicationCron tick —
#                 # leaving the master with zero alive replicas and logging
#                 # "last replica dropped" instead of the expected
#                 # "1 replicas still up".
#                 $master config set repl-timeout 2
#                 wait_for_log_messages -2 {"*Disconnecting timedout replica (full sync)*"} $loglines 200 100
#                 $master config set repl-timeout 60

#                 wait_for_condition 6000 100 {
#                     [s -2 rdb_bgsave_in_progress] == 0
#                 } else {
#                     fail "rdb child didn't terminate"
#                 }

#                 wait_for_log_messages -2 {"*Disconnecting timedout replica (full sync)*"} $loglines 1 1
#                 wait_for_log_messages -2 {"*Diskless rdb transfer, done reading from pipe, 1 replicas still up*"} $loglines 1 1
#                 # master disconnected the slow replica, remove from array
#                 set replicas_alive [lreplace $replicas_alive 0 0]
#                 # release the paused replica process so its start_server
#                 # cleanup can shut it down.
#                 resume_process [srv -1 pid]

#                 if {$measure_time} {
#                     set master_end_metrics [get_cpu_metrics $master_statfile]
#                     set time_elapsed [expr {[clock seconds]-$start_time}]
#                     set master_cpu [compute_cpu_usage $master_start_metrics $master_end_metrics]
#                     set master_utime [lindex $master_cpu 0]
#                     set master_stime [lindex $master_cpu 1]
#                     if {$::verbose} {
#                         puts "elapsed: $time_elapsed"
#                         puts "master utime: $master_utime"
#                         puts "master stime: $master_stime"
#                     }
#                     if {!$::no_latency} {
#                         assert {$master_utime < 70}
#                         assert {$master_stime < 70}
#                     }
#                 }

#                 foreach replica $replicas_alive {
#                     wait_for_condition 150 100 {
#                         [lindex [$replica role] 3] eq {connected}
#                     } else {
#                         fail "replicas still not connected after some time"
#                     }
#                     wait_for_condition 50 100 {
#                         [$master dbsize] == [$replica dbsize]
#                     } else {
#                         fail "Different number of keys between master and replicas after too long time."
#                     }
#                     set digest [$master debug digest]
#                     set digest0 [$replica debug digest]
#                     assert {$digest ne 0000000000000000000000000000000000000000}
#                     assert {$digest eq $digest0}
#                 }
#             }
#         }
#     }
# }
