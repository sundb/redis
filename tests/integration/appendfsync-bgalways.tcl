# Tests for `appendfsync bgalways`: the AOF fsync runs in the bio thread and each
# client's reply is held until its data is durably fsynced (fsynced_reploff >=
# the write's woff). See docs/appendfsync-bgalways.md.
#
# Observability: sync_repl_hold_count is a cumulative counter that increments
# every time a reply chunk is enqueued (non-racy), and sync_repl_pending_clients
# is the live count of clients with held replies. WAITAOF is used as a local
# durability oracle (numlocal == 1 iff fsynced_reploff >= the client's offset).

# A deterministic mixed read/write program over a client's own keyspace, so every
# GET reply is predictable and any RESP-stream corruption surfaces on read-back.
proc bg_prog {c ncmds} {
    set prog {}
    array set kv {}
    for {set k 0} {$k < 8} {incr k} {
        set key "bgp:$c:$k"
        set v "v:$c:$k:0"
        set kv($key) $v
        lappend prog [list [list set $key $v] OK]
    }
    set seed [expr {$c * 7919 + 12345}]
    for {set n 0} {$n < $ncmds} {incr n} {
        set seed [expr {($seed * 1103515245 + 12345) & 0x7fffffff}]
        set k [expr {$seed % 8}]
        set key "bgp:$c:$k"
        set seed [expr {($seed * 1103515245 + 12345) & 0x7fffffff}]
        if {($seed % 3) == 0} {
            set v "v:$c:$k:[expr {$n + 1}]"
            set kv($key) $v
            lappend prog [list [list set $key $v] OK]
        } else {
            lappend prog [list [list get $key] $kv($key)]
        }
    }
    return $prog
}

# A parked reply is released from the main thread's beforeSleep path. Keep the
# owning client on the main thread so re-arming its write path cannot touch an
# I/O thread-owned connection event loop.
start_server {tags {"aof bgalways external:skip"} overrides {appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0 io-threads 4}} {
    set r [srv 0 client]

    test {bgalways + io-threads: a parked client stays on main and drains safely} {
        $r set bgk_iot_warm v
        assert_equal [$r waitaof 1 0 5000] {1 0}

        set rd [redis_deferring_client]
        $rd client id
        set rd_id [$rd read]

        $r debug aof-flush-force stall 1
        set before [s sync_repl_hold_count]
        $rd set bgk_iot v1
        wait_for_condition 100 20 {
            [s sync_repl_hold_count] > $before && [s sync_repl_pending_clients] >= 1
        } else {
            $rd close
            $r debug aof-flush-force stall 0
            fail "write was not held under a stalled durable offset"
        }

        wait_for_condition 20 20 {
            [regexp "id=$rd_id .*io-thread=(\[0-9\]+)" [$r client list] -> iothread]
        } else {
            $rd close
            $r debug aof-flush-force stall 0
            fail "could not find the held client in CLIENT LIST"
        }
        assert_equal 0 $iothread

        $r debug aof-flush-force stall 0
        assert_equal {OK} [$rd read]
        $rd close
        wait_for_condition 50 20 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after the write became durable"
        }
        assert_equal v1 [$r get bgk_iot]
    }
}

