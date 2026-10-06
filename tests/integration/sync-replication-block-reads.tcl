# sync-replication-block-reads local: a read is held until the write it depends
# on is durable in the local AOF. Run under appendfsync bgalways, where the AOF
# fsync happens in a background thread and replies are held until it completes.
# The hold is created by stalling the AOF flush (DEBUG AOF-FLUSH-FORCE STALL), so
# the durable offset stops advancing until the stall is released.
#
# The replica-side counterpart -- a read served BY a replica, waiting on the
# replica's own AOF fsync -- lives in sync-replication-block-reads-replica.tcl.
# The write-side hold/drain gate itself lives in appendfsync-bgalways.tcl.

# ---------------------------------------------------------------------------
# Block-read behavior. The subsections cover dirty state tracking, read
# deferral, expiry and eviction, configuration, client notifications, and
# database-wide invalidation.
# ---------------------------------------------------------------------------

# The flow shared by the no-op-write deferral tests below: with the AOF flush
# stalled, `dirty_cmd` is held until durable, so `noop_cmd` from a second, clean
# client must be held on the same offset instead of answering from that
# not-yet-durable state. Both clients belong to the caller. Every fail() releases
# the stall first: a held write that can never become durable would hang the rest
# of the file.
proc assert_noop_write_deferred {rd_writer rd_reader dirty_cmd dirty_reply noop_cmd noop_reply} {
    set master [srv 0 client]

    $master debug aof-flush-force stall 1
    set hold_before [s sync_repl_hold_depth_count]

    # With the flush stalled the write cannot become durable: it is held.
    $rd_writer {*}$dirty_cmd
    wait_for_condition 100 50 {
        [s sync_repl_pending_clients] == 1 &&
        ([s sync_repl_hold_depth_count] - $hold_before) >= 1
    } else {
        $master debug aof-flush-force stall 0
        fail "the dirty write did not chunk"
    }

    # The no-op write must produce a chunk of its own and stay silent.
    $rd_reader {*}$noop_cmd
    wait_for_condition 100 50 {
        [s sync_repl_pending_clients] == 2 &&
        ([s sync_repl_hold_depth_count] - $hold_before) >= 2
    } else {
        $master debug aof-flush-force stall 0
        fail "$noop_cmd was not deferred on the dirty key"
    }
    if {[reply_arrived_within $rd_reader 100]} {
        $master debug aof-flush-force stall 0
        fail "$noop_cmd replied before the dirty write was acked"
    }

    $master debug aof-flush-force stall 0
    assert_equal [$rd_writer read] $dirty_reply
    assert_equal [$rd_reader read] $noop_reply
    wait_for_condition 50 100 {
        [s sync_repl_pending_clients] == 0
    } else {
        fail "pending clients did not drain after resume"
    }
}

