# sync-replication-block-reads evaluated on a REPLICA: a read served BY a
# replica, of a key its master wrote, is held until that write is durable in
# the replica's own AOF -- the `local` dimension, engaged by appendfsync
# bgalways on the replica. The replica's local fsync is stalled with
# DEBUG AOF-FLUSH-FORCE STALL to create the hold.
#
# The primary-side counterpart lives in sync-replication-block-reads.tcl. The
# write-side hold/drain gate itself lives in appendfsync-bgalways.tcl.
#
# Sections below: the replica's local durability dimension, passthrough
# replies, and demotion/failover of a held read.

# ===========================================================================
# Replica local AOF dirty-read tests
# ===========================================================================

# sync-replication-block-reads on a REPLICA: the LOCAL durability dimension.
#
# A replica can fsync its inbound master stream to its own AOF, so the `local`
# dimension IS satisfiable on a replica when appendfsync bgalways is engaged.
# A read on the replica of a key the master wrote is then held until that write
# is durable in the replica's own AOF. The key the read waits on is tagged with
# the master client's per-command stream offset (c->reploff_next), which lives
# in fsynced_reploff's space. The dirty dict stays bounded (cleanup advances on
# local fsync).
start_server {tags {"repl aof external:skip"} overrides {appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0}} {
start_server {tags {"repl aof external:skip"} overrides {appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0}} {
    set replica [srv 0 client]
    set master  [srv -1 client]

    assert_equal [$master waitaof 1 0 5000] {1 0}
    assert_equal [$replica waitaof 1 0 5000] {1 0}
    $replica replicaof [srv -1 host] [srv -1 port]
    wait_for_sync $replica
    wait_for_ofs_sync $master $replica
    # Wait out the replica's post-sync AOF rewrite, during which dirty tracking
    # is suppressed because fsynced_reploff is pinned at -1.
    waitForBgrewriteaof $replica

    test {replica local: read of a not-yet-durable master write is held until the replica fsyncs} {
        $replica config set sync-replication-block-reads local
        # Stall the replica's local fsync so fsynced_reploff cannot advance.
        $replica debug aof-flush-force stall 1

        # Master (plain) writes a key; the replica applies it in memory but its
        # local AOF has not fsynced it yet.
        $master set durable_key durable_val
        wait_for_ofs_sync $master $replica
        # The key is tracked dirty on the replica, tagged with the stream offset.
        wait_for_condition 100 50 {
            [s 0 sync_repl_dirty_keys_count] >= 1
        } else {
            fail "replica did not track the master-applied write as dirty"
        }
        set dirty [$replica debug syncrep dirty-keys]
        set idx [lsearch $dirty durable_key]
        assert {$idx >= 0}
        assert {[lindex $dirty [expr {$idx + 1}]] > 0}  ;# real woff, not 0

        # A read of durable_key from a deferring client must be HELD (replica fsync stalled).
        set rd [redis_deferring_client 0]
        set hold0 [s 0 sync_repl_hold_depth_count]
        $rd get durable_key
        wait_for_condition 100 50 {
            [s 0 sync_repl_hold_depth_count] > $hold0 && [s 0 sync_repl_pending_clients] >= 1
        } else {
            fail "read of a not-yet-durable key was not held on the replica"
        }
        # No bytes may reach the socket while the write is not yet locally durable.
        if {[reply_arrived_within $rd 150]} {
            fail "replica read reply reached the socket before the write was locally durable"
        }

        # Release the stall: the replica fsyncs, fsynced_reploff advances past the
        # write's offset, and both the held read and the dirty entry clear.
        $replica debug aof-flush-force stall 0
        assert_equal durable_val [$rd read]
        wait_for_condition 100 50 {
            [s 0 sync_repl_pending_clients] == 0
        } else {
            fail "held replica read did not drain after the local fsync advanced"
        }
        wait_for_condition 100 50 {
            [s 0 sync_repl_dirty_keys_count] == 0
        } else {
            fail "replica dirty dict did not drain after the local fsync advanced"
        }
        $rd close
        $replica config set sync-replication-block-reads no
    }

    test {replica local: a read in a flushed DB is held until the replica fsyncs the FLUSHALL} {
        # The per-DB analogue of the per-key test above. A FLUSHALL the master
        # applies wipes the keyspace; on the replica the now-absent key reads as
        # nil, but that nil is not durable until the replica fsyncs the FLUSHALL
        # to its own AOF — a restart before then would reload the pre-flush value.
        # So a read in the flushed DB must be held until the local fsync passes
        # the FLUSHALL's stream offset (tagged via the per-DB dirty offset).
        $replica config set sync-replication-block-reads local
        # Seed a durable key first, then stall the replica's local fsync.
        $master set flushed_key flushed_val
        wait_for_ofs_sync $master $replica
        $replica debug aof-flush-force stall 1

        $master flushall
        wait_for_ofs_sync $master $replica
        # The flushed DB is tracked dirty on the replica, tagged with a real woff.
        wait_for_condition 100 50 {
            [s 0 sync_repl_dirty_dbs_count] >= 1
        } else {
            fail "replica did not track the master-applied FLUSHALL as a dirty DB"
        }
        set dirty_dbs [$replica debug syncrep dirty-dbs]
        set idx [lsearch $dirty_dbs 0]
        assert {$idx >= 0}
        assert {[lindex $dirty_dbs [expr {$idx + 1}]] > 0}  ;# real woff, not 0

        # A read of the now-absent key must be HELD (local fsync stalled).
        set rd [redis_deferring_client 0]
        set hold0 [s 0 sync_repl_hold_depth_count]
        $rd get flushed_key
        wait_for_condition 100 50 {
            [s 0 sync_repl_hold_depth_count] > $hold0 && [s 0 sync_repl_pending_clients] >= 1
        } else {
            fail "read in a flushed DB was not held on the replica"
        }
        if {[reply_arrived_within $rd 150]} {
            fail "replica read reply reached the socket before the FLUSHALL was locally durable"
        }

        # Release the stall: the replica fsyncs, fsynced_reploff passes the
        # FLUSHALL offset, and both the held read and the dirty DB clear.
        $replica debug aof-flush-force stall 0
        assert_equal {} [$rd read]
        wait_for_condition 100 50 {
            [s 0 sync_repl_pending_clients] == 0 && [s 0 sync_repl_dirty_dbs_count] == 0
        } else {
            fail "held replica read / dirty DB did not drain after the local fsync advanced"
        }
        $rd close
        $replica config set sync-replication-block-reads no
    }

    foreach operation {{set reconnect_key value} {flushdb async}} {
        test "replica local: partial resync preserves dirty state for $operation" {
            $replica config set sync-replication-block-reads local
            $replica debug aof-flush-force stall 0
            $master set reconnect_key before
            wait_for_ofs_sync $master $replica
            wait_for_condition 100 20 {
                [s 0 sync_repl_dirty_keys_count] == 0 && [s 0 sync_repl_dirty_dbs_count] == 0
            } else {
                fail "warmup was not durable"
            }
            set before_reader [redis_deferring_client 0]
            set after_reader [redis_deferring_client 0]
            $replica debug aof-flush-force stall 1
            $master {*}$operation
            wait_for_ofs_sync $master $replica
            $before_reader get reconnect_key
            # This reader must already be held when the link breaks — that is
            # what the test is about, so don't let the kill below race it.
            wait_for_condition 100 10 {
                [s 0 sync_repl_pending_clients] == 1
            } else {
                fail "the pre-reconnect read was not held"
            }
            set partials [s -1 sync_partial_ok]
            assert_equal 1 [$master client kill type replica]
            wait_for_condition 100 50 {
                [s -1 sync_partial_ok] > $partials && [s 0 master_link_status] eq "up"
            } else {
                fail "replica did not partially resync"
            }
            if {[lindex $operation 0] eq "set"} {
                assert {[dict exists [$replica debug syncrep dirty-keys] reconnect_key]}
                set expected value
            } else {
                assert {[s 0 sync_repl_dirty_dbs_count] > 0}
                set expected {}
            }
            $after_reader get reconnect_key
            # The post-reconnect read must be held on the preserved dirty state
            # too, before the local fsync is allowed to release both.
            wait_for_condition 100 10 {
                [s 0 sync_repl_pending_clients] == 2
            } else {
                fail "the post-reconnect read was not held"
            }
            $replica debug aof-flush-force stall 0
            assert_equal $expected [$before_reader read]
            assert_equal $expected [$after_reader read]
            wait_for_condition 100 20 {
                [s 0 sync_repl_dirty_keys_count] == 0 && [s 0 sync_repl_dirty_dbs_count] == 0
            } else {
                fail "dirty state did not drain after local fsync"
            }
            $replica config set sync-replication-block-reads no
            $before_reader close
            $after_reader close
        }
    }

    foreach mode {no} {
        foreach operation {{set toggle_key value} {flushdb async}} {
            test "replica local: changing block-reads to $mode releases $operation readers" {
                $replica debug aof-flush-force stall 0
                $replica config set sync-replication-block-reads local
                $master set toggle_key before
                wait_for_ofs_sync $master $replica
                wait_for_condition 100 20 {
                    [s 0 sync_repl_dirty_keys_count] == 0 && [s 0 sync_repl_dirty_dbs_count] == 0
                } else {
                    fail "warmup was not durable"
                }
                set reader [redis_deferring_client 0]
                $replica debug aof-flush-force stall 1
                $master {*}$operation
                wait_for_ofs_sync $master $replica
                set expected [expr {[lindex $operation 0] eq "set" ? "value" : ""}]
                $reader get toggle_key
                $reader ping
                # Both replies must be parked: the GET as a read-dirty chunk and
                # the PING passthrough behind it (RESP ordering). The two
                # commands are pipelined fire-and-forget, so wait for the server
                # to have read and parked both before sampling the gauge.
                wait_for_condition 100 10 {
                    [s 0 sync_repl_pending_chunks] == 2
                } else {
                    fail "GET and the PING queued behind it were not both parked"
                }
                $replica config set sync-replication-block-reads $mode
                assert {[reply_arrived_within $reader 1000]}
                assert_equal $expected [$reader read]
                assert_equal PONG [$reader read]
                assert_equal $expected [$replica get toggle_key]
                wait_for_condition 100 20 {
                    [s 0 sync_repl_dirty_keys_count] == 0 && [s 0 sync_repl_dirty_dbs_count] == 0 &&
                    [s 0 sync_repl_pending_clients] == 0
                } else {
                    fail "disabled local protection left pending state"
                }
                $reader close
                $replica config set sync-replication-block-reads no
            }
        }
    }

    test {replica local: dirty dict stays bounded under a sustained write batch} {
        # With prompt (non-stalled) fsync, cleanup advances as the replica
        # fsyncs, so the dict does not grow without bound.
        # bgalways makes the local fsync prompt (WAITAOF is rejected on a replica
        # instance, so we can't checkpoint that way).
        $replica config set sync-replication-block-reads local
        $replica debug aof-flush-force stall 0
        for {set i 0} {$i < 500} {incr i} { $master set "batch_key:$i" "v$i" }
        wait_for_ofs_sync $master $replica
        # As the replica fsyncs the stream, the dict must drain back to empty.
        wait_for_condition 100 50 {
            [s 0 sync_repl_dirty_keys_count] == 0
        } else {
            fail "replica dirty dict did not drain to empty: [s 0 sync_repl_dirty_keys_count]"
        }
        # And a read of a now-durable key returns promptly.
        assert_equal v499 [$replica get batch_key:499]
        $replica config set sync-replication-block-reads no
    }
}
}


