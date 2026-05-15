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
            # Use a modest repl-timeout (not the default 60s) so that when a
            # slow/killed replica leaves the master with a full socket buffer
            # the kernel can't drain (no ACKs from dead peer), the fallback
            # disconnect in replicationCron fires within a few seconds rather
            # than blowing the test budget. The "timeout" subcase sets its
            # own short value transiently.
            $master config set repl-timeout 10
            $master config set rdb-key-save-delay 0
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

                    # Pause the slow replica to deterministically stall the
                    # master's pipe-read handler on a blocked write to that
                    # replica (rdbPipeReadHandler installs a per-replica write
                    # handler and disables pipe read until all writes drain).
                    # This decouples the test from real-time key-load-delay
                    # throttling which is flaky on slow/TLS CI runners due to
                    # issue #14983 (one slow replica throttles the whole pipe).
                    # In "all" the master generates the RDB slowly via
                    # rdb-key-save-delay, so pausing is unnecessary (and we
                    # want to kill the replica anyway).
                    # "no" tests the happy path (both replicas complete) and
                    # does not need an engineered pipe stall — pausing the
                    # slow replica there only adds post-resume drain time and
                    # makes the final "replica online" wait flaky.
                    # "all" generates the RDB slowly via rdb-key-save-delay,
                    # so pausing is unnecessary.
                    set slow_paused 0
                    if {$all_drop != "all" && $all_drop != "no"} {
                        pause_process [srv -1 pid]
                        set slow_paused 1
                    }
                    after 500

                    # add some command to be present in the command stream after the rdb.
                    $master incr $all_drop

                    # disconnect replicas depending on the current test.
                    # Always use SIGKILL: SIGTERM goes through Redis's signal
                    # handler and graceful shutdown, which can delay master
                    # detection of the dead connection. SIGKILL also works on
                    # a SIGSTOPped process (the slow replica may be paused),
                    # whereas SIGTERM would queue and be ignored.
                    if {$all_drop == "all" || $all_drop == "fast"} {
                        exec kill -9 [srv 0 pid]
                        set replicas_alive [lreplace $replicas_alive 1 1]
                    }
                    if {$all_drop == "all" || $all_drop == "slow"} {
                        exec kill -9 [srv -1 pid]
                        set replicas_alive [lreplace $replicas_alive 0 0]
                        set slow_paused 0
                    }
                    # For "fast"/"slow" subcases, let the master detect the
                    # dead replica (NULLing its slot in rdb_pipe_conns) BEFORE
                    # we proceed. Otherwise pipe EOF can arrive while the
                    # dead replica's slot is still set, and the master logs
                    # the wrong "N replicas still up" count.
                    if {$all_drop == "fast" || $all_drop == "slow"} {
                        wait_for_condition 200 50 {
                            [regexp -all {state=wait_bgsave} [$master info replication]] <= 1
                        } else {
                            # Best-effort: fall through and let the log-message
                            # check below surface the issue with more context.
                        }
                    }
                    if {$all_drop == "timeout"} {
                        # Let one replica hit repl-timeout while the slow reader
                        # is paused, then restore a generous timeout so the
                        # remaining replica can finish the streamed RDB.
                        $master config set repl-timeout 2
                        wait_for_log_messages -2 {"*Disconnecting timedout replica (full sync)*"} $loglines 100 100
                        $master config set repl-timeout 10
                    } elseif {$all_drop == "fast" && $slow_paused} {
                        # For "fast" the slow replica (-1) must finish after
                        # the fast one is killed. Resume the slow reader so
                        # the pipe drains and the RDB transfer completes
                        # promptly — no longer rate-limited by socket
                        # backpressure (issue #14983).
                        resume_process [srv -1 pid]
                        set slow_paused 0
                    }

                    # Use a generous budget; successful runs exit early.
                    wait_for_condition 2400 100 {
                        [s -2 rdb_bgsave_in_progress] == 0
                    } else {
                        if {$slow_paused} { resume_process [srv -1 pid] }
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
                    # ONLINE transition can lag behind child exit.
                    set replica_online_wait_tries [expr {$all_drop == "no" ? 600 : 150}]

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