set miscmodule [file normalize tests/modules/misc.so]
start_server [list tags {"aof bgalways external:skip"} overrides [list appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0 loadmodule $miscmodule]] {
    set master [srv 0 client]

    # ------------------------------------------------------------------
    # Dirty-dict tracking; feature off → no read-behaviour change
    # ------------------------------------------------------------------

    test {Block-reads disabled: GET on an unacked key returns immediately} {
        # With sync-replication-block-reads no (the default), a GET on a
        # written-but-unacked key must NOT be deferred. Verify by pausing
        # the AOF flush, issuing a write (which chunks), then doing GET from
        # a deferring client and confirming the GET reply arrives without
        # waiting for durability.
        $master config set sync-replication-block-reads no
        $master debug aof-flush-force stall 1
        set rd_writer [redis_deferring_client]
        set rd_reader [redis_deferring_client]
        $rd_writer set noblock_unacked_key noblock_unacked_val
        # Wait for the write to chunk (AOF flush is stalled, so the write is held).
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 1
        } else {
            fail "write did not chunk"
        }
        # Now GET on the same key from a different client. With block-reads
        # off this must arrive immediately.
        $rd_reader get noblock_unacked_key
        assert_equal [$rd_reader read] noblock_unacked_val
        $master debug aof-flush-force stall 0
        # Drain the held writer.
        assert_equal [$rd_writer read] OK
        wait_for_condition 50 100 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after resume"
        }
        $rd_writer close
        $rd_reader close
    }

    test {Dirty tracking: a write adds an entry and an ACK removes it} {
        # With sync-rep engaged and the AOF flush stalled, a SET must insert
        # the key into sync_repl_dirty_keys (visible via DEBUG SYNCREP DIRTY-KEYS
        # and sync_repl_dirty_keys_count). After resume+ack, the dict must be empty.
        # Population is gated on the feature being ON (zero overhead when off),
        # so enable block-reads. The write must be issued from a DEFERRING
        # client: with the AOF flush stalled and its reply is held,
        # and a synchronous client would block the test forever.
        $master config set sync-replication-block-reads local
        $master del dirty_tracked_key
        $master debug aof-flush-force stall 1
        set rd_w [redis_deferring_client]
        $rd_w set dirty_tracked_key dirty_tracked_val
        # Wait for the write to chunk (held by the stalled AOF flush).
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 1
        } else {
            fail "write did not chunk"
        }
        # DEBUG SYNCREP DIRTY-KEYS returns a flat list: key woff key woff ...
        set dirty [$master debug syncrep dirty-keys]
        set idx [lsearch $dirty dirty_tracked_key]
        if {$idx < 0} { $master debug aof-flush-force stall 0; $rd_w close; fail "dirty_tracked_key not found in dirty-keys output: $dirty" }
        # The woff value is the element right after the key.
        set woff [lindex $dirty [expr {$idx + 1}]]
        if {$woff <= 0} { $master debug aof-flush-force stall 0; $rd_w close; fail "woff for dirty_tracked_key should be > 0, got $woff" }
        # sync_repl_dirty_keys_count must be at least 1.
        assert {[s sync_repl_dirty_keys_count] >= 1}
        # Release the stall, then the dict must drain to empty.
        $master debug aof-flush-force stall 0
        assert_equal [$rd_w read] OK
        wait_for_condition 100 50 {
            [s sync_repl_dirty_keys_count] == 0
        } else {
            fail "dirty dict did not drain to empty after durability"
        }
        # DEBUG SYNCREP DIRTY-KEYS should now return an empty list.
        assert_equal [$master debug syncrep dirty-keys] {}
        $rd_w close
    }

    # ------------------------------------------------------------------
    # Feature on — read-side deferral
    # ------------------------------------------------------------------

    test {Read deferral: same-client GET waits for the preceding write} {
        # With the feature on and the AOF flush stalled, a SET followed by a
        # GET on the same key from the SAME client must both be held until
        # the durabilitys. The existing RESP-ordering mechanism already
        # chains reads behind writes on the same client; the feature
        # ensures the GET chunk is issued even though GET itself doesn't
        # propagate, because the key is dirty.
        $master config set sync-replication-block-reads local
        $master debug aof-flush-force stall 1
        set rd [redis_deferring_client]
        set hold_before [s sync_repl_hold_depth_count]
        $rd set same_client_key same_client_val
        $rd get same_client_key
        # Two replies should be queued (one write chunk + one read chunk) on
        # the same client.
        wait_for_condition 100 50 {
            ([s sync_repl_hold_depth_count] - $hold_before) >= 2 &&
            [s sync_repl_pending_clients] == 1
        } else {
            fail "GET did not queue behind SET (hold delta: [expr [s sync_repl_hold_depth_count] - $hold_before])"
        }
        # Verify no reply bytes arrive while the AOF flush is still stalled.
        if {[reply_arrived_within $rd 100]} {
            fail "replies arrived while AOF flush still stalled"
        }
        # Resume → both replies arrive in order.
        $master debug aof-flush-force stall 0
        assert_equal [$rd read] OK
        assert_equal [$rd read] same_client_val
        wait_for_condition 50 100 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after resume"
        }
        $rd close
    }

    test {Read deferral: cross-client GET waits for the dirty write} {
        # Write K, then GET K from a DIFFERENT client while the AOF flush is
        # paused. The second client has never issued a write, so without
        # per-key dirty tracking it would see the local value immediately.
        # With the feature on, the GET must be held until the write acks.
        $master config set sync-replication-block-reads local
        $master debug aof-flush-force stall 1
        set rd_writer [redis_deferring_client]
        set rd_reader [redis_deferring_client]
        set hold_before [s sync_repl_hold_depth_count]
        $rd_writer set cross_client_key cross_client_val
        # Wait for the write chunk to appear.
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 1 &&
            ([s sync_repl_hold_depth_count] - $hold_before) >= 1
        } else {
            fail "write did not chunk"
        }
        # Reader issues GET on the dirty key from a clean client.
        $rd_reader get cross_client_key
        # The reader's GET must also produce a chunk (key is dirty) and the
        # reader must now be pending.
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 2 &&
            ([s sync_repl_hold_depth_count] - $hold_before) >= 2
        } else {
            fail "cross-client GET did not chunk (hold delta: [expr [s sync_repl_hold_depth_count] - $hold_before])"
        }
        # Confirm the reader is silent while the AOF flush is stalled.
        if {[reply_arrived_within $rd_reader 100]} {
            fail "cross-client GET received bytes before durabilityed"
        }
        # Resume → both clients unblock; the reader gets the value.
        $master debug aof-flush-force stall 0
        assert_equal [$rd_writer read] OK
        assert_equal [$rd_reader read] cross_client_val
        wait_for_condition 50 100 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after resume"
        }
        $rd_writer close
        $rd_reader close
    }

    # A no-op write reports unacked state while propagating nothing of its own,
    # so it has to wait on the dirty key's offset like a GET. All are CMD_WRITE,
    # so none is covered unless "propagated nothing" falls back to the read path.

    test {Read deferral: no-op SETNX on a dirty key waits like a read} {
        # The 0 reply reveals the key the held SET created.
        $master config set sync-replication-block-reads local
        $master del noop_setnx
        set rd_writer [redis_deferring_client]
        set rd_reader [redis_deferring_client]
        assert_noop_write_deferred $rd_writer $rd_reader \
            {set noop_setnx dirty_val} OK \
            {setnx noop_setnx other_val} 0
        $rd_writer close
        $rd_reader close
    }

    test {Read deferral: GETEX without options waits like a read} {
        # GETEX with no options propagates nothing and leaks the value.
        $master config set sync-replication-block-reads local
        $master del noop_getex
        set rd_writer [redis_deferring_client]
        set rd_reader [redis_deferring_client]
        assert_noop_write_deferred $rd_writer $rd_reader \
            {set noop_getex dirty_val} OK \
            {getex noop_getex} dirty_val
        $rd_writer close
        $rd_reader close
    }

    test {Read deferral: SET XX on a key a dirty DEL removed waits like a read} {
        # The nil reply reveals the held DEL.
        $master config set sync-replication-block-reads local
        $master set noop_setxx stale_val
        set rd_writer [redis_deferring_client]
        set rd_reader [redis_deferring_client]
        assert_noop_write_deferred $rd_writer $rd_reader \
            {del noop_setxx} 1 \
            {set noop_setxx other_val XX} {}
        $rd_writer close
        $rd_reader close
    }

    test {Read deferral: DEL with nothing to delete waits like a read} {
        $master config set sync-replication-block-reads local
        $master set noop_del stale_val
        set rd_writer [redis_deferring_client]
        set rd_reader [redis_deferring_client]
        assert_noop_write_deferred $rd_writer $rd_reader \
            {del noop_del} 1 \
            {del noop_del} 0
        $rd_writer close
        $rd_reader close
    }

    test {Read deferral: EXPIRE with nothing to expire waits like a read} {
        $master config set sync-replication-block-reads local
        $master set noop_expire stale_val
        set rd_writer [redis_deferring_client]
        set rd_reader [redis_deferring_client]
        assert_noop_write_deferred $rd_writer $rd_reader \
            {del noop_expire} 1 \
            {expire noop_expire 100} 0
        $rd_writer close
        $rd_reader close
    }

    test {Read deferral: COPY onto a dirty destination waits like a read} {
        # COPY returns 0 without propagating when the destination exists --
        # which is what the held write created.
        $master config set sync-replication-block-reads local
        $master set noop_copy_src src_val
        $master del noop_copy_dst
        set rd_writer [redis_deferring_client]
        set rd_reader [redis_deferring_client]
        assert_noop_write_deferred $rd_writer $rd_reader \
            {set noop_copy_dst dirty_val} OK \
            {copy noop_copy_src noop_copy_dst} 0
        $rd_writer close
        $rd_reader close
    }

    test {Read deferral: an EXEC of only no-op writes waits like a read} {
        # EXEC has no keys of its own: each subcommand records its dependency
        # before it runs (multi.c) and the reply is held on the maximum. With
        # every subcommand a no-op, the transaction propagates nothing at all.
        $master config set sync-replication-block-reads local
        $master del noop_exec
        set rd_writer [redis_deferring_client]
        set rd_reader [redis_deferring_client]
        # Queueing touches no key, so only the EXEC reply can be deferred.
        $rd_reader multi
        assert_equal [$rd_reader read] OK
        $rd_reader setnx noop_exec other_val
        assert_equal [$rd_reader read] QUEUED
        $rd_reader getex noop_exec
        assert_equal [$rd_reader read] QUEUED
        assert_noop_write_deferred $rd_writer $rd_reader \
            {set noop_exec dirty_val} OK \
            {exec} {0 dirty_val}
        $rd_writer close
        $rd_reader close
    }

    test {Read deferral: a script whose only write is a no-op waits like a read} {
        # The outer EVAL is skipped -- its declared keys are only an upper bound
        # on what the script touches -- so scriptCall() records each inner
        # command instead, and a no-op inner SETNX propagates nothing.
        $master config set sync-replication-block-reads local
        $master del noop_eval
        # Preload: the implicit SCRIPT LOAD of a first EVAL propagates, which
        # would hold the reply on its own offset and hide a missing dependency.
        set script {return redis.call('setnx', KEYS[1], ARGV[1])}
        $master script load $script
        set rd_writer [redis_deferring_client]
        set rd_reader [redis_deferring_client]
        assert_noop_write_deferred $rd_writer $rd_reader \
            {set noop_eval dirty_val} OK \
            [list eval $script 1 noop_eval other_val] 0
        $rd_writer close
        $rd_reader close
    }

    test {Read deferral: a clean-key GET in the pipeline adds no wait} {
        # With a pending write on key K, a GET on a DIFFERENT, CLEAN key J
        # must drain as soon as the queue head (the write on K) clears —
        # it must NOT need its own durability (woff=0 passthrough chunk).
        # Mirrors the existing "RESP ordering: passthrough chunk drains as
        # soon as head clears" test, but via the read-blocking code path.
        $master config set sync-replication-block-reads local
        $master del pipeline_dirty_key pipeline_clean_key
        $master set pipeline_clean_key clean_value
        $master debug aof-flush-force stall 1
        set rd [redis_deferring_client]
        set hold_before [s sync_repl_hold_depth_count]
        # Write dirty key K, then read clean key J on the same client.
        $rd set pipeline_dirty_key pipeline_dirty_val
        $rd get pipeline_clean_key
        # The write produces a chunk; the GET on the clean key must not
        # independently need a dirty woff but may still chain behind the
        # write on the same client.
        wait_for_condition 100 50 {
            ([s sync_repl_hold_depth_count] - $hold_before) >= 2 &&
            [s sync_repl_pending_clients] == 1
        } else {
            fail "pipeline did not produce expected chunk count"
        }
        # Resume → both replies arrive in order; the clean GET does not
        # need an additional ack cycle beyond the write.
        $master debug aof-flush-force stall 0
        assert_equal [$rd read] OK
        assert_equal [$rd read] clean_value
        wait_for_condition 50 100 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after resume"
        }
        $rd close
    }

    test {Dirty tracking: an EVAL write blocks a cross-client GET} {
        # Same cross-client shape as the SET case above, but the write happens
        # through redis.call() inside a script instead of directly. This covers
        # the nested-client path: keyModified must not buffer onto the script
        # engine's fake client (lctx.lua_client), whose buffer is never drained
        # (call()'s epilogue only drains the OUTERMOST client's buffer) — buffered
        # there, the key never reaches sync_repl_dirty_keys and this GET would return
        # immediately instead of deferring.
        $master config set sync-replication-block-reads local
        $master debug aof-flush-force stall 1
        set rd_writer [redis_deferring_client]
        set rd_reader [redis_deferring_client]
        set hold_before [s sync_repl_hold_depth_count]
        $rd_writer eval {return redis.call('set', KEYS[1], ARGV[1])} 1 eval_write_key eval_write_val
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 1 &&
            ([s sync_repl_hold_depth_count] - $hold_before) >= 1
        } else {
            fail "EVAL write did not chunk"
        }
        # Reader issues GET on the dirty key from a clean client. If the
        # script's write never reached sync_repl_dirty_keys, this GET is not
        # detected as dirty and would NOT chunk (the failure surfaces here).
        $rd_reader get eval_write_key
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 2 &&
            ([s sync_repl_hold_depth_count] - $hold_before) >= 2
        } else {
            fail "cross-client GET did not chunk — script write was not recorded in sync_repl_dirty_keys (hold delta: [expr [s sync_repl_hold_depth_count] - $hold_before])"
        }
        # Confirm the reader is silent while the AOF flush is stalled.
        if {[reply_arrived_within $rd_reader 100]} {
            fail "cross-client GET received bytes before durabilityed"
        }
        $master debug aof-flush-force stall 0
        assert_equal [$rd_writer read] OK
        assert_equal [$rd_reader read] eval_write_val
        wait_for_condition 50 100 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after resume"
        }
        $rd_writer close
        $rd_reader close
    }

    test {Dirty tracking: a module RM_Call write blocks a cross-client GET} {
        # Same shape as the EVAL case above, but the write happens through a module's
        # RM_Call() (test.rm_call_replicate from tests/modules/misc.c,
        # which wraps test_rm_call and then RM_ReplicateVerbatim so the
        # write actually propagates) instead of a Lua script. Covers the same
        # keyModified nested-client path: a module temp client
        # (moduleAllocTempClient, pooled/reused across calls) is not the
        # outermost client either, so its buffer is never drained — exactly
        # like the Lua engine client's.
        $master config set sync-replication-block-reads local
        $master debug aof-flush-force stall 1
        set rd_writer [redis_deferring_client]
        set rd_reader [redis_deferring_client]
        set hold_before [s sync_repl_hold_depth_count]
        $rd_writer test.rm_call_replicate SET rm_call_key rm_call_val
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 1 &&
            ([s sync_repl_hold_depth_count] - $hold_before) >= 1
        } else {
            fail "RM_Call write did not chunk"
        }
        $rd_reader get rm_call_key
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 2 &&
            ([s sync_repl_hold_depth_count] - $hold_before) >= 2
        } else {
            fail "cross-client GET did not chunk — RM_Call write was not recorded in sync_repl_dirty_keys (hold delta: [expr [s sync_repl_hold_depth_count] - $hold_before])"
        }
        if {[reply_arrived_within $rd_reader 100]} {
            fail "cross-client GET received bytes before durabilityed"
        }
        $master debug aof-flush-force stall 0
        assert_equal [$rd_writer read] OK
        assert_equal [$rd_reader read] rm_call_val
        wait_for_condition 50 100 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after resume"
        }
        $rd_writer close
        $rd_reader close
    }

    test {Dirty tracking: reexecuted BLMOVE records both keys before ACK} {
        $master config set sync-replication-block-reads local
        $master del blmove_src blmove_dst
        set rd_mover [redis_deferring_client]
        set rd_writer [redis_deferring_client]
        set rd_reader [redis_deferring_client]
        set replica_paused 0

        $rd_mover blmove blmove_src blmove_dst LEFT RIGHT 0
        wait_for_blocked_clients_count 1 100 10 0
        set pre_woff [s master_repl_offset]
        set hold_before [s sync_repl_hold_depth_count]
        $master debug aof-flush-force stall 1
        set replica_paused 1
        $rd_writer rpush blmove_src value
        wait_for_condition 100 50 {
            [s sync_repl_hold_depth_count] - $hold_before == 2 &&
            [s sync_repl_pending_clients] == 2
        } else {
            fail "RPUSH and reexecuted BLMOVE did not both hold their replies"
        }

        # BLMOVE propagates after its nested call() returns. Both keys must
        # carry that final offset, including the destination RPUSH never touched.
        set dirty [$master debug syncrep dirty-keys]
        assert {[dict exists $dirty blmove_src]}
        assert {[dict exists $dirty blmove_dst]}
        set move_woff [dict get $dirty blmove_dst]
        assert {$move_woff > $pre_woff}
        assert_equal $move_woff [dict get $dirty blmove_src]

        # A separate client's read must wait for the move's ACK too.
        $rd_reader llen blmove_dst
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 3
        } else {
            fail "LLEN on the destination was not held"
        }

        $master debug aof-flush-force stall 0
        set replica_paused 0
        assert_equal 1 [$rd_writer read]
        assert_equal value [$rd_mover read]
        assert_equal 1 [$rd_reader read]
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 0 &&
            [s sync_repl_dirty_keys_count] == 0
        } else {
            fail "pending replies and dirty keys did not drain after ACK"
        }
        if {$replica_paused} { $master debug aof-flush-force stall 0 }
        $rd_mover close
        $rd_writer close
        $rd_reader close
    }

    test {Dirty tracking: repeated writes share one cleanup node} {
        # syncReplDirtyKeysUpsert must append a woff-ordered cleanup node only
        # when the upsert actually advances the stored woff. A script writing
        # the same key many times drains all of those writes at the same final
        # offset, so every call after the first is a no-op on the dirty-keys
        # dict; appending a node anyway costs O(writes) memory (each node
        # holding a copy of the key) that syncReplDirtyKeysCleanupWhile then has to
        # walk one at a time on the main thread once the write is acked.
        $master config set sync-replication-block-reads local
        $master debug aof-flush-force stall 1
        set replica_paused 1
        set rd_writer [redis_deferring_client]

        set hold_before [s sync_repl_hold_depth_count]
        $rd_writer eval {
            for i=1,5000 do redis.call('set', KEYS[1], ARGV[1]) end
            return redis.call('get', KEYS[1])
        } 1 repeated_write_key repeated_write_val
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 1 &&
            ([s sync_repl_hold_depth_count] - $hold_before) >= 1
        } else {
            fail "EVAL write did not chunk"
        }
        assert_equal 1 [s sync_repl_dirty_keys_count]
        assert_equal 1 [$master debug syncrep dirty-ordered-len]

        $master debug aof-flush-force stall 0
        set replica_paused 0
        assert_equal [$rd_writer read] repeated_write_val
        wait_for_condition 50 100 {
            [s sync_repl_pending_clients] == 0 &&
            [s sync_repl_dirty_keys_count] == 0 &&
            [$master debug syncrep dirty-ordered-len] == 0
        } else {
            fail "pending replies and dirty state did not drain after ACK"
        }
        if {$replica_paused} { $master debug aof-flush-force stall 0 }
        $rd_writer close
    }

    test {Dirty tracking: repeated writes to one key buffer one copy} {
        # syncReplDirtyKeyRecord buffers into a set, so an execution unit writing
        # the same key N times holds one copy of that key, not N. The copies
        # used to cost O(writes x keylen) of temporary memory, which a script
        # looping over a long key could turn into an OOM before the outermost
        # command ended and drained the buffer.
        #
        # The record count still counts every write: MULTI/EXEC and scripts
        # snapshot it around nested calls to detect dependencies recorded while
        # they ran, which a deduping set's size cannot express.
        #
        # DEBUG is noscript, so observe from inside an EXEC rather than a
        # script: the buffer is not drained between subcommands, and both kinds
        # of execution unit share the same buffering path.
        $master config set sync-replication-block-reads local
        set longkey [string repeat k 4096]

        $master multi
        for {set i 0} {$i < 20} {incr i} {
            $master set $longkey val-$i
        }
        $master debug syncrep buffered-keys
        set res [$master exec]

        # [distinct, records] as seen by the last subcommand of the EXEC,
        # before its execution unit drains the buffer.
        assert_equal {1 20} [lindex $res end]
        assert_equal val-19 [$master get $longkey]

        # Distinct keys are still each buffered.
        $master multi
        $master set ${longkey}-a v
        $master set ${longkey}-b v
        $master set ${longkey}-a v
        $master debug syncrep buffered-keys
        assert_equal {2 3} [lindex [$master exec] end]

        # The counter is reset by the drain, so it does not leak into the next
        # execution unit.
        $master multi
        $master debug syncrep buffered-keys
        assert_equal {0 0} [lindex [$master exec] end]

        $master del $longkey ${longkey}-a ${longkey}-b
    }

    test {Dirty tracking: disabling inside EXEC discards command buffers} {
        # An earlier subcommand can populate both command-level buffers before
        # a later CONFIG SET disables tracking. The outer EXEC epilogue must
        # still discard those buffers and reset the record counter; otherwise
        # they survive on the client and are drained with a stale offset when
        # the feature is enabled again.
        wait_for_condition 100 50 {
            [s sync_repl_dirty_keys_count] == 0 &&
            [s sync_repl_dirty_dbs_count] == 0
        } else {
            fail "dirty state did not drain before discard test"
        }
        $master config set sync-replication-block-reads local

        $master multi
        $master set exec_discard_buffer_key value
        $master swapdb 14 15
        $master config set sync-replication-block-reads no
        $master debug syncrep buffered-keys
        set res [$master exec]
        assert_equal {1 1} [lindex $res end]

        # The buffer and its record counter are command-scoped even though the
        # feature was off by the time the outer execution unit finished.
        assert_equal {0 0} [$master debug syncrep buffered-keys]

        # Restore the DB layout while tracking is off, then re-enable on this
        # same client. Neither the old key nor the two SWAPDB DB markers may be
        # imported into global dirty state by CONFIG's epilogue.
        $master swapdb 14 15
        $master config set sync-replication-block-reads local
        assert {![dict exists [$master debug syncrep dirty-keys] exec_discard_buffer_key]}
        assert_equal {} [$master debug syncrep dirty-dbs]

        $master config set sync-replication-block-reads no
        $master del exec_discard_buffer_key
    }

    test {Expiry tracking disabled: GET returns nil immediately} {
        # With sync-replication-block-reads-on-expire no (default), a lazy or
        # active expiry is NOT tracked. The triggering GET must return nil
        # immediately (not wait for the expiry-DEL to ack) and
        # sync_repl_dirty_keys_count must NOT include the expired key.
        # This mirrors the existing "Lazy expiry on read: GET on expired key
        # does NOT chunk" test, but now asserting the dirty dict stays clean.
        $master config set sync-replication-block-reads local
        $master config set sync-replication-block-reads-on-expire no
        $master debug set-active-expire 0
        $master set untracked_expire_key untracked_expire_val px 50
        after 200  ;# let the key expire
        $master debug aof-flush-force stall 1
        set rd [redis_deferring_client]
        set count_before [s sync_repl_dirty_keys_count]
        # GET on the expired key — must return nil promptly.
        $rd get untracked_expire_key
        assert_equal [$rd read] {}
        # sync_repl_dirty_keys_count must not have increased for this key.
        assert_equal [s sync_repl_dirty_keys_count] $count_before
        $master debug aof-flush-force stall 0
        $rd close
        $master debug set-active-expire 1
    }

    test {Expiry tracking enabled: GET waits for the expiry DEL} {
        # With sync-replication-block-reads-on-expire yes, expiration is
        # promoted to the same treatment as eviction: the expiry-DEL is tracked
        # in sync_repl_dirty_keys, and a subsequent GET on the expired key is
        # deferred until the expiry-DEL acks, then returns nil.
        $master config set sync-replication-block-reads local
        $master config set sync-replication-block-reads-on-expire yes
        $master debug set-active-expire 0
        $master set tracked_expire_key tracked_expire_val px 50
        after 200  ;# let the key expire
        $master debug aof-flush-force stall 1
        # A GET on the expired key should trigger lazy expiry, whose DEL
        # (with -on-expire yes) is recorded as dirty. The GET must therefore
        # be deferred.
        set rd [redis_deferring_client]
        set hold_before [s sync_repl_hold_depth_count]
        $rd get tracked_expire_key
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] >= 1
        } else {
            fail "GET on expired key was not deferred (block-reads-on-expire is on)"
        }
        # Confirm GET stays deferred.
        if {[reply_arrived_within $rd 100]} {
            fail "deferred GET received bytes while AOF flush stalled"
        }
        # Resume → expiry-DEL acks → GET returns nil.
        $master debug aof-flush-force stall 0
        assert_equal [$rd read] {}
        wait_for_condition 50 100 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after resume"
        }
        $rd close
        $master config set sync-replication-block-reads-on-expire no
        $master debug set-active-expire 1
    }

    test {Eviction tracking: only the evicted-key reader waits} {
        # Per-key blocking, demonstrated robustly. Two equally large keys; under
        # memory pressure eviction removes exactly ONE, but which one is not
        # guaranteed — so we discover the evicted (now dirty, unacked) key, then
        # assert: a read of the SURVIVOR is NOT deferred, while a read of the
        # EVICTED key IS deferred until its DEL acks, then returns nil. This is
        # the contrast with per-command eviction chunking.
        $master config set sync-replication-block-reads local
        $master debug set-active-expire 0
        $master flushdb
        # Two equally large (1MB) keys; eviction must drop exactly one of them.
        set v1 [string repeat 1 1048576]
        set v2 [string repeat 2 1048576]
        $master set evict_candidate1 $v1
        $master set evict_candidate2 $v2
        # Let the client query-buffer excess from the 1MB SETs above be trimmed
        # by cron before measuring; otherwise used_memory is transiently
        # inflated and the sized push below won't cross maxmemory (mirrors
        # tests/unit/maxmemory.tcl).
        after 1100
        wait_for_stable 100 100 {s used_memory}
        # maxmemory just ABOVE the eviction metric (used_memory minus
        # mem_not_counted_for_evict), so eviction does NOT fire now (an eviction
        # while unpaused would ack and be cleaned). It is forced below, while
        # paused, so the eviction-DEL stays unacked.
        set used_no_repl [expr {[s used_memory] - [s mem_not_counted_for_evict]}]
        $master config set maxmemory-policy allkeys-lru
        $master config set maxmemory [expr {$used_no_repl + 262144}]
        $master debug aof-flush-force stall 1
        # Force eviction while paused via a deferring client: the 512KB push
        # exceeds the headroom; evicting one 1MB key drops ~750KB under the
        # limit, so exactly one of the two candidates is evicted and the
        # server lands comfortably under maxmemory (so the discovery/read
        # commands below do not trip further eviction). Replies held until
        # resume.
        set rd_trig [redis_deferring_client]
        $rd_trig set evict_trigger [string repeat Z 524288]
        $rd_trig set evict_settle_key evict_settle_val
        # Discover which big key was evicted, via a throwaway client (NOT the
        # shared $master, which may carry pending chunks of its own).
        set probe [redis_client]
        wait_for_condition 100 50 {
            [lsearch [$probe debug syncrep dirty-keys] evict_candidate1] >= 0 ||
            [lsearch [$probe debug syncrep dirty-keys] evict_candidate2] >= 0
        } else {
            fail "neither big key was evicted"
        }
        set dirty [$probe debug syncrep dirty-keys]
        if {[lsearch $dirty evict_candidate1] >= 0} {
            set evicted evict_candidate1; set survivor evict_candidate2; set survivor_val $v2
        } else {
            set evicted evict_candidate2; set survivor evict_candidate1; set survivor_val $v1
        }
        $probe close

        # Survivor reader: must NOT be deferred (survivor is clean/acked).
        set rd_surv [redis_deferring_client]
        $rd_surv get $survivor
        assert_equal [$rd_surv read] $survivor_val

        # Evicted-key reader: MUST be deferred until the eviction-DEL acks.
        set rd_ev [redis_deferring_client]
        $rd_ev get $evicted
        if {[reply_arrived_within $rd_ev 100]} {
            fail "reader of evicted key $evicted received bytes before DEL acked"
        }

        # Resume → eviction-DEL acks → evicted-key read returns nil.
        $master debug aof-flush-force stall 0
        assert_equal [$rd_trig read] OK
        assert_equal [$rd_trig read] OK
        assert_equal [$rd_ev read] {}
        wait_for_condition 50 100 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after resume"
        }
        $rd_surv close; $rd_ev close; $rd_trig close
        $master config set maxmemory 0
        $master config set maxmemory-policy noeviction
        $master debug set-active-expire 1
    }

    test {Nested eviction while reissuing BLPOP tracks the evicted key} {
        # COPY duplicates a large list using a tiny request. It therefore passes
        # its own pre-command maxmemory check, then pushes the server over the
        # limit and wakes BLPOP. BLPOP's reissue runs inside an outer execution
        # unit, so its pre-command eviction queues the DEL until that unit exits.
        # The evicted key must be tagged with the final, actually propagated
        # offset rather than the unchanged offset observed inside eviction.
        $master config set sync-replication-block-reads local
        $master debug set-active-expire 0
        $master config set maxmemory 0
        $master config set maxmemory-policy noeviction
        $master flushdb

        set nested_payload [string repeat P 524288]
        $master rpush nested_evict_source $nested_payload
        $master set nested_evict_candidate1 [string repeat 1 1048576] ex 3600
        $master set nested_evict_candidate2 [string repeat 2 1048576] ex 3600

        set rd_block [redis_deferring_client]
        $rd_block blpop nested_evict_wake 0
        wait_for_condition 100 20 {
            [s blocked_clients] == 1
        } else {
            fail "BLPOP did not block"
        }

        # Leave less headroom than COPY's deep copy, but much more than its tiny
        # request, so eviction first runs from the nested BLPOP reissue. Only the
        # volatile candidates are eligible; source/wake list keys are protected.
        after 1100
        wait_for_stable 100 100 {s used_memory}
        set used_no_repl [expr {[s used_memory] - [s mem_not_counted_for_evict]}]
        $master config set maxmemory-policy volatile-lru
        $master config set maxmemory [expr {$used_no_repl + 262144}]

        $master debug aof-flush-force stall 1
        set rd_copy [redis_deferring_client]
        $rd_copy copy nested_evict_source nested_evict_wake

        set probe [redis_client]
        wait_for_condition 100 50 {
            [lsearch [$probe debug syncrep dirty-keys] nested_evict_candidate1] >= 0 ||
            [lsearch [$probe debug syncrep dirty-keys] nested_evict_candidate2] >= 0
        } else {
            fail "nested eviction did not record either candidate as dirty"
        }
        set dirty [$probe debug syncrep dirty-keys]
        if {[lsearch $dirty nested_evict_candidate1] >= 0} {
            set nested_evicted nested_evict_candidate1
        } else {
            set nested_evicted nested_evict_candidate2
        }
        $probe close

        # A different client's read of the evicted key must wait for the queued
        # DEL's acknowledgement; returning nil now would permit failover to
        # resurrect the replica's old value.
        set rd_evicted [redis_deferring_client]
        $rd_evicted get $nested_evicted
        if {[reply_arrived_within $rd_evicted 100]} {
            fail "reader of nested-evicted key received nil before DEL acked"
        }

        $master debug aof-flush-force stall 0
        assert_equal [$rd_copy read] 1
        set pop_reply [$rd_block read]
        assert_equal [lindex $pop_reply 0] nested_evict_wake
        assert_equal [lindex $pop_reply 1] $nested_payload
        assert_equal [$rd_evicted read] {}
        wait_for_condition 50 100 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after nested eviction ack"
        }

        $rd_evicted close; $rd_copy close; $rd_block close
        $master config set maxmemory 0
        $master config set maxmemory-policy noeviction
        $master debug set-active-expire 1
    }

    test {Script write then read: the EVAL reply waits for its write} {
        # An EVAL that contains both a write to K and a read of K is treated
        # as a whole-script write (it propagates). Its reply is held via the
        # write-side chunk path. No extra read-side logic needed; the test
        # verifies the combined deferred reply arrives after ack.
        $master config set sync-replication-block-reads local
        $master debug aof-flush-force stall 1
        set rd [redis_deferring_client]
        set hold_before [s sync_repl_hold_depth_count]
        # Script: SET script_rw_key, then GET script_rw_key; return the GET result.
        $rd eval {
            redis.call('set', KEYS[1], ARGV[1])
            return redis.call('get', KEYS[1])
        } 1 script_rw_key script_rw_val
        # The EVAL propagates (write inside), so exactly one chunk is created.
        wait_for_condition 100 50 {
            ([s sync_repl_hold_depth_count] - $hold_before) >= 1 &&
            [s sync_repl_pending_clients] == 1
        } else {
            fail "EVAL did not chunk"
        }
        # Confirm the script reply stays deferred.
        if {[reply_arrived_within $rd 100]} {
            fail "EVAL reply arrived before durabilityed"
        }
        # Resume → ack → the script's return value (the GET result) arrives.
        $master debug aof-flush-force stall 0
        assert_equal [$rd read] script_rw_val
        wait_for_condition 50 100 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after resume"
        }
        $rd close
    }

    test {Block-reads disabled: eviction does not defer either reader} {
        # Eviction read-blocking is gated on the feature. With block-reads OFF
        # there is no dirty dict and no read-side deferral: a reader of an
        # evicted-but-unacked key gets nil IMMEDIATELY (the only OFF-mode
        # protection is the shipped blunt chunking of the command that TRIGGERS
        # the eviction). This is the disabled counterpart to the test above,
        # where block-reads defers the same read until the eviction-DEL acks.
        $master config set sync-replication-block-reads no
        $master debug set-active-expire 0
        $master config set maxmemory 0
        $master config set maxmemory-policy noeviction
        $master flushdb
        $master set noblock_evict_candidate1 [string repeat A 1048576]
        $master set noblock_evict_candidate2 [string repeat B 1048576]
        set ev_before [s evicted_keys]
        # Let the client query-buffer excess from the 1MB SETs above be trimmed
        # by cron before measuring; otherwise used_memory is transiently
        # inflated and the sized push below won't cross maxmemory (mirrors
        # tests/unit/maxmemory.tcl).
        after 1100
        wait_for_stable 100 100 {s used_memory}
        set used_no_repl [expr {[s used_memory] - [s mem_not_counted_for_evict]}]
        $master config set maxmemory-policy allkeys-lru
        $master config set maxmemory [expr {$used_no_repl + 262144}]
        $master debug aof-flush-force stall 1
        # A 512KB write whose own argument crosses maxmemory: its pre-command
        # check evicts one of the 1MB keys (held + unacked, AOF flush stalled).
        #
        # IMPORTANT: while stalled, issue NO synchronous command on $master / `s`
        # until the push has settled. While the server is transiently over
        # maxmemory (the push's 512KB arg sits in the query buffer), any command
        # — even INFO or EXISTS — would itself trigger eviction and, with
        # block-reads OFF, get chunked (held), hanging the test. The `after`
        # lets the push run (it evicts one key and drops us back under) first.
        set rd_push [redis_deferring_client]
        $rd_push set noblock_evict_trigger [string repeat C 524288]
        after 300
        # Back under maxmemory. Read BOTH big keys from fresh clients. With
        # block-reads OFF neither is deferred: the survivor returns its value
        # and the evicted one returns nil — both immediately.
        set rd1 [redis_deferring_client]
        set rd2 [redis_deferring_client]
        $rd1 get noblock_evict_candidate1
        $rd2 get noblock_evict_candidate2
        set ready 0
        foreach rd [list $rd1 $rd2] {
            if {[reply_arrived_within $rd 1000]} { incr ready }
        }
        set v1 [$rd1 read]
        set v2 [$rd2 read]
        $master debug aof-flush-force stall 0
        assert_equal [$rd_push read] OK
        wait_for_condition 50 100 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after resume"
        }
        set ev_after [s evicted_keys]
        $rd1 close; $rd2 close; $rd_push close
        if {$ev_after <= $ev_before} {
            $master config set maxmemory 0; $master debug set-active-expire 1
            fail "no eviction was triggered (test setup race)"
        }
        if {$ready != 2} {
            $master config set maxmemory 0; $master debug set-active-expire 1
            fail "a read of a big key was deferred, but block-reads is off"
        }
        set nil_count [expr {($v1 eq {} ? 1 : 0) + ($v2 eq {} ? 1 : 0)}]
        if {$nil_count != 1} {
            $master config set maxmemory 0; $master debug set-active-expire 1
            fail "expected exactly one evicted (nil) big key, got [string length $v1]B and [string length $v2]B"
        }
        $master config set maxmemory 0
        $master config set maxmemory-policy noeviction
        $master debug set-active-expire 1
    }

    # ------------------------------------------------------------------
    # Config/validation
    # ------------------------------------------------------------------

    test {Expiry tracking off: a default-expiry GET is immediate} {
        # These servers have no AOF, so only the `replicas` dimension applies
        # here; the local one is covered in sync-replication-block-reads-replica.
        $master config set sync-replication-block-reads no
        $master debug set-active-expire 0
        $master set expire_noblock_key expire_noblock_val px 50
        after 200
        $master debug aof-flush-force stall 1
        set rd [redis_deferring_client]
        $rd get expire_noblock_key
        assert_equal [$rd read] {}
        $master debug aof-flush-force stall 0
        $rd close
        $master config set sync-replication-block-reads no
        $master config set sync-replication-block-reads-on-expire no
        $master debug set-active-expire 1
    }

    # ------------------------------------------------------------------
    # WATCH and CLIENT TRACKING notifications
    # ------------------------------------------------------------------

    test {WATCH aborts immediately when a pending write changes the key} {
        # With the feature on and the AOF flush stalled (write K is pending),
        # a concurrent MULTI/EXEC that WATCHed K must see K as modified and
        # return a nil-array exec result — the abort happens immediately
        # from the local write, not waiting for the ack.
        $master config set sync-replication-block-reads local
        $master debug aof-flush-force stall 1
        # Client W1: issues the write that will dirty K.
        set rd_writer [redis_deferring_client]
        # W2 (the main client) WATCHes the key first.
        assert_equal [$master watch watch_key] OK
        # W1 writes K. The write is chunked (AOF flush stalled).
        $rd_writer set watch_key watch_val
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 1
        } else {
            fail "write did not chunk"
        }
        # Now the main client (that did WATCH) does MULTI/EXEC.
        # The EXEC must return nil (abort) because K was modified after WATCH.
        $master multi
        $master get watch_key
        set exec_result [$master exec]
        # nil result = transaction aborted due to watched key modification.
        assert_equal $exec_result {}
        $master debug aof-flush-force stall 0
        assert_equal [$rd_writer read] OK
        wait_for_condition 50 100 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after resume"
        }
        $rd_writer close
    }

    test {CLIENT TRACKING invalidates immediately for a pending write} {
        # With the feature on and AOF flush stalled, CLIENT TRACKING must send
        # the invalidation message as soon as K is written locally — the
        # invalidation client must receive its message before the write acks.
        # We verify by: (1) enabling CLIENT TRACKING on a tracking client,
        # (2) issuing a GET (caches the key), (3) pausing the replica,
        # (4) issuing a write from a deferring client, (5) asserting the
        # tracking invalidation arrives on the tracking client before the
        # write reply arrives on the writing client.
        $master config set sync-replication-block-reads local
        # Canonical RESP2 tracking pattern: invalidations are delivered as
        # pub/sub messages on a connection subscribed to __redis__:invalidate,
        # and the tracking client redirects to it.
        set rd_redir [redis_deferring_client]
        $rd_redir client id
        set redir_id [$rd_redir read]
        $rd_redir subscribe __redis__:invalidate
        $rd_redir read ;# consume the SUBSCRIBE reply
        # Tracking owner (synchronous client): enable tracking with redirect,
        # then GET the key to register interest. tracking_key is acked/clean, so
        # the GET is not deferred.
        set tracker [redis_client]
        $master set tracking_key initial_v
        assert_equal [$tracker client tracking on redirect $redir_id] OK
        assert_equal [$tracker get tracking_key] initial_v
        $master debug aof-flush-force stall 1
        # Write the tracked key from a deferring client; its reply is held
        # (AOF flush stalled). The invalidation must still fire immediately.
        set rd_writer [redis_deferring_client]
        $rd_writer set tracking_key new_v
        wait_for_condition 100 50 {
            [status $tracker sync_repl_pending_clients] == 1
        } else {
            fail "write did not chunk"
        }
        # The invalidation must arrive on rd_redir while rd_writer is deferred.
        # Pub/sub message: {message __redis__:invalidate {tracking_key}}.
        set inv [$rd_redir read]
        assert_match "*tracking_key*" $inv
        # The writing client is still deferred (AOF flush still stalled).
        assert_equal [status $tracker sync_repl_pending_clients] 1
        # Resume → writing client unblocks.
        $master debug aof-flush-force stall 0
        assert_equal [$rd_writer read] OK
        wait_for_condition 50 100 {
            [status $tracker sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after resume"
        }
        $tracker client tracking off
        $tracker close; $rd_redir close; $rd_writer close
    }

    # ------------------------------------------------------------------
    # Per-DB dirty offset — FLUSHALL on the default single DB. Per-DB
    # precision and SWAPDB need >1 DB and so live in a separate block below.
    # ------------------------------------------------------------------

    test {FLUSHALL: a cross-client read waits for the flush ACK} {
        # FLUSHALL wipes the keyspace and propagates, but marks no individual
        # key dirty. The per-DB dirty offset must make a later named-key read in
        # the flushed DB defer until the FLUSHALL acks — otherwise the read would
        # observe a non-durable nil that a failover could roll back to the value.
        $master config set sync-replication-block-reads local
        $master set flushall_key flushall_val
        $master debug aof-flush-force stall 1
        set rd_w [redis_deferring_client]
        set rd_r [redis_deferring_client]
        set hold_before [s sync_repl_hold_depth_count]
        $rd_w flushall
        # FLUSHALL is a write → its own reply chunks (held by the stalled AOF flush).
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 1 &&
            ([s sync_repl_hold_depth_count] - $hold_before) >= 1
        } else {
            fail "FLUSHALL did not chunk"
        }
        # The flushed DB (0) must be marked dirty with a real woff.
        assert {[s sync_repl_dirty_dbs_count] >= 1}
        set dirty_dbs [$master debug syncrep dirty-dbs]
        set idx [lsearch $dirty_dbs 0]
        if {$idx < 0} { $master debug aof-flush-force stall 0; $rd_w close; $rd_r close; fail "db 0 not in dirty-dbs: $dirty_dbs" }
        assert {[lindex $dirty_dbs [expr {$idx + 1}]] > 0}
        # A read of the now-absent key from a clean client must also be held.
        $rd_r get flushall_key
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 2 &&
            ([s sync_repl_hold_depth_count] - $hold_before) >= 2
        } else {
            fail "read after FLUSHALL was not deferred"
        }
        # No bytes may reach the reader while the flush is unacked.
        if {[reply_arrived_within $rd_r 100]} {
            fail "read returned before the FLUSHALL acked"
        }
        # Resume → both drain; the read observes the durable nil.
        $master debug aof-flush-force stall 0
        assert_equal [$rd_w read] OK
        assert_equal [$rd_r read] {}
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 0 && [s sync_repl_dirty_dbs_count] == 0
        } else {
            fail "pending clients / dirty DBs did not drain after resume"
        }
        assert_equal {} [$master debug syncrep dirty-dbs]
        $rd_w close ; $rd_r close
    }

    test {Block-reads disabled: a read after FLUSHALL returns immediately} {
        # Disabled counterpart to the test above: FLUSHALL stamps no
        # per-DB offset and a read of a flushed key is not deferred.
        $master config set sync-replication-block-reads no
        $master set noblock_flushall_key noblock_flushall_val
        $master debug aof-flush-force stall 1
        set rd_w [redis_deferring_client]
        set rd_r [redis_deferring_client]
        $rd_w flushall
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 1
        } else {
            fail "FLUSHALL did not chunk"
        }
        # No per-DB tracking when the feature is off.
        assert_equal 0 [s sync_repl_dirty_dbs_count]
        $rd_r get noblock_flushall_key
        assert_equal {} [$rd_r read]
        $master debug aof-flush-force stall 0
        assert_equal [$rd_w read] OK
        wait_for_condition 50 100 {
            [s sync_repl_pending_clients] == 0
        } else {
            fail "pending clients did not drain after resume"
        }
        $rd_w close ; $rd_r close
    }

    test {Scripted FLUSHALL: a cross-client read waits for the flush ACK} {
        # redis.call("FLUSHALL") executes on the script engine's client, but the
        # per-DB stamp must land on the real (EVAL) client so it is drained at
        # the EVAL epilogue with the EVAL's woff. If it instead landed on the
        # engine client it would never drain and the DB would not be stamped —
        # so this asserts the stamp took (sync_repl_dirty_dbs_count) and the
        # cross-client read is deferred.
        $master config set sync-replication-block-reads local
        $master set script_flushall_key script_flushall_val
        $master debug aof-flush-force stall 1
        set rd_w [redis_deferring_client]
        set rd_r [redis_deferring_client]
        set hold_before [s sync_repl_hold_depth_count]
        $rd_w eval {redis.call('flushall'); return 'done'} 0
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 1 &&
            ([s sync_repl_hold_depth_count] - $hold_before) >= 1
        } else {
            fail "scripted FLUSHALL did not chunk"
        }
        # The stamp must have landed on the real client and drained → DB dirty.
        assert {[s sync_repl_dirty_dbs_count] >= 1}
        $rd_r get script_flushall_key
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 2 &&
            ([s sync_repl_hold_depth_count] - $hold_before) >= 2
        } else {
            fail "read after a scripted FLUSHALL was not deferred"
        }
        if {[reply_arrived_within $rd_r 100]} {
            fail "read returned before the scripted FLUSHALL acked"
        }
        $master debug aof-flush-force stall 0
        assert_equal [$rd_w read] done
        assert_equal [$rd_r read] {}
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 0 && [s sync_repl_dirty_dbs_count] == 0
        } else {
            fail "pending clients / dirty DBs did not drain after resume"
        }
        $rd_w close ; $rd_r close
    }

    test {Block-reads cleanup: restore defaults} {
        $master config set sync-replication-block-reads no
        $master config set sync-replication-block-reads-on-expire no
        $master config set sync-replication-timeout 0
        $master config set maxmemory 0
        $master config set maxmemory-policy noeviction
        $master debug set-active-expire 1
    }
}