# ===========================================================================
# Replica passthrough reply tests
# ===========================================================================

# A pipelined read of a CLEAN key, queued behind a read of a dirty key on a
# replica, becomes a passthrough chunk (read_dirty=0). It must release with the
# dirty head once the head drains, otherwise the clean-key read hangs
# indefinitely.
start_server {tags {"repl aof external:skip"} overrides {appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0}} {
start_server {tags {"repl aof external:skip"} overrides {appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0}} {
    set replica [srv 0 client]
    set master  [srv -1 client]

    assert_equal [$master waitaof 1 0 5000] {1 0}
    assert_equal [$replica waitaof 1 0 5000] {1 0}
    $replica config set sync-replication-block-reads local
    $replica replicaof [srv -1 host] [srv -1 port]
    wait_for_sync $replica
    wait_for_ofs_sync $master $replica
    waitForBgrewriteaof $replica

    test {pipelined read of a CLEAN key behind a dirty read drains on the replica} {
        # clean_key: written and fully fsynced+cleaned on the replica.
        $master set clean_key clean_val
        wait_for_ofs_sync $master $replica
        wait_for_condition 100 50 {
            [s 0 sync_repl_dirty_keys_count] == 0
        } else {
            fail "clean_key never cleaned on replica"
        }

        # Stall the replica's local fsync so the next write stays dirty.
        $replica debug aof-flush-force stall 1
        $master set dirty_key dirty_val
        wait_for_ofs_sync $master $replica
        wait_for_condition 100 50 {
            [s 0 sync_repl_dirty_keys_count] >= 1
        } else {
            fail "dirty_key not tracked dirty"
        }

        # Pipeline two reads on the SAME replica connection, without reading between:
        #   GET dirty_key -> read_dirty=1 chunk (held on local fsync, correct)
        #   GET clean_key -> passthrough read_dirty=0 chunk (queued behind it)
        set rd [redis_deferring_client 0]
        $rd get dirty_key
        $rd get clean_key
        # Wait until BOTH chunks are parked (head read-dirty + passthrough), so we
        # don't race read2 being processed after read1 already drained.
        wait_for_condition 100 50 {
            [s 0 sync_repl_pending_chunks] == 2
        } else {
            fail "both pipelined reads were not parked (pending_chunks=[s 0 sync_repl_pending_chunks])"
        }

        # Release the fsync stall: fsynced_reploff advances past dirty_key's woff, so
        # the read_dirty=1 head drains and GET dirty_key returns.
        $replica debug aof-flush-force stall 0
        assert_equal dirty_val [$rd read]

        # GET clean_key is the passthrough (read_dirty=0) chunk. It must drain
        # right behind the head, since clean_key is clean.
        set arrived [reply_arrived_within $rd 2000]
        set hung [expr {!$arrived}]
        if {$arrived} { assert_equal clean_val [$rd read] }
        $rd close
        $replica config set sync-replication-block-reads no
        # Expected behavior: the clean-key read drains with the head, no hang.
        assert_equal 0 $hung
        assert_equal 0 [s 0 sync_repl_pending_clients]
    }
}
}