start_server {tags {"aof bgalways external:skip"} overrides {appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0}} {
    set r [srv 0 client]

    test {bgalways: setup — AOF durability machinery is live} {
        # A write whose reply returned must be durable; this also waits out the
        # initial AOF rewrite so fsynced_reploff != -1.
        $r set warmup 1
        assert_equal [$r waitaof 1 0 5000] {1 0}
    }

    test {bgalways: a write is chunked (held) and then drains; reply delivered} {
        set before [s sync_repl_hold_count]
        set rd [redis_deferring_client]
        $rd set bgk1 v1
        wait_for_condition 100 20 {
            [s sync_repl_hold_count] > $before
        } else {
            $rd close
            fail "bgalways write was not routed through the reply-holding path"
        }
        # It drains: the reply is delivered and pending returns to zero.
        assert_equal [$rd read] OK
        wait_for_condition 50 20 {
            [s sync_repl_pending_clients] == 0
        } else {
            $rd close
            fail "bgalways pending clients did not drain"
        }
        $rd close
        assert_equal [$r get bgk1] v1
    }

    test {bgalways: held reply stays off the socket until fsync advances, then drains} {
        # The load-bearing invariant: a not-yet-durable reply must never reach
        # the client socket. Classic `always` enforces this with the AE_BARRIER
        # (read/write socket ordering); bgalways instead parks the reply outside
        # c->reply until fsynced_reploff covers its woff, so no barrier is needed.
        # This proves the bytes really stay off the wire while non-durable.
        $r set bgk_barrier_warm v
        assert_equal [$r waitaof 1 0 5000] {1 0}   ;# fsynced_reploff established

        # Freeze the durable offset so the write's reply must stay held.
        $r debug aof-flush-force stall 1
        set rd [redis_deferring_client]
        set before [s sync_repl_hold_count]
        $rd set bgk_barrier v
        wait_for_condition 100 20 {
            [s sync_repl_hold_count] > $before && [s sync_repl_pending_clients] >= 1
        } else {
            $rd close
            $r debug aof-flush-force stall 0
            fail "write was not held under a stalled durable offset"
        }

        # Poll the writer's socket for 100ms: no bytes may arrive while the
        # write is not yet durable. (Same fileevent/vwait race the sync-rep
        # "Replica paused" test uses.)
        set fd [$rd channel]
        set ::__bg_signal 0
        fileevent $fd readable [list set ::__bg_signal data]
        set timer [after 100 [list set ::__bg_signal timeout]]
        vwait ::__bg_signal
        after cancel $timer
        fileevent $fd readable {}
        if {$::__bg_signal ne "timeout"} {
            $rd close
            $r debug aof-flush-force stall 0
            fail "reply bytes reached the socket before the write was durable"
        }

        # Clearing the stall lets the bio fsync advance fsynced_reploff past the
        # write's woff; only then is the reply delivered.
        $r debug aof-flush-force stall 0
        assert_equal [$rd read] OK
        wait_for_condition 50 50 {
            [s sync_repl_pending_clients] == 0
        } else {
            $rd close
            fail "held reply did not drain after clearing the stall"
        }
        $rd close
        assert_equal [$r get bgk_barrier] v
    }

    test {bgalways: held reply is released promptly with no other traffic} {
        # The bio-completion wakeup releases the reply as soon as the fsync lands
        # rather than waiting for the next cron tick. Generous bound — this just
        # proves there is no multi-second / never-woken hang.
        $r set bgk_warm v
        set rd [redis_deferring_client]
        set t0 [clock milliseconds]
        $rd set bgk_prompt v
        assert_equal [$rd read] OK
        set dt [expr {[clock milliseconds] - $t0}]
        $rd close
        assert {$dt < 500}
    }

    test {bgalways: reads are fast by default (not chunked)} {
        $r set bgk_r v
        set before [s sync_repl_hold_count]
        $r get bgk_r
        $r get warmup
        assert_equal [s sync_repl_hold_count] $before
    }

    test {bgalways: a write is durable before its reply returns} {
        $r set bgk_dur v
        # Reply already returned above, so the local copy must already be fsynced.
        assert_equal [$r waitaof 1 0 0] {1 0}
    }

    test {bgalways: appendonly off => writes are not chunked and never hang} {
        $r config set appendonly no
        set before [s sync_repl_hold_count]
        set rd [redis_deferring_client]
        $rd set bgk_noaof v
        assert_equal [$rd read] OK
        $rd close
        assert_equal [s sync_repl_hold_count] $before
        $r config set appendonly yes
        assert_equal [$r waitaof 1 0 5000] {1 0}
    }

    # aofRefreshFsyncedReploff() only advances fsynced_reploff once aof_state is
    # back to AOF_ON, so while a background AOFRW (triggered here by re-enabling
    # appendonly on a running server, via startAppendOnly ->
    # rewriteAppendOnlyFileBackground) is in AOF_WAIT_REWRITE, fsynced_reploff
    # must be pinned at -1 -- the sentinel syncReplWaitLocalAof() checks to
    # suppress gating -- or every write issued during the rewrite would sit
    # below any write's offset and get held until the whole rewrite finishes,
    # contradicting docs/appendfsync-bgalways.md's "gating is suppressed for
    # the whole rewrite".
    test {bgalways: gating is suppressed for the whole initial AOF rewrite} {
        $r config set appendonly no
        # Control the dataset size so the artificial per-key rewrite delay
        # below adds a bounded, predictable amount of time regardless of how
        # many keys earlier tests in this file left behind.
        $r flushall
        $r set bgk_rw_seed v
        ;# Slow the (forked) rewrite down so we have a reliable window in
        ;# which aof_state is AOF_WAIT_REWRITE to probe.
        $r config set rdb-key-save-delay 500000

        $r config set appendonly yes
        wait_for_condition 100 20 {
            [s aof_rewrite_in_progress] == 1
        } else {
            $r config set rdb-key-save-delay 0
            fail "AOF rewrite did not start"
        }

        set before [s sync_repl_hold_count]
        set rd [redis_deferring_client]
        $rd set bgk_during_rw v
        assert_equal [$rd read] OK
        set hold_delta [expr {[s sync_repl_hold_count] - $before}]
        $rd close

        # If the write's reply was wrongly held (gating not suppressed), $rd
        # read above only returned because it waited out the whole slowed-down
        # rewrite -- by which point aof_rewrite_in_progress has already
        # dropped back to 0, which would otherwise mask the bug as a timing
        # flake. Check the hold counter (unambiguous either way) first.
        if {$hold_delta != 0} {
            $r config set rdb-key-save-delay 0
            fail "write issued during the initial AOF rewrite was held\
                (hold_delta=$hold_delta) instead of having gating suppressed"
        }
        if {[s aof_rewrite_in_progress] != 1} {
            $r config set rdb-key-save-delay 0
            fail "rewrite already finished by the time the write returned;\
                rdb-key-save-delay was not slow enough to exercise the gap"
        }

        $r config set rdb-key-save-delay 0
        wait_for_condition 100 50 {
            [s aof_rewrite_in_progress] == 0
        } else {
            fail "AOF rewrite did not finish"
        }
        assert_equal [$r waitaof 1 0 5000] {1 0}
    }

    test {classic appendfsync always: writes are NOT chunked (stays synchronous)} {
        $r config set appendfsync always
        set before [s sync_repl_hold_count]
        $r set always_k v
        assert_equal [s sync_repl_hold_count] $before
        assert_equal [$r get always_k] v
        $r config set appendfsync bgalways
    }

    test {bgalways: mixed read/write pipeline stays uncorrupted} {
        set nclients 6
        set ncmds 400
        # Unlimited normal-class OBL so held chunks under load can't trip the
        # output-buffer limit and disconnect a client mid-stream.
        set saved_obl [lindex [$r config get client-output-buffer-limit] 1]
        $r config set client-output-buffer-limit "normal 0 0 0"

        set rds {}
        set progs {}
        for {set c 0} {$c < $nclients} {incr c} {
            lappend rds [redis_deferring_client]
            lappend progs [bg_prog $c $ncmds]
        }
        set total [llength [lindex $progs 0]]

        # Round-robin send without reading: keep every pipeline full so the
        # server interleaves overlapping batches under hold/drain churn.
        for {set i 0} {$i < $total} {incr i} {
            for {set c 0} {$c < $nclients} {incr c} {
                [lindex $rds $c] {*}[lindex [lindex $progs $c] $i 0]
            }
        }
        # Read and verify every reply, in order.
        for {set c 0} {$c < $nclients} {incr c} {
            set rd [lindex $rds $c]
            set prog [lindex $progs $c]
            for {set i 0} {$i < $total} {incr i} {
                set step [lindex $prog $i]
                set exp  [lindex $step 1]
                if {[catch {$rd read} got]} {
                    foreach x $rds { catch {$x close} }
                    $r config set client-output-buffer-limit $saved_obl
                    fail "client $c reply #$i for [lindex $step 0]: protocol/read error: $got"
                }
                if {$got ne $exp} {
                    foreach x $rds { catch {$x close} }
                    $r config set client-output-buffer-limit $saved_obl
                    fail "client $c reply #$i for [lindex $step 0]: got <$got> expected <$exp>"
                }
            }
        }
        foreach x $rds { catch {$x close} }
        wait_for_condition 50 100 {
            [s sync_repl_pending_clients] == 0
        } else {
            $r config set client-output-buffer-limit $saved_obl
            fail "pending clients did not drain after pipeline"
        }
        $r config set client-output-buffer-limit $saved_obl
    }

    # A default (SYNC) FLUSHDB/FLUSHALL is internally run as a *blocking ASYNC*
    # flush (flushCommandCommon -> blockClient(BLOCKED_LAZYFREE)); its "+OK" is
    # produced later in the BIO completion callback (unblockClientForAsyncFlush ->
    # addReply), OUTSIDE the call() cycle where chunking happens. It must still be
    # held until the flush is durable, or a crash would resurrect the "flushed"
    # keyspace after the client already saw +OK.
    foreach flushcmd {flushdb flushall} {
        test "bgalways: $flushcmd reply is held until the flush is durable" {
            # Seed a key so the flush actually removes something and therefore
            # propagates (an empty-DB flush would not advance master_repl_offset).
            $r set fk v
            assert_equal [$r waitaof 1 0 5000] {1 0}

            $r debug aof-flush-force stall 1
            set rd [redis_deferring_client]
            set before [s sync_repl_hold_count]
            $rd $flushcmd
            wait_for_condition 100 20 {
                [s sync_repl_pending_clients] == 1 &&
                [s sync_repl_hold_count] > $before
            } else {
                $rd close
                $r debug aof-flush-force stall 0
                fail "$flushcmd did not park a pending chunk"
            }
            # Exactly one chunk: the late reply is chunked in the completion
            # callback, and the call() gate must NOT also park a premature empty
            # placeholder for the same blocking command (a delta of 2 would mean
            # the empty-chunk suppression regressed).
            assert_equal [expr {[s sync_repl_hold_count] - $before}] 1
            assert_equal [s sync_repl_pending_commands] 1

            # The flush took effect locally (another client sees an empty DB)
            # even though the flushing client hasn't received +OK yet.
            assert_equal [$r dbsize] 0

            # Prove the +OK is really held: poll the socket for 100ms and verify
            # no bytes arrive.
            set fd [$rd channel]
            set ::__bg_flush_sig 0
            fileevent $fd readable [list set ::__bg_flush_sig data]
            set timer [after 100 [list set ::__bg_flush_sig timeout]]
            vwait ::__bg_flush_sig
            after cancel $timer
            fileevent $fd readable {}
            if {$::__bg_flush_sig ne "timeout"} {
                $rd close
                $r debug aof-flush-force stall 0
                fail "$flushcmd reply arrived while the flush was not yet durable"
            }

            # Release the stall -> the AOF is written and fsynced -> +OK arrives.
            $r debug aof-flush-force stall 0
            assert_equal {OK} [$rd read]
            $rd close
            wait_for_condition 50 20 {
                [s sync_repl_pending_clients] == 0
            } else {
                fail "pending clients did not drain after the flush became durable"
            }
        }
    }

    # A blocking command (BLPOP et al.) that wakes up on another client's write
    # is reprocessed via unblockClientOnKey (blocked.c), which wraps the
    # reissued call() in its own enterExecutionUnit so call()'s usual
    # syncReplStartCommand/syncReplFinishCommand bracketing is skipped; the
    # reissue's reply must still be held until durable, or a crash after the
    # pop is acked but before it's fsynced would let the client believe it
    # consumed data that the AOF never recorded.
    test {bgalways: a blocked command's reply is held until its pop is durable} {
        $r del bgk_blist
        $r set bgk_blist_warm v
        assert_equal [$r waitaof 1 0 5000] {1 0}

        $r debug aof-flush-force stall 1

        set rd_blpop [redis_deferring_client]
        $rd_blpop blpop bgk_blist 0
        wait_for_condition 100 20 {
            [s blocked_clients] >= 1
        } else {
            $rd_blpop close
            $r debug aof-flush-force stall 0
            fail "BLPOP did not block"
        }

        set rd_lpush [redis_deferring_client]
        set before [s sync_repl_hold_count]
        $rd_lpush lpush bgk_blist v1
        wait_for_condition 100 20 {
            [s sync_repl_pending_clients] == 2 &&
            [s sync_repl_hold_count] - $before == 2
        } else {
            $rd_blpop close
            $rd_lpush close
            $r debug aof-flush-force stall 0
            fail "LPUSH and the woken BLPOP's reissue were not both held\
                (pending_clients=[s sync_repl_pending_clients]\
                hold_delta=[expr {[s sync_repl_hold_count] - $before}])"
        }

        # The pop already happened locally (another client sees the list
        # emptied) even though neither client has received its reply yet.
        assert_equal [$r exists bgk_blist] 0

        # Prove BLPOP's reply is really held: poll its socket for 100ms and
        # verify no bytes arrive while the pop is not yet durable.
        set fd [$rd_blpop channel]
        set ::__bg_blpop_sig 0
        fileevent $fd readable [list set ::__bg_blpop_sig data]
        set timer [after 100 [list set ::__bg_blpop_sig timeout]]
        vwait ::__bg_blpop_sig
        after cancel $timer
        fileevent $fd readable {}
        if {$::__bg_blpop_sig ne "timeout"} {
            $rd_blpop close
            $rd_lpush close
            $r debug aof-flush-force stall 0
            fail "BLPOP reply arrived before its pop was durable"
        }

        # Release the stall -> the pop's AOF write is fsynced -> both replies
        # arrive.
        $r debug aof-flush-force stall 0
        assert_equal {bgk_blist v1} [$rd_blpop read]
        assert_equal 1 [$rd_lpush read]
        $rd_blpop close
        $rd_lpush close
        wait_for_condition 50 20 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after the pop became durable"
        }
    }

    test {bgalways: held client is disconnected on a main-thread AOF error} {
        # A held reply whose data can never become durable must be disconnected,
        # not left to hang forever. A main-thread write /
        # forced-fsync failure sets aof_last_write_status (vs. a bio-thread fsync
        # failure, which sets aof_bio_fsync_status); beforeSleep must honor both.
        $r set bgk_warm2 v
        assert_equal [$r waitaof 1 0 5000] {1 0}

        # Stall the durable offset (no error) so a write stays held.
        $r debug aof-flush-force stall 1
        set rd [redis_deferring_client]
        $rd set bgk_err v
        wait_for_condition 100 20 {
            [s sync_repl_pending_clients] >= 1
        } else {
            $rd close
            $r debug aof-flush-force stall 0
            fail "write was not held under a stalled durable offset"
        }

        # Now inject a main-thread AOF write error: the held reply can never
        # become durable, so beforeSleep must disconnect the client.
        set before_disc [s sync_repl_pending_disconnects]
        $r debug aof-flush-force error 1
        wait_for_condition 100 20 {
            [s sync_repl_pending_disconnects] > $before_disc
        } else {
            $rd close
            $r debug aof-flush-force error 0
            $r debug aof-flush-force stall 0
            fail "held client was not disconnected on a main-thread AOF error"
        }
        # The held client's connection was dropped (deferred read errors / EOF).
        catch {$rd read}
        $rd close

        # New writes are rejected with -MISCONF while in the error state.
        assert_error {*MISCONF*} {$r set should_fail 1}

        # Recover: clearing the flags lets the next flush write & fsync, the
        # error status returns to OK, and durability resumes.
        $r debug aof-flush-force error 0
        $r debug aof-flush-force stall 0
        wait_for_condition 50 20 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after recovery"
        }
        $r set recovered v
        assert_equal [$r waitaof 1 0 5000] {1 0}
    }

    test {bgalways: FLUSHALL blocked in BLOCKED_LAZYFREE is disconnected (not acked) on demotion to replica} {
        # A default (SYNC) FLUSHALL already propagated (forceCommandPropagation
        # runs before blockClientForAsyncFlush() suspends the client) while it
        # sits in BLOCKED_LAZYFREE waiting for the BIO lazyfree completion. If a
        # REPLICAOF demotes this instance to a replica while that client is
        # still blocked, disconnectAllBlockedClients() must not unconditionally
        # answer +OK for a write that disconnectAllSyncRepPendingClients()
        # (called right after, in replicationSetMaster()) is specifically
        # designed to avoid acking.
        $r debug aof-flush-force stall 1

        # Freeing the DB is dominated by object count, not value size, and
        # the BIO thread races the poll below: at 100k keys it finishes in
        # single-digit ms, well under the 20ms poll granularity, so the
        # blocked/pending window is never observed. 500k keys (tiny values)
        # keeps that window comfortably above the poll interval while
        # staying well short of "a million"-key cleanup cost on 32-bit CI
        # runners.
        r debug populate 500000

        set rd [redis_deferring_client]
        set before_disc [s sync_repl_pending_disconnects]
        $rd flushall
        wait_for_condition 200 20 {
            [s lazyfree_pending_objects] > 0 &&
            [s blocked_clients] >= 1
        } else {
            $rd close
            $r debug aof-flush-force stall 0
            fail "FLUSHALL did not block in BLOCKED_LAZYFREE with a pending lazyfree job"
        }

        # Demote to replica while the FLUSHALL client is still blocked. The
        # replicaof handshake itself doesn't need to succeed for
        # replicationSetMaster()'s synchronous demotion bookkeeping to run.
        $r replicaof 127.0.0.1 1

        # The FLUSHALL client must be disconnected, not answered with +OK.
        set got_ok 0
        catch {
            if {[$rd read] eq {OK}} { set got_ok 1 }
        }
        assert_equal 0 $got_ok
        $rd close

        wait_for_condition 100 20 {
            [s sync_repl_pending_disconnects] > $before_disc
        } else {
            fail "FLUSHALL client held on a since-demoted write was not\
                disconnected via disconnectAllSyncRepPendingClients"
        }

        $r debug aof-flush-force stall 0
        $r replicaof no one
        # Reclaiming the DB can take several seconds on slow.
        # This is cleanup, not a latency assertion;
        # allow up to 30 seconds, returning as soon as the BIO job completes.
        wait_for_condition 500 20 {
            [s lazyfree_pending_objects] == 0
        } else {
            fail "lazyfree did not finish draining: [s lazyfree_pending_objects] objects pending"
        }
    }

    test {bgalways: a client held on a not-yet-durable write is disconnected (not acked) by CONFIG SET appendonly no} {
        $r set bgk_cfgoff_warm v
        assert_equal [$r waitaof 1 0 5000] {1 0}

        # aof-flush-force stall makes flushAppendOnlyFile() a no-op
        # unconditionally (even with force=1), so stopAppendOnly()'s own
        # forced flush+fsync below won't actually make this write durable
        # either.
        $r debug aof-flush-force stall 1

        set rd [redis_deferring_client]
        set before_disc [s sync_repl_pending_disconnects]
        $rd set bgk_cfgoff v1
        wait_for_condition 100 20 {
            [s sync_repl_pending_clients] == 1
        } else {
            $rd close
            $r debug aof-flush-force stall 0
            fail "SET did not park a chunk while fsync was stalled"
        }

        # Disabling AOF must not silently release this client's held reply:
        # the write it's waiting on was never actually made durable.
        $r config set appendonly no

        set got_ok 0
        catch {
            if {[$rd read] eq {OK}} { set got_ok 1 }
        }
        assert_equal 0 $got_ok
        $rd close

        wait_for_condition 100 20 {
            [s sync_repl_pending_disconnects] > $before_disc
        } else {
            fail "client held on a write left non-durable by CONFIG SET\
                appendonly no was not disconnected via\
                disconnectAllSyncRepPendingClients"
        }

        $r debug aof-flush-force stall 0
        $r config set appendonly yes
    }

    test {bgalways: a client held on a not-yet-durable write is disconnected (not acked) by CONFIG SET appendfsync away from bgalways} {
        # Switching appendfsync away from bgalways (to everysec/always/no)
        # disarms syncReplWaitLocalAof()'s gate the same way stopAppendOnly()
        # pinning fsynced_reploff to -1 does. Without disconnecting first, the
        # very next drainSyncPendingReplies() would release every still-parked
        # chunk unconditionally, acking a write that was never actually made
        # durable.
        $r set bgk_fsyncoff_warm v
        assert_equal [$r waitaof 1 0 5000] {1 0}

        # Stall the durable offset (no error) so a write stays held.
        $r debug aof-flush-force stall 1

        set rd [redis_deferring_client]
        set before_disc [s sync_repl_pending_disconnects]
        $rd set bgk_fsyncoff v1
        wait_for_condition 100 20 {
            [s sync_repl_pending_clients] == 1
        } else {
            $rd close
            $r debug aof-flush-force stall 0
            fail "SET did not park a chunk while fsync was stalled"
        }

        $r config set appendfsync everysec

        set got_ok 0
        catch {
            if {[$rd read] eq {OK}} { set got_ok 1 }
        }
        assert_equal 0 $got_ok
        $rd close

        wait_for_condition 100 20 {
            [s sync_repl_pending_disconnects] > $before_disc
        } else {
            fail "client held on a write left non-durable by CONFIG SET\
                appendfsync everysec was not disconnected via\
                disconnectAllSyncRepPendingClients"
        }

        $r debug aof-flush-force stall 0
        $r config set appendfsync bgalways
    }

    test {bgalways: a transient forced-fsync failure during BGREWRITEAOF self-heals instead of permanently denying writes} {
        # A classic appendfsync always exits(1) on a synchronous fsync
        # failure rather than continuing degraded, so it never has to
        # self-heal aof_last_write_status from a fsync-only failure.
        # bgalways's forced (synchronous) fsync path -- used at the start of
        # BGREWRITEAOF to flush the current INCR AOF before forking -- is
        # the first mode that can set aof_last_write_status from a fsync-only
        # failure while the write() itself already succeeded (so there's no
        # leftover aof_buf data for the classic retry-on-next-write path to
        # ever see). Without a self-heal keyed off fsynced_reploff actually
        # catching up, this wedges -MISCONF forever even after the disk
        # recovers.
        r set bgk_wedge_warm v
        assert_equal [r waitaof 1 0 5000] {1 0}

        r debug aof-flush-force fsync-error 1
        r bgrewriteaof

        wait_for_condition 50 20 {
            [catch {r set bgk_wedge v1}] == 0 &&
            [s aof_last_write_status] eq {ok}
        } else {
            r debug aof-flush-force fsync-error 0
            fail "aof_last_write_status did not self-heal after the\
                simulated forced-fsync failure -- writes stayed denied"
        }

        r debug aof-flush-force fsync-error 0
        assert_equal {v1} [r get bgk_wedge]
    }

    test {bgalways: FLUSHALL ASYNC doesn't race a zero-copy reply sitting in a parked chunk} {
        # protectClientReplyObjects() duplicates any zero-copy BULK_STR_REF
        # reference still sitting in a client's pending reply before an
        # async FLUSHALL/FLUSHDB frees the underlying object in a bio
        # thread, to avoid the main thread and the bio thread doing a
        # non-atomic decrRefCount on the same object. Under bgalways, that
        # reference can also be sitting in an already-parked
        # c->sync_pending_replies chunk instead of c->reply -- reads get
        # chunked as a woff=0 passthrough purely to preserve RESP ordering
        # behind an earlier held write. If protectClientReplyObjects()
        # doesn't know to look there too, the bio thread frees/decrefs the
        # object while the parked chunk still holds a reference to it,
        # which is later sent to the client -- a use-after-free.
        set bigval [string repeat x 20000]
        r set bgk_uaf_big $bigval
        r set bgk_uaf_warm v
        assert_equal [r waitaof 1 0 5000] {1 0}

        r debug aof-flush-force stall 1

        set rd [redis_deferring_client]
        $rd set bgk_uaf_k1 v1
        wait_for_condition 100 20 {
            [s sync_repl_pending_clients] == 1
        } else {
            $rd close
            r debug aof-flush-force stall 0
            fail "SET did not park a chunk while fsync was stalled"
        }

        # This GET's zero-copy reply gets chunked too (passthrough, to
        # preserve ordering behind the still-parked SET), landing its
        # BULK_STR_REF in c->sync_pending_replies instead of c->reply.
        $rd get bgk_uaf_big
        set before_hold [s sync_repl_hold_count]
        wait_for_condition 100 20 {
            [s sync_repl_hold_count] > $before_hold
        } else {
            $rd close
            r debug aof-flush-force stall 0
            fail "GET's zero-copy reply was not routed through the\
                reply-holding path behind the still-parked SET"
        }

        # Concurrently free the underlying object via an async flush. Its
        # own +OK also propagates a write, so it parks behind the still-held
        # chunks too -- use a deferring client so this doesn't block waiting
        # for a reply that can't arrive until the stall is released below.
        set rd_flush [redis_deferring_client]
        $rd_flush flushall async
        wait_for_condition 100 20 {
            [s lazyfree_pending_objects] == 0
        } else {
            $rd close
            $rd_flush close
            r debug aof-flush-force stall 0
            fail "lazyfree did not finish draining"
        }

        # Release the stall so all parked replies drain and get sent.
        r debug aof-flush-force stall 0
        assert_equal {OK} [$rd read]
        assert_equal $bigval [$rd read]
        $rd close
        assert_equal {OK} [$rd_flush read]
        $rd_flush close

        # The race (if unprotected) corrupts/frees shared object memory --
        # confirm the server is still alive and coherent afterward.
        assert_equal {PONG} [r ping]
        assert_equal {} [r get bgk_uaf_big]
    }

    test {bgalways: memory stats include zero-copy refs parked in a sync_pending_replies chunk} {
        # updateClientUnsharedReplyBytes() (which feeds CLIENT LIST's
        # omem-unshared, INFO's mem_clients_normal_unshared, and MEMORY
        # STATS) only scanned c->buf and c->reply. Under bgalways, a
        # zero-copy GET reply can instead be parked in a chunk on
        # c->sync_pending_replies (passthrough, to preserve ordering behind
        # an earlier held write) -- if that chunk isn't scanned too,
        # deleting the key while the reply sits there makes the client the
        # sole owner of the value without ever counting it as unshared,
        # which throws off maxmemory-clients eviction accounting.
        r set bgk_mem_warm v
        assert_equal [r waitaof 1 0 5000] {1 0}

        set val_size 20000
        r set bgk_mem_big [string repeat v $val_size]

        r debug aof-flush-force stall 1

        set rd [redis_deferring_client]
        $rd client setname bgk_mem_client
        assert_equal {OK} [$rd read]

        set before [s sync_repl_hold_count]
        $rd set bgk_mem_k1 v1
        wait_for_condition 100 20 {
            [s sync_repl_pending_clients] == 1 &&
            [s sync_repl_hold_count] > $before
        } else {
            $rd close
            r debug aof-flush-force stall 0
            fail "SET did not park a chunk while fsync was stalled"
        }

        # This GET's zero-copy reply gets chunked too (passthrough, behind
        # the still-parked SET), landing its BULK_STR_REF in
        # c->sync_pending_replies instead of c->reply.
        set before2 [s sync_repl_hold_count]
        $rd get bgk_mem_big
        wait_for_condition 100 20 {
            [s sync_repl_hold_count] > $before2
        } else {
            $rd close
            r debug aof-flush-force stall 0
            fail "GET's zero-copy reply was not routed through the\
                reply-holding path behind the still-parked SET"
        }

        # DEL is itself a write and would also park behind the stall if
        # issued synchronously on $rd, so fire it from another deferring
        # client. The keyspace mutation happens immediately; only that
        # client's own reply is deferred for durability, so a plain read on
        # a separate, unaffected connection observes the deletion right away.
        set rd_del [redis_deferring_client]
        $rd_del del bgk_mem_big
        wait_for_condition 50 20 {
            [r exists bgk_mem_big] == 0
        } else {
            $rd close
            $rd_del close
            r debug aof-flush-force stall 0
            fail "DEL did not take effect while its own reply was held"
        }

        # bgk_mem_client is now the sole owner of the big value's object,
        # but the reference sits in a parked chunk, not c->reply.
        set omem_unshared 0
        set omem_shared 0
        set omem 0
        wait_for_condition 50 20 {
            [set c [lsearch -inline [split [r client list] "\r\n"] *name=bgk_mem_client*]] ne {} &&
            [regexp {omem-unshared=([0-9]+)} $c - omem_unshared] &&
            [regexp {omem-shared=([0-9]+)} $c - omem_shared] &&
            [regexp {omem=([0-9]+)} $c - omem] &&
            ($omem_unshared >= $val_size || ($omem_shared == 0 && $omem >= $val_size))
        } else {
            $rd close
            $rd_del close
            r debug aof-flush-force stall 0
            fail "omem-unshared did not account for the reply parked in a\
                sync_pending_replies chunk after the key was deleted\
                (omem-unshared=$omem_unshared)"
        }
        if {$omem_shared > 0} {
            # The zero-copy reference survived, so it must be classified as
            # unshared after DEL and included in the global memory statistic.
            assert_morethan_equal $omem_shared $omem_unshared
            set info_mem [r info memory]
            assert {[getInfoProperty $info_mem mem_clients_normal_unshared] >= $val_size}
        } else {
            # With I/O threads the handoff may already have converted the
            # reference into an owned reply block. It is then ordinary omem,
            # not shared/unshared reference memory, but must remain accounted.
            assert_morethan_equal $omem $val_size
        }

        # Release the stall so both parked replies drain.
        r debug aof-flush-force stall 0
        assert_equal {OK} [$rd read]
        assert_equal [string repeat v $val_size] [$rd read]
        $rd close
        assert_equal {1} [$rd_del read]
        $rd_del close

        wait_for_condition 50 20 {
            [s mem_clients_normal_unshared] == 0
        } else {
            fail "mem_clients_normal_unshared did not return to 0 after the\
                parked chunk drained"
        }
    }

    test {bgalways: QUIT does not drop a still-parked reply out from under the client} {
        # clientHasPendingReplies() only looks at c->reply/c->bufpos. Once
        # syncReplFinishCommand() moves a command's reply bytes out into a
        # parked chunk, c->reply/bufpos go back to empty even though the
        # bytes are still sitting unsent. If a CLIENT_CLOSE_AFTER_REPLY
        # command (QUIT, or a protocol error) reaches writeToClient() while
        # that chunk is still parked, it must not be treated as "nothing
        # left to send, close now" -- freeClientAsync()'s eventual
        # freeSyncPendingReplies() discards the chunk's contents without
        # ever sending them.
        r set bgk_quit_warm v
        assert_equal [r waitaof 1 0 5000] {1 0}

        r debug aof-flush-force stall 1

        set rd [redis_deferring_client]
        set before [s sync_repl_hold_count]
        $rd set bgk_quit v1
        $rd quit
        wait_for_condition 100 20 {
            [s sync_repl_hold_count] - $before >= 2
        } else {
            $rd close
            r debug aof-flush-force stall 0
            fail "SET and QUIT's own +OK were not both routed through the\
                reply-holding path (hold_delta=[expr {[s sync_repl_hold_count] - $before}])"
        }

        # Prove the connection is not being torn down early: poll its
        # socket for 150ms and verify neither data nor a close arrives
        # while the fsync is still stalled.
        set fd [$rd channel]
        set ::__bg_quit_sig 0
        fileevent $fd readable [list set ::__bg_quit_sig data]
        set timer [after 150 [list set ::__bg_quit_sig timeout]]
        vwait ::__bg_quit_sig
        after cancel $timer
        fileevent $fd readable {}
        if {$::__bg_quit_sig ne "timeout"} {
            $rd close
            r debug aof-flush-force stall 0
            fail "client was disconnected (or sent data) before its held\
                replies were durable"
        }

        # Release the stall -> both replies actually arrive, in order.
        r debug aof-flush-force stall 0
        assert_equal {OK} [$rd read]
        assert_equal {OK} [$rd read]
        $rd close
    }

    test {bgalways: a stale forced-fsync self-heal offset must not survive a later, unrelated write failure} {
        # aof_force_fsync_fail_offset (added to self-heal the BGALWAYS
        # forced-fsync-only failure -- see the previous BGREWRITEAOF test)
        # is only reset by the handful of places that also clear
        # aof_last_write_status back to C_OK. If a genuinely separate,
        # later write() failure sets aof_last_write_status = C_ERR again
        # without also resetting that stale offset, aofRefreshFsyncedReploff()
        # could wrongly declare the *new* failure resolved the moment
        # fsynced_reploff catches up past the *old* one -- even though the
        # new failure's own bytes are still stuck unwritten. Checking the
        # field directly (DEBUG AOF-FSYNC-FAIL OFFSET) verifies the
        # reset itself deterministically, without depending on real
        # fsync/bio timing to observe it indirectly through
        # aof_last_write_status.
        r set bgk_stale_warm v
        assert_equal [r waitaof 1 0 5000] {1 0}

        # Create a genuine gap: park a write while fsync is stalled, so the
        # offset the simulated failure below captures is strictly ahead of
        # what's currently durable -- otherwise it would self-heal trivially
        # on its own, before this test ever gets to check anything.
        r debug aof-flush-force stall 1
        set rd [redis_deferring_client]
        $rd set bgk_stale v1
        wait_for_condition 100 20 {
            [s sync_repl_pending_clients] == 1
        } else {
            $rd close
            r debug aof-flush-force stall 0
            fail "SET did not park a chunk while fsync was stalled"
        }

        r debug aof-fsync-fail simulate
        assert {[r debug aof-fsync-fail offset] != -1}

        # The still-parked client gets disconnected by the existing
        # AOF-error protection (its held write can't be trusted durable) --
        # expected, and not what this test is checking.
        catch {$rd read}
        $rd close

        # Arm a genuinely separate write failure (Y), strictly after the
        # forced-fsync-only one (X) above, and let the server's own flush
        # retries drive it -- deliberately not using BGREWRITEAOF here,
        # since its unconditional file-close fsync would race a legitimate
        # resolution of X independently of Y, muddying which one actually
        # cleared the offset. The stall from above stays in effect
        # throughout, so nothing else can independently advance
        # fsynced_reploff past X while waiting.
        r debug aof-flush-force error 1
        wait_for_condition 30 100 {
            [r debug aof-fsync-fail offset] eq {-1}
        } else {
            r debug aof-flush-force error 0
            r debug aof-flush-force stall 0
            fail "aof_force_fsync_fail_offset was not reset by the later,\
                unrelated write failure (stayed stale)"
        }

        r debug aof-flush-force error 0
        r debug aof-flush-force stall 0
        wait_for_condition 50 20 {
            [catch {r set bgk_stale2 v2}] == 0
        } else {
            fail "aof_last_write_status did not clear after disarming the\
                simulated write error"
        }
    }

    test {bgalways: a blocked command's timeout reply is routed through reply-holding too} {
        # replyToBlockedClientTimedOut() writes straight into c->reply,
        # entirely outside call(). It doesn't propagate anything itself, so
        # the risk isn't durability -- it's that this reply can bypass the
        # ordering (passthrough) protection every other reply-holding path
        # already gets, since it never calls syncReplStartCommand(). When an
        # earlier command's reply is still parked on the same connection,
        # this timeout reply must also be routed through the chunk
        # machinery (as a woff=0 passthrough) to stay in order behind it,
        # not skip straight into c->reply. BLPOP's timeout clock and the
        # earlier SET's fsync are on entirely independent clocks, so this
        # doesn't need any unusual timing to reproduce.
        r del bgk_order_list
        r set bgk_order_warm v
        assert_equal [r waitaof 1 0 5000] {1 0}

        r debug aof-flush-force stall 1

        set rd [redis_deferring_client]
        $rd set bgk_order v1
        wait_for_condition 100 20 {
            [s sync_repl_pending_clients] == 1
        } else {
            $rd close
            r debug aof-flush-force stall 0
            fail "SET did not park a chunk while fsync was stalled"
        }

        # BLPOP's own 100ms timeout fires independently of the stall. Its
        # reply must get routed through the same chunking path (parking as
        # a second, passthrough chunk on the same client) rather than
        # bypassing it straight into c->reply.
        set before [s sync_repl_hold_count]
        $rd blpop bgk_order_list 0.1
        wait_for_condition 100 20 {
            [s blocked_clients] == 0 &&
            [s sync_repl_hold_count] > $before
        } else {
            $rd close
            r debug aof-flush-force stall 0
            fail "BLPOP's timeout reply was not routed through the\
                reply-holding path (hold_delta=[expr {[s sync_repl_hold_count] - $before}])"
        }

        # Release the stall -> both replies drain/arrive, in the order they
        # were actually produced.
        r debug aof-flush-force stall 0
        assert_equal {OK} [$rd read]
        assert_equal {} [$rd read]
        $rd close
    }

    test {bgalways: WAITAOF's success reply stays in order behind an earlier parked reply} {
        # processClientsWaitingReplicas() writes WAIT/WAITAOF's success reply
        # straight into c->reply once the offset/replica conditions are met,
        # entirely outside call() -- unlike its timeout twin
        # (replyToBlockedClientTimedOut()'s BLOCKED_WAIT/BLOCKED_WAITAOF
        # branches), it didn't bracket this with
        # syncReplBeginCommand/syncReplFinishByOffset. On the same connection,
        # an earlier write's reply can still be parked in a
        # sync_pending_replies chunk (not yet durable) when WAITAOF's local
        # condition (fsynced_reploff) is satisfied -- without the bracket,
        # WAITAOF's reply lands directly in c->reply while the earlier
        # chunk is still queued, and the chunk is only appended to the tail
        # of c->reply once it drains, so the client receives WAITAOF's reply
        # before the write's own reply -- a RESP ordering violation.
        r set bgk_waitaof_warm v
        assert_equal [r waitaof 1 0 5000] {1 0}

        r debug aof-flush-force stall 1

        set rd [redis_deferring_client]
        $rd set bgk_waitaof_order v1
        wait_for_condition 100 20 {
            [s sync_repl_pending_clients] == 1
        } else {
            $rd close
            r debug aof-flush-force stall 0
            fail "SET did not park a chunk while fsync was stalled"
        }

        # WAITAOF blocks on the same connection behind the still-parked SET,
        # waiting for fsynced_reploff to reach its own offset (unchanged by
        # WAITAOF itself, which propagates nothing).
        $rd waitaof 1 0 0
        wait_for_condition 100 20 {
            [s blocked_clients] == 1
        } else {
            $rd close
            r debug aof-flush-force stall 0
            fail "WAITAOF did not block behind the still-parked SET"
        }

        # Releasing the stall lets the fsync complete, which satisfies
        # WAITAOF's local condition and drains SET's chunk around the same
        # event. Replies must arrive in the order they were actually
        # produced: SET's OK first, then WAITAOF's array.
        r debug aof-flush-force stall 0
        assert_equal {OK} [$rd read]
        assert_equal {1 0} [$rd read]
        $rd close
    }
}

