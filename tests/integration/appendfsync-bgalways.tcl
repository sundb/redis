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
        $r debug aof-flush-force-stall 1
        set rd [redis_deferring_client]
        set before [s sync_repl_hold_count]
        $rd set bgk_barrier v
        wait_for_condition 100 20 {
            [s sync_repl_hold_count] > $before && [s sync_repl_pending_clients] >= 1
        } else {
            $rd close
            $r debug aof-flush-force-stall 0
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
            $r debug aof-flush-force-stall 0
            fail "reply bytes reached the socket before the write was durable"
        }

        # Clearing the stall lets the bio fsync advance fsynced_reploff past the
        # write's woff; only then is the reply delivered.
        $r debug aof-flush-force-stall 0
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

            $r debug aof-flush-force-stall 1
            set rd [redis_deferring_client]
            set before [s sync_repl_hold_count]
            $rd $flushcmd
            wait_for_condition 100 20 {
                [s sync_repl_pending_clients] == 1 &&
                [s sync_repl_hold_count] > $before
            } else {
                $rd close
                $r debug aof-flush-force-stall 0
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
                $r debug aof-flush-force-stall 0
                fail "$flushcmd reply arrived while the flush was not yet durable"
            }

            # Release the stall -> the AOF is written and fsynced -> +OK arrives.
            $r debug aof-flush-force-stall 0
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

        $r debug aof-flush-force-stall 1

        set rd_blpop [redis_deferring_client]
        $rd_blpop blpop bgk_blist 0
        wait_for_condition 100 20 {
            [s blocked_clients] >= 1
        } else {
            $rd_blpop close
            $r debug aof-flush-force-stall 0
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
            $r debug aof-flush-force-stall 0
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
            $r debug aof-flush-force-stall 0
            fail "BLPOP reply arrived before its pop was durable"
        }

        # Release the stall -> the pop's AOF write is fsynced -> both replies
        # arrive.
        $r debug aof-flush-force-stall 0
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
        $r debug aof-flush-force-stall 1
        set rd [redis_deferring_client]
        $rd set bgk_err v
        wait_for_condition 100 20 {
            [s sync_repl_pending_clients] >= 1
        } else {
            $rd close
            $r debug aof-flush-force-stall 0
            fail "write was not held under a stalled durable offset"
        }

        # Now inject a main-thread AOF write error: the held reply can never
        # become durable, so beforeSleep must disconnect the client.
        set before_disc [s sync_repl_pending_disconnects]
        $r debug aof-flush-force-error 1
        wait_for_condition 100 20 {
            [s sync_repl_pending_disconnects] > $before_disc
        } else {
            $rd close
            $r debug aof-flush-force-error 0
            $r debug aof-flush-force-stall 0
            fail "held client was not disconnected on a main-thread AOF error"
        }
        # The held client's connection was dropped (deferred read errors / EOF).
        catch {$rd read}
        $rd close

        # New writes are rejected with -MISCONF while in the error state.
        assert_error {*MISCONF*} {$r set should_fail 1}

        # Recover: clearing the flags lets the next flush write & fsync, the
        # error status returns to OK, and durability resumes.
        $r debug aof-flush-force-error 0
        $r debug aof-flush-force-stall 0
        wait_for_condition 50 20 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after recovery"
        }
        $r set recovered v
        assert_equal [$r waitaof 1 0 5000] {1 0}
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

        $r debug aof-flush-force-stall 1

        set rd_bpop [redis_deferring_client]
        $rd_bpop fsl.bpop bgk_fsl 0
        wait_for_condition 100 20 {
            [s blocked_clients] >= 1
        } else {
            $rd_bpop close
            $r debug aof-flush-force-stall 0
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
            $r debug aof-flush-force-stall 0
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
            $r debug aof-flush-force-stall 0
            fail "FSL.BPOP reply arrived before its pop was durable"
        }

        # Release the stall -> the pop's AOF write is fsynced -> both replies
        # arrive.
        $r debug aof-flush-force-stall 0
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
}