# ===========================================================================
# Demotion and failover dirty-read tests
# ===========================================================================

# sync-replication-block-reads across a demotion + failover (local dimension).
#
# block-reads holds a read of a "dirty" key -- one whose write is not yet
# durable -- until that write is fsynced to the local AOF. When a primary holds
# such a write (its local fsync is stalled) and is then demoted, the dirty
# tracking must SURVIVE the demotion so the read stays blocked even as a replica
# -- serving it would be a phantom read of a value the imminent failover might
# erase.
#
# How that read finally resolves depends on what the failover does to the write:
#
#   Scenario 1 (ROLLBACK): the promoted replica never received the write, so the
#   demoted node FULL-resyncs from it. The dataset is replaced, the captured
#   reply is stale, the held reader is disconnected (reconnect + re-read => nil).
#
#   Scenario 2 (COMMIT): the promoted replica DID receive the write (in its
#   socket buffer; it applies it on resume) and so is at the same offset. The
#   demoted node PARTIAL-resyncs from it on the same replid lineage -- the write
#   is now committed, so the held read is SERVED its captured value (no timeout,
#   no disconnect).
#
# Both scenarios hinge on the dirty dict's lifetime around a role change:
# flushing it in replicationSetMaster would serve scenario-1's read during the
# demotion window, while never releasing it on a partial resync would leave
# scenario-2's read hanging until sync-replication-timeout.