# Module clients unblocked via RM_BlockClientOnKeys() reply straight from their
# reply_callback, entirely outside call() (see moduleTryServeClientBlockedOnKey
# in module.c), so they need their own syncReplStartCommand/syncReplFinishByOffset
# bracketing rather than relying on call()'s. blockonkeys.so's FSL.BPOP is a
# ready-made example: its reply_callback pops an element and then calls
# RedisModule_ReplicateVerbatim(), i.e. it propagates a write from inside the
# callback, exactly the case that must be held.
set testmodule [file normalize tests/modules/blockonkeys.so]
start_server [list tags {"aof bgalways modules external:skip"} overrides [list appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0 loadmodule "$testmodule"]] {
    set r [srv 0 client]

    test {bgalways: a module's blocked-on-keys reply is held until its propagated write is durable} {
        $r del bgk_fsl
        $r set bgk_fsl_warm v
        assert_equal [$r waitaof 1 0 5000] {1 0}

        $r debug aof-flush-force stall 1

        set rd_bpop [redis_deferring_client]
        $rd_bpop fsl.bpop bgk_fsl 0
        wait_for_condition 100 20 {
            [s blocked_clients] >= 1
        } else {
            $rd_bpop close
            $r debug aof-flush-force stall 0
            fail "FSL.BPOP did not block"
        }

        set rd_push [redis_deferring_client]
        set before [s sync_repl_hold_count]
        $rd_push fsl.push bgk_fsl 1
        wait_for_condition 100 20 {
            [s sync_repl_pending_clients] == 2 &&
            [s sync_repl_hold_count] - $before == 2
        } else {
            $rd_bpop close
            $rd_push close
            $r debug aof-flush-force stall 0
            fail "FSL.PUSH and the woken FSL.BPOP reply_callback's reply were not\
                both held (pending_clients=[s sync_repl_pending_clients]\
                hold_delta=[expr {[s sync_repl_hold_count] - $before}])"
        }

        # The pop already happened locally even though neither client has
        # received its reply yet.
        assert_equal {} [$r fsl.getall bgk_fsl]

        # Prove FSL.BPOP's reply is really held: poll its socket for 100ms and
        # verify no bytes arrive while the pop is not yet durable.
        set fd [$rd_bpop channel]
        set ::__bg_fslbpop_sig 0
        fileevent $fd readable [list set ::__bg_fslbpop_sig data]
        set timer [after 100 [list set ::__bg_fslbpop_sig timeout]]
        vwait ::__bg_fslbpop_sig
        after cancel $timer
        fileevent $fd readable {}
        if {$::__bg_fslbpop_sig ne "timeout"} {
            $rd_bpop close
            $rd_push close
            $r debug aof-flush-force stall 0
            fail "FSL.BPOP reply arrived before its pop was durable"
        }

        # Release the stall -> the pop's AOF write is fsynced -> both replies
        # arrive.
        $r debug aof-flush-force stall 0
        assert_equal 1 [$rd_bpop read]
        assert_equal {OK} [$rd_push read]
        $rd_bpop close
        $rd_push close
        wait_for_condition 50 20 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after the pop became durable"
        }
    }

    test {bgalways: a module's timeout_callback reply is held until its propagated write is durable} {
        $r del bgk_fsl_to
        $r del bgk_module_timeout_marker
        $r set bgk_fsl_to_warm v
        assert_equal [$r waitaof 1 0 5000] {1 0}

        $r debug aof-flush-force stall 1

        set rd_to [redis_deferring_client]
        set before [s sync_repl_hold_count]
        $rd_to fsl.bpop_to_propagate bgk_fsl_to 100
        wait_for_condition 100 20 {
            [s sync_repl_pending_clients] == 1 &&
            [s sync_repl_hold_count] > $before
        } else {
            $rd_to close
            $r debug aof-flush-force stall 0
            fail "fsl.bpop_to_propagate's timeout reply was not routed through\
                the reply-holding path"
        }

        # The timeout callback's INCR already took effect locally even though
        # the calling client hasn't received its reply yet.
        assert_equal {1} [$r get bgk_module_timeout_marker]

        # Prove the reply is really held: poll its socket for 100ms and
        # verify no bytes arrive while the write is not yet durable.
        set fd [$rd_to channel]
        set ::__bg_to_sig 0
        fileevent $fd readable [list set ::__bg_to_sig data]
        set timer [after 100 [list set ::__bg_to_sig timeout]]
        vwait ::__bg_to_sig
        after cancel $timer
        fileevent $fd readable {}
        if {$::__bg_to_sig ne "timeout"} {
            $rd_to close
            $r debug aof-flush-force stall 0
            fail "timeout_callback's reply arrived while its write was not yet\
                durable"
        }

        # Release the stall -> the write is durable -> the reply arrives.
        $r debug aof-flush-force stall 0
        assert_equal {Request timedout} [$rd_to read]
        $rd_to close
        wait_for_condition 50 20 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after the write became durable"
        }
    }
}

