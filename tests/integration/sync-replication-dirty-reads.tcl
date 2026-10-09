# The dirty-key dependency tracking that sync-replication-block-reads is built
# on: which key (and which DB) a read records as its dependency, in the
# contexts where that bookkeeping is easy to get wrong -- AOF-loading replay,
# writes from a module thread-safe context, read-only MULTI/EXEC, cross-DB
# isolation, and scripts that SELECT another DB.
#
# No replica is involved anywhere in this file: the gate is driven by
# sync-replication-block-reads local, so the primary's own AOF fsync is the
# durability source. The block-reads behaviour these tests underpin lives in
# sync-replication-block-reads.tcl (primary) and
# sync-replication-block-reads-replica.tcl (replica); the write-side gate lives
# in appendfsync-bgalways.tcl.

# ===========================================================================
# AOF loading dirty-state tests
# ===========================================================================

start_server {tags {"aof external:skip"} overrides {appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0 sync-replication-block-reads local}} {
    test {AOF loading does not buffer replayed writes as dirty} {
        for {set i 0} {$i < 100} {incr i} {
            r set replayed-key $i
        }
        r flushdb async
        r set replayed-key final
        assert_equal {1 0} [r waitaof 1 0 5000]

        restart_server 0 true false

        assert_equal final [r get replayed-key]
        assert_equal 0 [s sync_repl_dirty_keys_count]
        assert_equal 0 [s sync_repl_dirty_dbs_count]
    }
}


# ===========================================================================
# Thread-safe module dirty tracking tests
# ===========================================================================

set thread_module [file normalize tests/modules/blockedclient.so]
start_server [list tags {aof bgalways modules external:skip} overrides [list \
    appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0 loadmodule $thread_module]] {
    foreach operation {{set thread_dirty value} {flushdb async}} {
        test "block-reads: thread-safe module $operation records its dirty dependency" {
            r set thread_dirty before
            assert_equal {1 0} [r waitaof 1 0 5000]
            r config set sync-replication-block-reads local
            set writer [redis_deferring_client]
            set reader [redis_deferring_client]
            r debug aof-flush-force stall 1
            $writer do_bg_rm_call_format ! {*}$operation
            wait_for_condition 100 20 {
                [s sync_repl_pending_clients] == 1
            } else {
                fail "module write reply was not held"
            }
            if {[lindex $operation 0] eq "set"} {
                assert {[dict exists [r debug syncrep dirty-keys] thread_dirty]}
                set expected value
            } else {
                assert {[s sync_repl_dirty_dbs_count] > 0}
                set expected {}
            }
            $reader get thread_dirty
            # The GET is fire-and-forget: wait for the server to read and hold
            # it alongside the module write before sampling the gauge.
            wait_for_condition 100 10 {
                [s sync_repl_pending_clients] == 2
            } else {
                fail "read of the module's dirty dependency was not held"
            }
            r debug aof-flush-force stall 0
            assert_equal OK [$writer read]
            assert_equal $expected [$reader read]
            wait_for_condition 100 20 {
                [s sync_repl_dirty_keys_count] == 0 && [s sync_repl_dirty_dbs_count] == 0
            } else {
                fail "dirty state did not drain"
            }
            r debug aof-flush-force stall 0
            $writer close
            $reader close
            r config set sync-replication-block-reads no
        }
    }
}


# ===========================================================================
# Read-only EXEC dirty-read tests
# ===========================================================================