# ---------------------------------------------------------------------------
# Scenario 1: rollback via full resync — the held read is dropped, key gone.
# ---------------------------------------------------------------------------
start_server {tags {"repl network aof external:skip"} overrides {appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0}} {
start_server {overrides {appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0}} {
    set replica [srv 0 client]
    set replica_host [srv 0 host]
    set replica_port [srv 0 port]
    set replica_pid [srv 0 pid]
    set master [srv -1 client]
    set master_pid [srv -1 pid]

    $replica replicaof [srv -1 host] [srv -1 port]
    wait_for_sync $replica
    wait_for_ofs_sync $master $replica
    $master config set replica-serve-stale-data yes
    $replica config set replica-serve-stale-data yes
    $master config set repl-diskless-sync-delay 0
    $replica config set repl-diskless-sync-delay 0
    $master config set sync-replication-block-reads local

    test {Demote holds an unacked read; rollback (full resync) drops it} {
        $master del rollback_key
        wait_for_ofs_sync $master $replica

        # Sever the replica, then accept a write it can never receive. A plain
        # SIGSTOP would still buffer the write in the replica's socket and it
        # would apply it on resume (that is scenario 2); killing the link first
        # guarantees a true rollback. The write is held (local fsync stalled) and dirty.
        pause_process $replica_pid
        $master debug aof-flush-force stall 1
        assert_equal 1 [$master client kill type replica]
        wait_for_condition 50 50 {
            [s -1 connected_slaves] == 0
        } else {
            fail "replica link was not dropped on the master"
        }
        set rd [redis_deferring_client -1]
        set hold_before [s -1 sync_repl_hold_depth_count]
        set before_disc [s -1 sync_repl_role_loss_disconnects]
        $rd set rollback_key rollback_val
        wait_for_condition 100 50 {
            [s -1 sync_repl_pending_clients] == 1 &&
            [s -1 sync_repl_hold_depth_count] > $hold_before &&
            [s -1 sync_repl_dirty_keys_count] >= 1
        } else {
            fail "write did not become held+dirty (pending=[s -1 sync_repl_pending_clients] dirty=[s -1 sync_repl_dirty_keys_count])"
        }
        set dirty [$master debug syncrep dirty-keys]
        assert {[lsearch $dirty rollback_key] >= 0}

        # Demote to a replica of its own (still-paused) replica. The dirty entry
        # must SURVIVE the demotion (replicationSetMaster must not flush it).
        # The held WRITER is force-dropped on role loss.
        $master replicaof $replica_host $replica_port
        wait_for_condition 50 100 {
            [s -1 role] eq {slave} &&
            [s -1 sync_repl_role_loss_disconnects] > $before_disc &&
            [s -1 sync_repl_pending_clients] == 0
        } else {
            fail "demotion did not complete / writer not dropped (role=[s -1 role] pending=[s -1 sync_repl_pending_clients])"
        }
        catch {$rd read} err
        assert_match {*I/O*} $err
        $rd close
        assert {[s -1 sync_repl_dirty_keys_count] >= 1}

        # A read of the orphaned key on the demoted node MUST be held.
        set rd2 [redis_deferring_client -1]
        $rd2 get rollback_key
        if {[reply_arrived_within $rd2 300]} {
            fail "read of an unacked, demotion-orphaned write was served (got '$v')"
        }
        assert {[s -1 sync_repl_pending_clients] >= 1}

        # Disabling local read protection must not release a captured value
        # from an actual demotion: that value still needs reconciliation.
        $master config set sync-replication-block-reads no
        assert {[s -1 sync_repl_dirty_keys_count] > 0}
        $master config set sync-replication-block-reads local

        # Failover: pause the old master, promote the clean replica (no rollback_key).
        pause_process $master_pid
        resume_process $replica_pid
        $replica replicaof no one
        wait_for_condition 50 100 {
            [s 0 role] eq {master}
        } else {
            fail "replica did not promote to master"
        }
        assert_equal 0 [$replica exists rollback_key]

        # Resume the old master; it FULL-resyncs (its tip is ahead with the
        # uncommitted write), reconciling the keyspace and flushing the dirty
        # tracking.
        resume_process $master_pid
        wait_for_condition 100 100 {
            [s -1 master_link_status] eq {up} &&
            [s -1 sync_repl_dirty_keys_count] == 0
        } else {
            fail "old master did not resync (link=[s -1 master_link_status] dirty=[s -1 sync_repl_dirty_keys_count])"
        }
        assert {[s 0 sync_full] >= 1}

        # The held read was dropped on resync (its captured value was rolled
        # back) — the client sees a disconnect, never a phantom 'rollback_val'.
        catch {$rd2 read} err2
        assert_match {*I/O*} $err2
        $rd2 close
        assert_equal 0 [$master exists rollback_key]
        assert_equal {} [$master get rollback_key]
        assert_equal 0 [$replica exists rollback_key]
    }
}
}

