# appendfsync bgalways — background fsync for "always" durability

## Motivation
`appendfsync always` fsyncs the AOF synchronously on the main thread before replying, so the event
loop is serialized behind the disk and throughput is bounded by `batch_size / fsync_latency`.
`appendfsync bgalways` keeps the same client guarantee — a reply is sent only after the data it
depends on is durable — but moves the fsync to the bio thread and **holds replies** until the bio
fsync completes, instead of blocking the main thread. Writes group-commit: while one fsync is in
flight, the next batch accumulates and is flushed+fsynced as soon as the previous one returns.

## Guarantee
- **Writes:** a client's reply to a propagating command is held until `fsynced_reploff` reaches that
  command's replication offset (`woff`), i.e. until the data is on disk. "ack ⇒ durable" is
  preserved exactly as in classic `always`.
- **Reads:** a read may observe a write that is not yet durable, and its reply is sent immediately.
  On a crash before that write's fsync, a reader could have observed a value that is then lost.
  (Classic `always` has no such window because the write's own reply came after its fsync. Restoring
  read-your-writes under `bgalways` requires per-key read gating, which is not part of this change.)

## Mechanism
Reply holding is implemented as per-command reply chunking in `networking.c`:

- Each propagating command's reply bytes are moved out of `c->buf` / `c->reply` into a
  `syncReplyChunk` tagged with `woff` and parked on `c->sync_pending_replies`
  (`syncReplStartCommand` at the head of `call()`, `syncReplFinishCommand` at its tail). The client
  is not blocked; only its bytes are withheld.
- The gate is `syncReplWaitLocalAof()`: `appendfsync bgalways && aof_enabled && fsynced_reploff != -1`.
- `flushAppendOnlyFile()` fires a bio fsync after every flush (no 1s interval) while no fsync is in
  flight — that "in flight" test is what makes writes group-commit. The bio worker advances
  `fsynced_reploff_pending` monotonically (`aofAdvanceFsyncedReploff`, atomic-max, so a late
  completion can never regress the durable offset).
- `beforeSleep` copies the pending offset into `fsynced_reploff` (`aofRefreshFsyncedReploff`) and
  `drainSyncPendingReplies()` splices every chunk whose `woff` is covered back into `c->reply`.
  A bio completion-request (`bioCreateCompRq`, queued FIFO right behind the fsync job) runs the same
  refresh+drain on the main thread the moment the fsync lands, so held replies are released promptly
  even on an otherwise idle server.
- Chunks drain head-first only: a non-releasable chunk blocks everything behind it, and a
  non-propagating reply that arrives while a chunk is parked is itself chunked with `woff = 0`
  (passthrough) so single-connection RESP order is preserved.
- **No `AE_BARRIER`.** Classic `always` installs the event-loop write barrier
  (`installClientWriteHandler`) so a not-yet-fsynced reply sitting in `c->reply` can't be flushed to
  the socket in the same iteration as the read that produced it. `bgalways` deliberately skips that
  barrier: because the reply is parked outside `c->reply` until `fsynced_reploff` covers its `woff`,
  a non-durable reply can never reach the socket regardless of read/write interleaving — the holding
  list enforces "no reply before durable" structurally.

## Durability model (vs classic always)
Like `everysec`, data can reach memory and replicas before it is locally durable; on a crash before
fsync, un-acked tail writes are lost and a replica may be ahead. Because the client was never acked,
there is no contract violation; divergence is handled by the existing failover/PSYNC machinery. This
differs from classic `always`, where data is on disk before it is ever observable.

## Edge cases & operational notes
- **no-appendfsync-on-rewrite is ignored under bgalways.** The fsync is off the main thread, so the
  original I/O-contention rationale doesn't apply, and honoring it would stop `fsynced_reploff` from
  advancing and hang every held client for the duration of a rewrite.
- **appendonly no.** Gating does not engage (no AOF), so clients are never held.
- **Initial AOF rewrite.** While `fsynced_reploff == -1`, gating is suppressed so clients are not
  held for the whole rewrite.
- **Slow/stuck disk.** Held replies count toward the client output-buffer limit; a slow disk grows
  per-client pending bytes and can trip OBL (per-client disconnect) — the `bgalways` analogue of
  classic `always` stalling the server.
- **write/fsync error.** Soft-fail: new writes rejected with `-MISCONF`
  (`writeCommandsDeniedByDiskError`), and held clients are disconnected (their data can no longer be
  made durable). This covers both a background bio-thread fsync failure (`aof_bio_fsync_status`) and
  a main-thread write/forced-fsync failure (`aof_last_write_status`). No `exit(1)`.
- **Forced fsync (shutdown / stopAppendOnly / rewrite-done).** Done synchronously after draining the
  bio AOF worker, so a late bio completion cannot regress the durable offset.
- **Config switching.** Switching `appendfsync` into/out of `always`/`bgalways` drains the bio AOF
  worker first. Switching away from `bgalways` releases held replies under the new policy's
  semantics.