start_server {tags {"aof bgalways external:skip"} overrides {appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0}} {
    test {block-reads EXEC: wait for every dirty read and hold the whole reply} {
        r set exec_clean clean
        assert_equal {1 0} [r waitaof 1 0 5000]
        r config set sync-replication-block-reads local
        set writer [redis_deferring_client]
        set reader [redis_deferring_client]
        r debug aof-flush-force stall 1
        $writer set exec_first first
        $writer set exec_last last
        wait_for_condition 100 20 {
            [s sync_repl_pending_chunks] == 2
        } else {
            fail "writes did not stay held"
        }

        $reader multi
        assert_equal OK [$reader read]
        # The highest dependency comes first; a later lower offset must
        # not replace it. QUEUED replies do not read the keys yet.
        foreach key {exec_last exec_first exec_clean} {
            $reader get $key
            assert_equal QUEUED [$reader read]
        }
        set hold_before [s sync_repl_hold_depth_count]
        $reader exec
        wait_for_condition 100 10 {
            [s sync_repl_pending_chunks] == 3
        } else {
            fail "EXEC's reply was not held behind the dirty writes"
        }
        assert_equal [expr {$hold_before + 1}] [s sync_repl_hold_depth_count]

        r debug aof-flush-force stall 0
        assert_equal OK [$writer read]
        assert_equal OK [$writer read]
        assert_equal {last first clean} [$reader read]

        # A clean transaction must not inherit the previous EXEC's
        # dependencies, even while another key is dirty.
        r debug aof-flush-force stall 1
        $writer set exec_unrelated value
        wait_for_condition 100 20 {
            [s sync_repl_pending_chunks] == 1
        } else {
            fail "unrelated write did not stay held"
        }
        set hold_before [s sync_repl_hold_depth_count]
        $reader multi
        assert_equal OK [$reader read]
        $reader get exec_clean
        assert_equal QUEUED [$reader read]
        $reader exec
        assert {[reply_arrived_within $reader 1000]}
        assert_equal {clean} [$reader read]
        assert_equal $hold_before [s sync_repl_hold_depth_count]
        r debug aof-flush-force stall 0
        assert_equal OK [$writer read]
        r debug aof-flush-force stall 0
        $writer close
        $reader close
        r config set sync-replication-block-reads no
    }

    test {block-reads EXEC: retain a flushed DB dependency across SELECT} {
        r select 1
        r set exec_flush value
        r select 0
        r set exec_clean clean
        assert_equal {1 0} [r waitaof 1 0 5000]
        r config set sync-replication-block-reads local
        set writer [redis_deferring_client]
        set reader [redis_deferring_client]
        $writer select 1
        assert_equal OK [$writer read]
        r debug aof-flush-force stall 1
        $writer flushdb async
        wait_for_condition 100 20 {
            [s sync_repl_dirty_dbs_count] == 1
        } else {
            fail "FLUSHDB did not mark its DB dirty"
        }

        $reader multi
        assert_equal OK [$reader read]
        foreach command {{select 1} {get exec_flush} {select 0} {get exec_clean}} {
            $reader {*}$command
            assert_equal QUEUED [$reader read]
        }
        $reader exec
        # The EXEC must be held on the flushed DB's dependency before the stall
        # is released; otherwise the values below would also be returned by an
        # EXEC that ran after the FLUSHDB became durable.
        wait_for_condition 100 10 {
            [s sync_repl_pending_chunks] == 2
        } else {
            fail "EXEC's reply was not held on the flushed DB's dependency"
        }
        r debug aof-flush-force stall 0
        assert_equal OK [$writer read]
        assert_equal {OK {} OK clean} [$reader read]
        r debug aof-flush-force stall 0
        $writer close
        $reader close
        r config set sync-replication-block-reads no
    } {OK} {singledb:skip cluster:skip}

    foreach on_expire {no yes} {
        test "block-reads EXEC: lazy expiry honors on-expire=$on_expire" {
            r debug set-active-expire 0
            r config set sync-replication-block-reads local
            r config set sync-replication-block-reads-on-expire $on_expire
            set reader [redis_deferring_client]
            set writer [redis_deferring_client]
            r select 0
            $reader select 0
            assert_equal OK [$reader read]
            $writer select 0
            assert_equal OK [$writer read]
            r set exec_expire_1 value PX 50
            r set exec_expire_2 value PX 50
            r set exec_expire_clean clean
            assert_equal {1 0} [r waitaof 1 0 5000]
            after 60
            r debug aof-flush-force stall 1
            $reader multi
            assert_equal OK [$reader read]
            foreach key {exec_expire_1 exec_expire_2} {
                $reader get $key
                assert_equal QUEUED [$reader read]
            }
            set hold_before [s sync_repl_hold_depth_count]
            $reader exec
            if {$on_expire eq "yes"} {
                # EXEC is pipelined fire-and-forget: wait for its reply to be
                # parked before sampling the gauges.
                wait_for_condition 100 10 {
                    [s sync_repl_pending_chunks] == 1
                } else {
                    fail "EXEC's reply was not held on its expiry dependencies"
                }
                assert_equal [expr {$hold_before + 1}] [s sync_repl_hold_depth_count]
                set dirty [r debug syncrep dirty-keys]
                assert {[dict exists $dirty exec_expire_1] && [dict exists $dirty exec_expire_2]}
            } else {
                assert {[reply_arrived_within $reader 1000]}
                assert_equal $hold_before [s sync_repl_hold_depth_count]
            }
            r debug aof-flush-force stall 0
            assert_equal {{} {}} [$reader read]

            # Reusing the connection must not carry the prior expiry
            # dependency into a later, entirely clean transaction.
            r debug aof-flush-force stall 1
            $writer set exec_expire_unrelated value
            wait_for_condition 100 20 {
                [s sync_repl_pending_chunks] == 1
            } else {
                fail "unrelated write was not held"
            }
            $reader multi
            assert_equal OK [$reader read]
            $reader get exec_expire_clean
            assert_equal QUEUED [$reader read]
            $reader exec
            assert {[reply_arrived_within $reader 1000]}
            assert_equal {clean} [$reader read]
            r debug aof-flush-force stall 0
            assert_equal OK [$writer read]
            r debug aof-flush-force stall 0
            r debug set-active-expire 1
            r config set sync-replication-block-reads-on-expire no
            r config set sync-replication-block-reads no
            $reader close
            $writer close
        }
    }

    test {block-reads EXEC: disabled tracking leaves read-only transactions unheld} {
        r config set sync-replication-block-reads no
        set writer [redis_deferring_client]
        set reader [redis_deferring_client]
        r debug aof-flush-force stall 1
        $writer set exec_off value
        wait_for_condition 100 20 {
            [s sync_repl_pending_chunks] == 1
        } else {
            fail "write did not stay held"
        }
        $reader multi
        assert_equal OK [$reader read]
        $reader get exec_off
        assert_equal QUEUED [$reader read]
        $reader exec
        assert {[reply_arrived_within $reader 1000]}
        assert_equal {value} [$reader read]
        r debug aof-flush-force stall 0
        assert_equal OK [$writer read]
        r debug aof-flush-force stall 0
        $writer close
        $reader close
    }
}