# ---------------------------------------------------------------------------
# Per-DB dirty offset: per-DB precision (FLUSHDB) and SWAPDB. Both need more
# than one database, so this block asks for databases=16 (cluster mode forces
# dbnum=1 and rejects SWAPDB). Mirrors the block-reads harness above: a stalled
# AOF flush holds chunks.
# FLUSHDB stamps only its DB, while SWAPDB stamps both swapped DBs.
# ---------------------------------------------------------------------------
start_server {tags {"aof bgalways external:skip"} overrides {appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0 databases 16}} {
    set master [srv 0 client]

    $master config set sync-replication-block-reads local

    test {FLUSHDB: reads wait only in the flushed DB} {
        # Seed a key in DB 1 (to be flushed) and DB 9 (untouched).
        $master select 1 ; $master set db1_key v1
        $master select 9 ; $master set db9_key v9
        $master select 0

        # Pre-select the deferring clients before pausing (SELECT doesn't chunk).
        set rd_w  [redis_deferring_client] ; $rd_w  select 1 ; assert_equal OK [$rd_w  read]
        set rd_d1 [redis_deferring_client] ; $rd_d1 select 1 ; assert_equal OK [$rd_d1 read]
        set rd_d9 [redis_deferring_client] ; $rd_d9 select 9 ; assert_equal OK [$rd_d9 read]

        $master debug aof-flush-force stall 1
        set hold_before [s sync_repl_hold_depth_count]
        $rd_w flushdb
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 1 &&
            ([s sync_repl_hold_depth_count] - $hold_before) >= 1
        } else {
            fail "FLUSHDB did not chunk"
        }
        # Exactly one DB (DB 1) must be marked dirty.
        assert_equal 1 [s sync_repl_dirty_dbs_count]
        set dirty_dbs [$master debug syncrep dirty-dbs]
        assert_equal 1 [lindex $dirty_dbs 0]
        assert {[lindex $dirty_dbs 1] > 0}

        # Reader in DB 1 (flushed) must be deferred.
        $rd_d1 get db1_key
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 2 &&
            ([s sync_repl_hold_depth_count] - $hold_before) >= 2
        } else {
            fail "read in the flushed DB was not deferred"
        }
        # Reader in DB 9 (untouched) must NOT be deferred — returns immediately.
        $rd_d9 get db9_key
        assert_equal v9 [$rd_d9 read]
        # The DB-1 reader is still held: confirm it is silent.
        if {[reply_arrived_within $rd_d1 100]} {
            fail "read in the flushed DB returned before the FLUSHDB acked"
        }
        # Resume → flush + held read drain; the read sees the durable nil.
        $master debug aof-flush-force stall 0
        assert_equal [$rd_w read] OK
        assert_equal [$rd_d1 read] {}
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 0 && [s sync_repl_dirty_dbs_count] == 0
        } else {
            fail "pending clients / dirty DBs did not drain after resume"
        }
        $rd_w close ; $rd_d1 close ; $rd_d9 close
    }

    test {SWAPDB: reads wait in both swapped DBs} {
        $master flushall
        $master select 1 ; $master set swap_key v1   ;# DB 2 has no swap_key
        $master select 0

        set rd_w  [redis_deferring_client]    ;# stays in DB 0; SWAPDB takes ids
        set rd_d1 [redis_deferring_client] ; $rd_d1 select 1 ; assert_equal OK [$rd_d1 read]
        set rd_d2 [redis_deferring_client] ; $rd_d2 select 2 ; assert_equal OK [$rd_d2 read]

        $master debug aof-flush-force stall 1
        set hold_before [s sync_repl_hold_depth_count]
        $rd_w swapdb 1 2
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 1 &&
            ([s sync_repl_hold_depth_count] - $hold_before) >= 1
        } else {
            fail "SWAPDB did not chunk"
        }
        # Both swapped DBs (1 and 2) must be marked dirty.
        assert_equal 2 [s sync_repl_dirty_dbs_count]
        set dirty_dbs [$master debug syncrep dirty-dbs]
        assert_equal {1 2} [list [lindex $dirty_dbs 0] [lindex $dirty_dbs 2]]

        # Reads in both swapped DBs must be deferred.
        $rd_d1 get swap_key
        $rd_d2 get swap_key
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 3 &&
            ([s sync_repl_hold_depth_count] - $hold_before) >= 3
        } else {
            fail "reads in the swapped DBs were not both deferred"
        }
        # Neither reader may receive bytes while the swap is unacked.
        foreach {rd tag} [list $rd_d1 d1 $rd_d2 d2] {
            if {[reply_arrived_within $rd 100]} {
                fail "reader $tag returned before the SWAPDB acked"
            }
        }
        # Resume → all drain; the swap is now observable:
        #   DB 1 received DB 2's (empty) contents → swap_key absent → nil;
        #   DB 2 received DB 1's swap_key=v1.
        $master debug aof-flush-force stall 0
        assert_equal [$rd_w read] OK
        assert_equal [$rd_d1 read] {}
        assert_equal [$rd_d2 read] v1
        wait_for_condition 100 50 {
            [s sync_repl_pending_clients] == 0 && [s sync_repl_dirty_dbs_count] == 0
        } else {
            fail "pending clients / dirty DBs did not drain after resume"
        }
        $rd_w close ; $rd_d1 close ; $rd_d2 close
    }

    test {Per-DB cleanup: restore defaults} {
        $master config set sync-replication-block-reads no
    }
}
