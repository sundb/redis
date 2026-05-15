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
    foreach all_drop {no slow fast all timeout} {
        test "diskless $all_drop replicas drop during rdb pipe" {
            # Reset state between subcases. The "timeout" subcase changes
            # repl-timeout transiently; the "all" subcase changes
            # rdb-key-save-delay.
            $master config set repl-timeout 60
            $master config set rdb-key-save-delay 0
            # Make sure stale replicas from the previous iteration (whose
            # processes were killed when their nested start_server scope
            # exited) have been reaped from server.slaves before we start
            # a fresh sync — otherwise repl-diskless-sync-max-replicas can
            # block the new sync, and the rdb child for the new iteration
            # is delayed waiting for the stale ones to be detected via TCP.
            wait_for_condition 100 100 {
                [regexp -all {id=\d+} [$master client list type replica]] == 0
            } else {
                catch {$master client kill type replica}
            }
            set replicas {}
            set replicas_alive {}
            # start one replica that will read the rdb fast, and one that will be slow
            start_server {overrides {save ""}} {
                lappend replicas [srv 0 client]
                lappend replicas_alive [srv 0 client]
                start_server {overrides {save ""}} {
                    lappend replicas [srv 0 client]
                    lappend replicas_alive [srv 0 client]

                    # start replication
                    # it's enough for just one replica to be slow, and have it's write handler enabled
                    # so that the whole rdb generation process is bound to that
                    set loglines [count_log_lines -2]
                    [lindex $replicas 0] config set repl-diskless-load swapdb
                    [lindex $replicas 1] config set repl-diskless-load swapdb
                    if {$all_drop == "all"} {
                        # Keep the RDB child generating data long enough for
                        # both replicas to be killed before the pipe reaches
                        # EOF, so this subcase still covers the last-replica
                        # drop path instead of racing with normal completion.
                        $master config set rdb-key-save-delay 1000
                    }
                    # Throttle replica 0 so the master's writes EAGAIN on it,
                    # installing the per-replica write handler and setting
                    # repl_last_partial_write (the "timeout" subcase needs
                    # this for repl-timeout to fire on slow).
                    # Skip the throttle for the "no" subcase — it tests the
                    # happy path of both replicas finishing, and the
                    # rate-limited pipe (issue #14983) under throttling can
                    # turn this into a multi-minute transfer on CI.
                    if {$all_drop != "no"} {
                        [lindex $replicas 0] config set key-load-delay 300
                    }
                    [lindex $replicas 0] replicaof $master_host $master_port
                    [lindex $replicas 1] replicaof $master_host $master_port

                    # wait for the replicas to start reading the rdb
                    # using the log file since the replica only responds to INFO once in 2mb
                    wait_for_log_messages -1 {"*Loading DB in memory*"} 0 1500 10

                    if {$measure_time} {
                        set master_statfile "/proc/$master_pid/stat"
                        set master_start_metrics [get_cpu_metrics $master_statfile]
                        set start_time [clock seconds]
                    }

                    # For the "timeout" subcase, pause the slow replica IMMEDIATELY
                    # so the master is guaranteed to be mid-transfer when its
                    # writes start to EAGAIN — otherwise on a fast box the master
                    # can finish streaming the entire RDB into the slow replica's
                    # kernel buffer before we get a chance to pause it, leaving
                    # the slave past WAIT_BGSAVE_END so the repl-timeout check in
                    # replicationCron no longer applies.
                    if {$all_drop == "timeout"} {
                        pause_process [srv -1 pid]
                    }

                    # wait a while so that the pipe socket writer will be
                    # blocked on write (since replica 0 is slow to read from the socket)
                    after 500

                    # add some command to be present in the command stream after the rdb.
                    $master incr $all_drop

                    # disconnect replicas depending on the current test.
                    # Use SIGKILL because SIGTERM goes through Redis's signal
                    # handler and graceful shutdown, which can delay master
                    # detection of the dead connection.
                    if {$all_drop == "all" || $all_drop == "fast"} {
                        exec kill -9 [srv 0 pid]
                        set replicas_alive [lreplace $replicas_alive 1 1]
                    }
                    if {$all_drop == "all" || $all_drop == "slow"} {
                        exec kill -9 [srv -1 pid]
                        set replicas_alive [lreplace $replicas_alive 0 0]
                    }
                    # After SIGKILL, wait for the master to actually detect
                    # and free the dead replica(s). On systems where the
                    # killed peer's TCP socket buffer was full, the master's
                    # kernel may not deliver EPOLLOUT/EPOLLHUP quickly (no
                    # ACKs from dead peer → retransmit loop), and we'd be
                    # racing against the master's slow detection.
                    set expected_alive 0
                    if {$all_drop == "no" || $all_drop == "timeout"} {
                        set expected_alive 2
                    } elseif {$all_drop == "slow" || $all_drop == "fast"} {
                        set expected_alive 1
                    }
                    if {$all_drop != "no" && $all_drop != "timeout"} {
                        wait_for_condition 600 100 {
                            [regexp -all {id=\d+} [$master client list type replica]] == $expected_alive
                        } else {
                            # Best-effort: fall through; the wait below will
                            # surface a clearer error.
                        }
                    }
                    if {$all_drop == "timeout"} {
                        # Slow has already been paused above. Now drop the
                        # repl-timeout to 2s and wait for the master to log
                        # the timed-out disconnect. Then restore a generous
                        # repl-timeout: when one replica throttles the
                        # diskless pipe (issue #14983) the OTHER replica's
                        # writes are also partial, so it too has
                        # repl_last_partial_write set and would time out on
                        # the next replicationCron tick — leaving the master
                        # with zero alive replicas and logging "last replica
                        # dropped" instead of the expected "1 replicas still
                        # up".
                        $master config set repl-timeout 2
                        wait_for_log_messages -2 {"*Disconnecting timedout replica (full sync)*"} $loglines 200 100
                        $master config set repl-timeout 60
                    }

                    # wait for rdb child to exit. Very generous budget (600s)
                    # for heavily loaded CI: the diskless pipe is fundamentally
                    # rate-limited by the slowest connected replica (issue
                    # #14983), and under CPU contention a replica's loading
                    # speed can drop dramatically — without ever fully
                    # stalling (so repl-timeout never fires). The transfer
                    # eventually completes; we just need to be patient enough.
                    wait_for_condition 6000 100 {
                        [s -2 rdb_bgsave_in_progress] == 0
                    } else {
                        fail "rdb child didn't terminate"
                    }

                    # make sure we got what we were aiming for, by looking for the message in the log file
                    if {$all_drop == "all"} {
                        wait_for_log_messages -2 {"*Diskless rdb transfer, last replica dropped, killing fork child*"} $loglines 1 1
                    }
                    if {$all_drop == "no"} {
                        wait_for_log_messages -2 {"*Diskless rdb transfer, done reading from pipe, 2 replicas still up*"} $loglines 1 1
                    }
                    if {$all_drop == "slow" || $all_drop == "fast"} {
                        wait_for_log_messages -2 {"*Diskless rdb transfer, done reading from pipe, 1 replicas still up*"} $loglines 1 1
                    }
                    if {$all_drop == "timeout"} {
                        wait_for_log_messages -2 {"*Disconnecting timedout replica (full sync)*"} $loglines 1 1
                        wait_for_log_messages -2 {"*Diskless rdb transfer, done reading from pipe, 1 replicas still up*"} $loglines 1 1
                        # master disconnected the slow replica, remove from array
                        set replicas_alive [lreplace $replicas_alive 0 0]
                        # release it
                        resume_process [srv -1 pid]
                    }

                    # make sure we don't have a busy loop going thought epoll_wait
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
                        if {!$::no_latency && ($all_drop == "all" || $all_drop == "slow" || $all_drop == "timeout")} {
                            assert {$master_utime < 70}
                            assert {$master_stime < 70}
                        }
                        if {!$::no_latency && ($all_drop == "no" || $all_drop == "fast")} {
                            assert {$master_utime < 15}
                            assert {$master_stime < 15}
                        }
                    }

                    # In the "no" case both replicas stay alive through the
                    # full streamed RDB, so on slow TLS runners the final
                    # ONLINE transition can lag behind child exit. Be very
                    # generous (300s per replica) for the same reason we
                    # bumped the rdb-child wait above.
                    set replica_online_wait_tries [expr {$all_drop == "no" ? 3000 : 150}]

                    # verify the data integrity
                    foreach replica $replicas_alive {
                        # Wait that replicas acknowledge they are online so
                        # we are sure that DBSIZE and DEBUG DIGEST will not
                        # fail because of timing issues.
                        wait_for_condition $replica_online_wait_tries 100 {
                            [lindex [$replica role] 3] eq {connected}
                        } else {
                            fail "replicas still not connected after some time"
                        }

                        # Make sure that replicas and master have same
                        # number of keys
                        wait_for_condition 50 100 {
                            [$master dbsize] == [$replica dbsize]
                        } else {
                            fail "Different number of keys between master and replicas after too long time."
                        }

                        # Check digests
                        set digest [$master debug digest]
                        set digest0 [$replica debug digest]
                        assert {$digest ne 0000000000000000000000000000000000000000}
                        assert {$digest eq $digest0}
                    }
                }
            }
        }
    }
}