# ===========================================================================
# Per-DB dirty tracking tests
# ===========================================================================

# Dirty-key identity must include the DB ID. With the AOF flush stalled, same-DB
# reads stay held while other DBs remain independently readable.
start_server {tags {"aof bgalways external:skip singledb:skip cluster:skip"} overrides {appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0}} {
    foreach key {same-name "same\x00name"} {
        test "block-reads DB isolation: unacked writes to [string map {\x00 {\\0}} $key]" {
            r debug aof-flush-force stall 0
            r flushall
            r select 1
            r set $key clean
            r select 0
            set writer0 [redis_deferring_client]
            set writer1 [redis_deferring_client]
            set reader0 [redis_deferring_client]
            set reader1 [redis_deferring_client]
            foreach client [list $writer0 $reader0] {
                $client select 0
                assert_equal OK [$client read]
            }
            foreach client [list $writer1 $reader1] {
                $client select 1
                assert_equal OK [$client read]
            }
            r config set sync-replication-block-reads local
            r debug aof-flush-force stall 1

            $writer0 set $key pending0
            wait_for_condition 100 10 {
                [s sync_repl_dirty_keys_count] == 1
            } else {
                fail "DB 0 write was not tracked"
            }
            set offset0 [dict get [r debug syncrep dirty-keys] $key]
            r select 1

            $reader1 get $key
            assert {[reply_arrived_within $reader1 1000]}
            assert_equal clean [$reader1 read]
            assert_equal {} [r debug syncrep dirty-keys]
            $reader1 multi
            assert_equal OK [$reader1 read]
            $reader1 get $key
            assert_equal QUEUED [$reader1 read]
            $reader1 exec
            assert {[reply_arrived_within $reader1 1000]}
            assert_equal {clean} [$reader1 read]

            $reader0 get $key
            $writer1 set $key pending1
            wait_for_condition 100 10 {
                [s sync_repl_dirty_keys_count] == 2
            } else {
                fail "same-named keys in two DBs were merged"
            }
            assert {[dict get [r debug syncrep dirty-keys] $key] > $offset0}
            r select 0
            assert_equal $offset0 [dict get [r debug syncrep dirty-keys] $key]
            $reader1 get $key

            # Releasing the stall releases both DBs and cleans up
            # both composite entries in the offset-ordered index.
            r debug aof-flush-force stall 0
            assert_equal OK [$writer0 read]
            assert_equal OK [$writer1 read]
            assert_equal pending0 [$reader0 read]
            assert_equal pending1 [$reader1 read]
            wait_for_condition 100 10 {
                [s sync_repl_dirty_keys_count] == 0 &&
                [r debug syncrep dirty-ordered-len] == 0
            } else {
                fail "dirty keys did not drain across DBs"
            }

            r debug aof-flush-force stall 0
            r config set sync-replication-block-reads no
            foreach client [list $writer0 $writer1 $reader0 $reader1] { $client close }
        }
    }

    foreach operation {move copy exec eval} {
        test "block-reads DB isolation: $operation records the modified DBs" {
            r flushall
            r select 0
            r set cross-db source
            r select 2
            r set cross-db unrelated
            r select 0
            set writer [redis_deferring_client]
            $writer select 0
            assert_equal OK [$writer read]
            set readers {}
            foreach dbid {0 1 2} {
                set reader [redis_deferring_client]
                $reader select $dbid
                assert_equal OK [$reader read]
                lappend readers $reader
            }
            r config set sync-replication-block-reads local
            r debug aof-flush-force stall 1
            switch $operation {
                move {
                    $writer move cross-db 1
                    set expected {{} source unrelated}
                    set write_reply 1
                }
                copy {
                    $writer copy cross-db cross-db db 1
                    set expected {source source unrelated}
                    set write_reply 1
                }
                exec {
                    $writer multi
                    assert_equal OK [$writer read]
                    foreach command {{set cross-db value0} {select 1} {set cross-db value1} {select 2}} {
                        $writer {*}$command
                        assert_equal QUEUED [$writer read]
                    }
                    $writer exec
                    set expected {value0 value1 unrelated}
                    set write_reply {OK OK OK OK}
                }
                eval {
                    $writer eval {
                        redis.call('SET', 'cross-db', 'value0')
                        redis.call('SELECT', 1)
                        redis.call('SET', 'cross-db', 'value1')
                        redis.call('SELECT', 2)
                        return 'done'
                    } 0
                    set expected {value0 value1 unrelated}
                    set write_reply done
                }
            }
            set dirty_count [expr {$operation eq "copy" ? 1 : 2}]
            wait_for_condition 100 10 {
                [s sync_repl_dirty_keys_count] == $dirty_count
            } else {
                fail "$operation did not record the expected DB/key pairs"
            }
            foreach dbid {0 1 2} reader $readers {
                $reader get cross-db
                if {$dbid == 2 || ($dbid == 0 && $operation eq "copy")} {
                    assert {[reply_arrived_within $reader 1000]}
                }
            }
            r debug aof-flush-force stall 0
            assert_equal $write_reply [$writer read]
            foreach reader $readers value $expected {
                assert_equal $value [$reader read]
            }
            wait_for_condition 100 10 {
                [s sync_repl_dirty_keys_count] == 0 &&
                [r debug syncrep dirty-ordered-len] == 0
            } else {
                fail "$operation dirty state did not drain"
            }

            r debug aof-flush-force stall 0
            r config set sync-replication-block-reads no
            $writer close
            foreach reader $readers { $reader close }
        }
    }

    test {block-reads DB isolation: lazy expiry records the expired DB} {
        r flushall
        r debug set-active-expire 0
        r select 0
        r set same-name clean
        r select 1
        r set same-name expired px 50
        set reader [redis_deferring_client]
        $reader select 1
        assert_equal OK [$reader read]
        after 60
        r config set sync-replication-block-reads local
        r config set sync-replication-block-reads-on-expire yes
        r debug aof-flush-force stall 1
        $reader get same-name
        wait_for_condition 100 10 {
            [s sync_repl_dirty_keys_count] == 1
        } else {
            fail "expiry was not tracked"
        }
        assert {[dict exists [r debug syncrep dirty-keys] same-name]}
        r select 0
        assert_equal {} [r debug syncrep dirty-keys]
        set clean_reader [redis_deferring_client]
        $clean_reader select 0
        assert_equal OK [$clean_reader read]

        $clean_reader get same-name
        assert {[reply_arrived_within $clean_reader 1000]}
        assert_equal clean [$clean_reader read]
        $clean_reader close

        r debug aof-flush-force stall 0
        assert_equal {} [$reader read]

        r debug aof-flush-force stall 0
        # The sub-switch goes off first: it requires the master switch.
        r config set sync-replication-block-reads-on-expire no
        r config set sync-replication-block-reads no
        r debug set-active-expire 1
        $reader close
    }
}