# Modules also reply to a blocked client from a background thread via a
# thread-safe context (RM_GetThreadSafeContext + RM_ReplyWith*), writing into
# a separate fake client (bc->reply_client) instead of through
# bc->reply_callback. moduleHandleBlockedClients() splices that accumulated
# reply into the real client with AddReplyFromClient() -- a distinct code
# path from the reply_callback case above, and one with no callback boundary
# to bracket a "before propagation" offset snapshot around, since the
# background thread's RM_Call (and the RM_ReplyWith*() that follows it) both
# already ran by the time the main thread gets around to this splice.
# blockedclient.so's do_bg_rm_call_format is a ready-made example: its worker
# thread runs RM_Call with the caller-supplied format (so "!" forces
# replication) and then replies via RM_ReplyWithCallReply on the thread-safe
# context, with reply_callback left NULL.
set testmodule2 [file normalize tests/modules/blockedclient.so]
start_server [list tags {"aof bgalways modules external:skip"} overrides [list appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0 loadmodule "$testmodule2"]] {
    set r [srv 0 client]

    test {bgalways: a module's thread-safe-context blocked reply is held until its propagated write is durable} {
        $r del bgk_thrd
        $r set bgk_thrd_warm v
        assert_equal [$r waitaof 1 0 5000] {1 0}

        $r debug aof-flush-force stall 1

        set rd [redis_deferring_client]
        set before [s sync_repl_hold_count]
        $rd do_bg_rm_call_format ! set bgk_thrd v1
        wait_for_condition 100 20 {
            [s sync_repl_pending_clients] == 1 &&
            [s sync_repl_hold_count] > $before
        } else {
            $rd close
            $r debug aof-flush-force stall 0
            fail "do_bg_rm_call_format's reply was not routed through the\
                reply-holding path"
        }

        # The SET already took effect locally even though the calling client
        # hasn't received its reply yet.
        assert_equal {v1} [$r get bgk_thrd]

        # Prove the reply is really held: poll its socket for 100ms and
        # verify no bytes arrive while the write is not yet durable.
        set fd [$rd channel]
        set ::__bg_thrd_sig 0
        fileevent $fd readable [list set ::__bg_thrd_sig data]
        set timer [after 100 [list set ::__bg_thrd_sig timeout]]
        vwait ::__bg_thrd_sig
        after cancel $timer
        fileevent $fd readable {}
        if {$::__bg_thrd_sig ne "timeout"} {
            $rd close
            $r debug aof-flush-force stall 0
            fail "thread-safe-context reply arrived while the write was not\
                yet durable"
        }

        # Release the stall -> the write is durable -> the reply arrives.
        $r debug aof-flush-force stall 0
        assert_equal {OK} [$rd read]
        $rd close
        wait_for_condition 50 20 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after the write became durable"
        }
    }
}