# ---------------------------------------------------------------------------
# Scenario 2: commit via partial resync — the held read is served, key kept.
# ---------------------------------------------------------------------------
start_server {tags {"repl network aof external:skip"} overrides {appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0}} {
start_server {overrides {appendonly yes appendfsync bgalways auto-aof-rewrite-percentage 0}} {
    set replica [srv 0 client]
    set replica_host [srv 0 host]
    set replica_port [srv 0 port]
    set replica_pid [srv 0 pid]
    set master [srv -1 client]
    set master_pid [srv -1 pid]

    $replica replicaof [srv -1 host] [srv -1 port]
    wait_for_sync $replica
    wait_for_ofs_sync $master $replica
    $master config set replica-serve-stale-data yes
    $replica config set replica-serve-stale-data yes
    $master config set repl-diskless-sync-delay 0
    $replica config set repl-diskless-sync-delay 0
    # A missing partial-resync release must hit the bounded wait in the test,
    # rather than eventually escaping through the sync-replication timeout.
    $master config set sync-replication-timeout 0
    $master config set sync-replication-block-reads local

    test {Demote holds an unacked read; commit (partial resync) serves it} {
        $master del commit_key
        wait_for_ofs_sync $master $replica

        # Pause the replica WITHOUT killing its link: the write still reaches its
        # socket buffer, so it applies it on resume and catches up to the same
        # offset — the difference from scenario 1. The write is held (local
        # fsync stalled) and tracked dirty.
        pause_process $replica_pid
        $master debug aof-flush-force stall 1
        set rd [redis_deferring_client -1]
        set before_disc [s -1 sync_repl_role_loss_disconnects]
        $rd set commit_key commit_val
        wait_for_condition 100 50 {
            [s -1 sync_repl_pending_clients] == 1 &&
            [s -1 sync_repl_dirty_keys_count] >= 1
        } else {
            fail "write did not become held+dirty (pending=[s -1 sync_repl_pending_clients] dirty=[s -1 sync_repl_dirty_keys_count])"
        }

        # Demote; dirty survives, held writer dropped.
        $master replicaof $replica_host $replica_port
        wait_for_condition 50 100 {
            [s -1 role] eq {slave} &&
            [s -1 sync_repl_role_loss_disconnects] > $before_disc &&
            [s -1 sync_repl_pending_clients] == 0
        } else {
            fail "demotion did not complete (role=[s -1 role] pending=[s -1 sync_repl_pending_clients])"
        }
        catch {$rd read} err
        assert_match {*I/O*} $err
        $rd close
        assert {[s -1 sync_repl_dirty_keys_count] >= 1}

        # The read of the orphaned key must be held here too.
        set rd2 [redis_deferring_client -1]
        $rd2 get commit_key
        if {[reply_arrived_within $rd2 300]} {
            fail "orphaned read was served before failover (got '$v')"
        }
        assert {[s -1 sync_repl_pending_clients] >= 1}

        # Failover: pause old master; resume the replica so it APPLIES the
        # buffered write (now at the same offset), then promote it.
        pause_process $master_pid
        resume_process $replica_pid
        wait_for_condition 50 100 {
            [$replica get commit_key] eq {commit_val}
        } else {
            fail "replica did not apply the buffered write"
        }
        $replica replicaof no one
        wait_for_condition 50 100 {
            [s 0 role] eq {master}
        } else {
            fail "replica did not promote"
        }

        # Resume the old master; it PARTIAL-resyncs (same offset, same lineage).
        # The write is committed, so the held read must be SERVED its captured
        # value — not disconnected, not timed out. The partial resync does not
        # make the write locally durable, so release the fsync stall too.
        resume_process $master_pid
        $master debug aof-flush-force stall 0
        wait_for_condition 100 100 {
            [s -1 master_link_status] eq {up} &&
            [s -1 sync_repl_dirty_keys_count] == 0 &&
            [s -1 sync_repl_pending_clients] == 0
        } else {
            fail "held read not released after partial resync (link=[s -1 master_link_status] dirty=[s -1 sync_repl_dirty_keys_count] pending=[s -1 sync_repl_pending_clients])"
        }
        # Prove it was a partial resync (the new master accepted +CONTINUE),
        # i.e. we exercised the commit path, not a full resync.
        assert {[s 0 sync_partial_ok] >= 1}
        assert_equal 0 [s 0 sync_full]

        # The held read is served its captured, now-committed value.
        assert_equal commit_val [$rd2 read]
        $rd2 close
        assert_equal commit_val [$master get commit_key]
        assert_equal commit_val [$replica get commit_key]
    }
}
}