# ===========================================================================
# Script cross-DB dirty-read tests
# ===========================================================================

start_server {tags {"aof bgalways external:skip singledb:skip cluster:skip"} overrides {appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0}} {
    set script {
        redis.call('SELECT', tonumber(ARGV[1]))
        local value = redis.call('GET', KEYS[1])
        redis.call('SELECT', 2)
        return value
    }
    # Preload before stalling fsync: implicit SCRIPT LOAD propagation would
    # otherwise hold the first EVAL reply and hide a missing read dependency.
    set sha [r script load $script]
    r function load {#!lua name=syncrepl_db_reads
        redis.register_function{
            function_name='read_db', flags={'no-writes'},
            callback=function(keys, args)
                redis.call('SELECT', tonumber(args[1]))
                local value = redis.call('GET', keys[1])
                redis.call('SELECT', 2)
                return value
            end
        }
    }

    foreach command [list [list eval_ro $script] [list evalsha_ro $sha] {fcall_ro read_db} \
                          [list eval $script] [list evalsha $sha] {fcall read_db}] {
        foreach in_exec {0 1} {
            test "block-reads script DB: [lindex $command 0], EXEC=$in_exec retains the actual read DB" {
                r select 0
                r set script_key clean
                assert_equal {1 0} [r waitaof 1 0 5000]
                r config set sync-replication-block-reads local
                set writer [redis_deferring_client]
                set reader [redis_deferring_client]
                $writer select 1
                assert_equal OK [$writer read]
                $reader select 0
                assert_equal OK [$reader read]

                r debug aof-flush-force stall 1
                $writer set script_key pending
                wait_for_condition 100 10 {
                    [s sync_repl_dirty_keys_count] == 1
                } else {
                    fail "script's input was not marked dirty"
                }

                if {$in_exec} {
                    $reader multi
                    assert_equal OK [$reader read]
                }
                $reader {*}$command 1 script_key 1
                if {$in_exec} {
                    assert_equal QUEUED [$reader read]
                    # A later clean script must not clear the earlier
                    # script's dependency on this same outer EXEC.
                    $reader {*}$command 1 script_key 0
                    assert_equal QUEUED [$reader read]
                    $reader exec
                }
                # The script's reply must be held on its input's dependency
                # before the stall is released, or the values asserted below
                # would also be produced by an unheld read.
                wait_for_condition 100 10 {
                    [s sync_repl_pending_chunks] == 2
                } else {
                    fail "the script's reply was not held on its dirty input"
                }
                r debug aof-flush-force stall 0
                assert_equal OK [$writer read]
                if {$in_exec} {
                    assert_equal {pending clean} [$reader read]
                } else {
                    assert_equal pending [$reader read]
                }

                # Reuse both the connection and script engine while DB 1
                # is dirty again. Reading DB 0 must remain independent.
                r debug aof-flush-force stall 1
                $writer set script_key newer
                wait_for_condition 100 10 {
                    [s sync_repl_dirty_keys_count] == 1
                } else {
                    fail "second write was not marked dirty"
                }
                $reader {*}$command 1 script_key 0
                assert {[reply_arrived_within $reader 1000]}
                assert_equal clean [$reader read]
                r debug aof-flush-force stall 0
                assert_equal OK [$writer read]

                # The outer script's declared key is only its access
                # boundary. A dirty same-named key in the caller's DB must
                # not block a script that actually reads the clean DB 1.
                $writer select 0
                assert_equal OK [$writer read]
                r debug aof-flush-force stall 1
                $writer set script_key caller-dirty
                wait_for_condition 100 10 {
                    [s sync_repl_dirty_keys_count] == 1
                } else {
                    fail "caller DB write was not marked dirty"
                }
                if {$in_exec} {
                    $reader multi
                    assert_equal OK [$reader read]
                }
                $reader {*}$command 1 script_key 1
                if {$in_exec} {
                    assert_equal QUEUED [$reader read]
                    $reader exec
                }
                assert {[reply_arrived_within $reader 1000]}
                if {$in_exec} {
                    assert_equal {newer} [$reader read]
                } else {
                    assert_equal newer [$reader read]
                }
                r debug aof-flush-force stall 0
                assert_equal OK [$writer read]

                r debug aof-flush-force stall 0
                r config set sync-replication-block-reads no
                $writer close
                $reader close
            }
        }
    }

    foreach change {flush expire-untracked expire-tracked} {
        test "block-reads script DB: $change in the selected DB" {
            r select 1
            r debug set-active-expire 0
            if {$change eq "flush"} {
                r set script_key value
            } else {
                r set script_key value px 50
            }
            assert_equal {1 0} [r waitaof 1 0 5000]
            if {$change ne "flush"} { after 60 }
            r select 0
            r config set sync-replication-block-reads local
            r config set sync-replication-block-reads-on-expire [expr {$change eq "expire-tracked" ? "yes" : "no"}]
            set writer [redis_deferring_client]
            set reader [redis_deferring_client]
            $writer select 1
            assert_equal OK [$writer read]
            $reader select 0
            assert_equal OK [$reader read]

            r debug aof-flush-force stall 1
            if {$change eq "flush"} {
                $writer flushdb async
                wait_for_condition 100 10 {
                    [s sync_repl_dirty_dbs_count] == 1
                } else {
                    fail "script's DB was not marked dirty"
                }
            }
            $reader evalsha_ro $sha 1 script_key 1
            if {$change eq "expire-untracked"} {
                assert {[reply_arrived_within $reader 1000]}
            }
            r debug aof-flush-force stall 0
            assert_equal {} [$reader read]
            if {$change eq "flush"} { assert_equal OK [$writer read] }

            r debug aof-flush-force stall 0
            r debug set-active-expire 1
            r config set sync-replication-block-reads-on-expire no
            r config set sync-replication-block-reads no
            $writer close
            $reader close
        }
    }
}