- **Demotion to replica.** `REPLICAOF` disconnects clients still holding chunks
  (`disconnectAllSyncRepPendingClients`): the offset they wait on belongs to the old primary's offset
  space and the write may be rolled back by the new master. This must also catch a blocking-async
  FLUSH client still sitting in `BLOCKED_LAZYFREE` when the demotion happens, i.e. before the BIO
  lazyfree job has completed and produced that reply — `disconnectAllBlockedClients()`'s
  `BLOCKED_LAZYFREE` branch (`blocked.c`) brackets that `+OK`/empty-array the same way
  `unblockClientForAsyncFlush` does (gated on `c->woff`, the offset the FLUSH already propagated
  before blocking), so if the reply ends up chunked, the `disconnectAllSyncRepPendingClients` sweep
  right after (in `replicationSetMaster`) catches this client too, instead of unconditionally
  answering `+OK` for a write that is about to vanish.
- **Blocking-async FLUSH.** A SYNC `FLUSHALL`/`FLUSHDB` that runs as a blocking-async flush produces
  its `+OK` in the bio completion callback, outside `call()`; that reply is bracketed and chunked
  there (`unblockClientForAsyncFlush`) so it is held like any other write. See "Demotion to replica"
  above for the same reply produced instead by `disconnectAllBlockedClients()`, on the still-blocked
  path.
- **Blocked-on-keys commands (BLPOP/BRPOPLPUSH/BLMOVE/BZPOPMIN/BZMPOP, blocking XREADGROUP).**
  `unblockClientOnKey` (`blocked.c`) reissues the command by wrapping its own `call()` in an
  `enterExecutionUnit`, so that reissued `call()` sees `execution_nesting != 0` and skips its usual
  `syncReplStartCommand`/`syncReplFinishCommand` bracketing — and, more importantly, the reissue's own
  propagation flush (`afterCommandEx` → `postExecutionUnitOperationsEx`, itself gated on
  `execution_nesting == 0`) doesn't happen until `unblockClientOnKey`'s own `exitExecutionUnit()` +
  `afterCommand()` run, i.e. strictly after that inner `call()` has already returned. So `call()` can
  never correctly decide "did this propagate" for a reissue. `unblockClientOnKey` therefore does its
  own `syncReplStartCommand`/… bracketing around the *whole* reissue (command + unblock handler),
  finishing it (via the shared `syncReplFinishOrDeferChunk`) only after its own `afterCommand()` call —
  the same "bracket outside `call()`" pattern as the blocking-async FLUSH case above. Without this, a
  reissued command's reply is delivered as soon as it's produced, unheld, breaking "ack ⇒ durable" for
  this entire command class (see `tests/integration/appendfsync-bgalways.tcl`, "a blocked command's
  reply is held until its pop is durable").
- **Module clients blocked on keys.** `moduleTryServeClientBlockedOnKey` (keys path) and
  `moduleHandleBlockedClients` (generic path, `module.c`) both deliver a module's blocked-command reply
  straight from `bc->reply_callback`, entirely outside `call()`. Unlike the blocked-on-keys case above,
  `CLIENT_BLOCKED` is cleared *asynchronously* here (only once `moduleHandleBlockedClients` later drains
  `moduleUnblockedClients`), so it's still set at the moment the reply is produced — the shared
  `syncReplFinishOrDeferChunk` can't be reused as-is, since its `CLIENT_BLOCKED` check would read that as
  "reply not produced yet, defer" and never chunk it. Both call sites instead bracket the
  `reply_callback` call directly with `syncReplStartCommand`/`syncReplFinishByOffset` (the offset-decision
  half of `syncReplFinishOrDeferChunk`, extracted so both share the chunk-vs-passthrough logic without
  the `CLIENT_BLOCKED` gate), using a locally captured pre-callback `server.master_repl_offset` in place
  of `call()`'s `sync_pre_command_repl_offset`.
- **Not gated:** keyspace notifications, pub/sub messages, and client-side-caching invalidations are
  pushed outside the command reply path and are not held; under `bgalways` they may be emitted
  slightly before the corresponding write is durable.
- **Pipelines / io-threads.** Every write goes through reply chunking, so the RESP-ordering guards
  are exercised on the hot path: `sync_rep_force_new_block` forces a fresh node instead of
  in-place-extending a prior reply's tail block, and `sync_rep_boundary_node` (same lifetime, but not
  one-shot) stops `setDeferredReply()` from merging a deferred header — e.g. `KEYS`/`SCAN`'s array
  length, filled in only after the array's elements were already appended — backward into that same
  prior block. Mixed read/write pipelines with `io-threads > 1` are part of the test matrix.

## Configuration
- `appendfsync bgalways` — enable. Default remains `everysec`; classic `always` is unchanged.

## Introspection (INFO stats)
- `sync_repl_pending_clients` — clients currently holding at least one parked chunk (gauge).
- `sync_repl_pending_commands` — parked chunks (gauge).
- `sync_repl_hold_count` — chunks ever parked (counter).
- `sync_repl_hold_depth_sum` — sum of queue depth at park time; `/hold_count` gives the average
  number of commands held together (counter).
- `sync_repl_hold_latency_usec` — total time chunks spent parked (counter).
- `sync_repl_pending_disconnects` — clients dropped while holding chunks, i.e. AOF error or demotion
  (counter).

## Testing
`tests/integration/appendfsync-bgalways.tcl`, driven by two fault-injection hooks:
`DEBUG AOF-FLUSH-FORCE-STALL <0|1>` (skip the flush so the durable offset stalls) and
`DEBUG AOF-FLUSH-FORCE-ERROR <0|1>` (fail the flush and set the AOF write-error status).
