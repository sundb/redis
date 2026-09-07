/* io_uring batch I/O engine for Redis
 *
 * Copyright (c) 2024-Present, Redis Ltd.
 * All rights reserved.
 *
 * Licensed under your choice of (a) the Redis Source Available License 2.0
 * (RSALv2); or (b) the Server Side Public License v1 (SSPLv1); or (c) the
 * GNU Affero General Public License v3 (AGPLv3).
 */

#include "server.h"

#ifdef HAVE_IO_URING

#include "io_uring_batch.h"
#include <string.h>
#include <errno.h>

#define IO_BATCH_INITIAL_CAPACITY 64

/* Encode operation index + type into CQE user_data for completion routing */
#define BATCH_USERDATA(idx, type) (((uint64_t)(unsigned)(idx)) | ((uint64_t)(type) << 32))
#define BATCH_USERDATA_IDX(ud)   ((int)((ud) & 0xFFFFFFFF))
#define BATCH_USERDATA_TYPE(ud)  ((int)((ud) >> 32))

ioBatchState *ioBatchCreate(int sq_size) {
    ioBatchState *batch = zmalloc(sizeof(ioBatchState));
    if (!batch) return NULL;
    memset(batch, 0, sizeof(*batch));

    if (sq_size <= 0) sq_size = IO_BATCH_DEFAULT_SQ_SIZE;
    batch->sq_size = sq_size;

    if (io_uring_queue_init(sq_size, &batch->ring, 0) < 0) {
        zfree(batch);
        return NULL;
    }
    batch->ring_initialized = 1;

    batch->write_capacity = IO_BATCH_INITIAL_CAPACITY;
    batch->write_ops = zmalloc(sizeof(ioBatchOp) * batch->write_capacity);
    batch->write_count = 0;

    batch->read_capacity = IO_BATCH_INITIAL_CAPACITY;
    batch->read_ops = zmalloc(sizeof(ioBatchOp) * batch->read_capacity);
    batch->read_count = 0;

    batch->inflight_writes = 0;
    batch->inflight_reads = 0;
    batch->batch_writes_enabled = 1;
    batch->batch_reads_enabled = 0;

    return batch;
}

void ioBatchFree(ioBatchState *batch) {
    if (!batch) return;

    /* Free any pending iovec arrays */
    for (int i = 0; i < batch->write_count; i++) {
        if (batch->write_ops[i].iov)
            zfree(batch->write_ops[i].iov);
    }
    for (int i = 0; i < batch->read_count; i++) {
        if (batch->read_ops[i].iov)
            zfree(batch->read_ops[i].iov);
    }

    if (batch->ring_initialized)
        io_uring_queue_exit(&batch->ring);

    zfree(batch->write_ops);
    zfree(batch->read_ops);
    zfree(batch);
}

static void ioBatchGrowWriteOps(ioBatchState *batch) {
    batch->write_capacity *= 2;
    batch->write_ops = zrealloc(batch->write_ops,
                                sizeof(ioBatchOp) * batch->write_capacity);
}

static void ioBatchGrowReadOps(ioBatchState *batch) {
    batch->read_capacity *= 2;
    batch->read_ops = zrealloc(batch->read_ops,
                               sizeof(ioBatchOp) * batch->read_capacity);
}

/* Queue a write operation. The caller provides an iovec array that has been
 * built from the client's output buffers. The iovec is OWNED by the batch
 * state and will be freed after completion or on cleanup. */
int ioBatchAddWrite(ioBatchState *batch, struct client *c, int fd,
                    struct iovec *iov, int iovcnt, size_t total_len) {
    if (!batch || !batch->batch_writes_enabled) return -1;
    if (batch->write_count >= batch->write_capacity)
        ioBatchGrowWriteOps(batch);

    ioBatchOp *op = &batch->write_ops[batch->write_count];
    op->c = c;
    op->fd = fd;
    op->type = IO_BATCH_OP_WRITE;
    op->iov = iov;
    op->iovcnt = iovcnt;
    op->total_len = total_len;
    batch->write_count++;
    return 0;
}

/* Submit all queued write operations to the io_uring ring. */
int ioBatchSubmitWrites(ioBatchState *batch) {
    if (!batch || batch->write_count == 0) return 0;

    int submitted = 0;
    for (int i = 0; i < batch->write_count; i++) {
        ioBatchOp *op = &batch->write_ops[i];
        struct io_uring_sqe *sqe = io_uring_get_sqe(&batch->ring);
        if (!sqe) break;

        io_uring_prep_writev(sqe, op->fd, op->iov, op->iovcnt, 0);
        sqe->flags |= IOSQE_ASYNC;
        io_uring_sqe_set_data64(sqe, BATCH_USERDATA(i, IO_BATCH_OP_WRITE));
        submitted++;
    }

    if (submitted > 0) {
        int ret = io_uring_submit(&batch->ring);
        if (ret < 0) {
            serverLog(LL_WARNING, "io_uring batch write submit failed: %s",
                      strerror(-ret));
            return -1;
        }
        batch->inflight_writes = submitted;
    }
    return submitted;
}

/* Harvest write completion CQEs. Returns number of completions processed.
 * For each completed write, updates the client's sentlen and frees
 * consumed reply blocks. */
int ioBatchHarvestWrites(ioBatchState *batch) {
    if (!batch || batch->inflight_writes == 0) return 0;

    struct io_uring_cqe *cqe;
    unsigned head;
    int harvested = 0;
    int seen = 0;

    io_uring_for_each_cqe(&batch->ring, head, cqe) {
        uint64_t ud = io_uring_cqe_get_data64(cqe);
        int type = BATCH_USERDATA_TYPE(ud);
        int idx = BATCH_USERDATA_IDX(ud);
        seen++;

        if (type != IO_BATCH_OP_WRITE) continue;
        if (idx < 0 || idx >= batch->write_count) continue;

        ioBatchOp *op = &batch->write_ops[idx];
        client *c = op->c;

        if (cqe->res >= 0) {
            ssize_t nwritten = cqe->res;
            c->net_output_bytes += nwritten;

            /* Update sentlen for the fixed buffer part */
            if (c->bufpos > 0) {
                ssize_t buf_remaining = c->bufpos - c->sentlen;
                if (nwritten >= buf_remaining) {
                    nwritten -= buf_remaining;
                    c->bufpos = 0;
                    c->sentlen = 0;
                } else {
                    c->sentlen += nwritten;
                    nwritten = 0;
                }
            }

            /* Update sentlen for reply list blocks */
            while (nwritten > 0 && listLength(c->reply)) {
                clientReplyBlock *o = listNodeValue(listFirst(c->reply));
                ssize_t block_remaining = o->used - c->sentlen;
                if (nwritten >= block_remaining) {
                    nwritten -= block_remaining;
                    c->reply_bytes -= o->size;
                    listDelNode(c->reply, listFirst(c->reply));
                    c->sentlen = 0;
                } else {
                    c->sentlen += nwritten;
                    nwritten = 0;
                }
            }
        } else if (cqe->res != -EAGAIN) {
            /* Write error: mark connection for closing */
            c->conn->last_errno = -cqe->res;
            if (c->conn->state == CONN_STATE_CONNECTED)
                c->conn->state = CONN_STATE_ERROR;
        }

        /* Free the iovec for this op */
        if (op->iov) {
            zfree(op->iov);
            op->iov = NULL;
        }
        harvested++;
    }
    io_uring_cq_advance(&batch->ring, seen);

    batch->inflight_writes -= harvested;
    if (batch->inflight_writes < 0) batch->inflight_writes = 0;

    /* Reset write queue for next batch */
    batch->write_count = 0;
    return harvested;
}

/* Queue a read operation for batch submission. */
int ioBatchAddRead(ioBatchState *batch, struct client *c, int fd,
                   void *buf, size_t buf_len) {
    if (!batch || !batch->batch_reads_enabled) return -1;
    if (batch->read_count >= batch->read_capacity)
        ioBatchGrowReadOps(batch);

    ioBatchOp *op = &batch->read_ops[batch->read_count];
    op->c = c;
    op->fd = fd;
    op->type = IO_BATCH_OP_READ;

    /* Build a single-element iovec */
    op->iov = zmalloc(sizeof(struct iovec));
    op->iov[0].iov_base = buf;
    op->iov[0].iov_len = buf_len;
    op->iovcnt = 1;
    op->total_len = buf_len;
    batch->read_count++;
    return 0;
}

/* Submit all queued read operations. */
int ioBatchSubmitReads(ioBatchState *batch) {
    if (!batch || batch->read_count == 0) return 0;

    int submitted = 0;
    for (int i = 0; i < batch->read_count; i++) {
        ioBatchOp *op = &batch->read_ops[i];
        struct io_uring_sqe *sqe = io_uring_get_sqe(&batch->ring);
        if (!sqe) break;

        io_uring_prep_readv(sqe, op->fd, op->iov, op->iovcnt, 0);
        sqe->flags |= IOSQE_ASYNC;
        io_uring_sqe_set_data64(sqe, BATCH_USERDATA(i, IO_BATCH_OP_READ));
        submitted++;
    }

    if (submitted > 0) {
        int ret = io_uring_submit(&batch->ring);
        if (ret < 0) {
            serverLog(LL_WARNING, "io_uring batch read submit failed: %s",
                      strerror(-ret));
            return -1;
        }
        batch->inflight_reads = submitted;
    }
    return submitted;
}

/* Harvest read completions. For each completed read, updates the
 * client's querybuf and triggers input processing. */
int ioBatchHarvestReads(ioBatchState *batch) {
    if (!batch || batch->inflight_reads == 0) return 0;

    struct io_uring_cqe *cqe;
    unsigned head;
    int harvested = 0;
    int seen = 0;

    io_uring_for_each_cqe(&batch->ring, head, cqe) {
        uint64_t ud = io_uring_cqe_get_data64(cqe);
        int type = BATCH_USERDATA_TYPE(ud);
        int idx = BATCH_USERDATA_IDX(ud);
        seen++;

        if (type != IO_BATCH_OP_READ) continue;
        if (idx < 0 || idx >= batch->read_count) continue;

        ioBatchOp *op = &batch->read_ops[idx];
        client *c = op->c;

        if (cqe->res > 0) {
            ssize_t nread = cqe->res;
            sdsIncrLen(c->querybuf, nread);
            c->net_input_bytes += nread;
            c->lastinteraction = server.unixtime;
            atomicIncr(server.stat_net_input_bytes, nread);
        } else if (cqe->res == 0) {
            /* EOF */
            c->conn->state = CONN_STATE_CLOSED;
        } else if (cqe->res != -EAGAIN) {
            c->conn->last_errno = -cqe->res;
            if (c->conn->state == CONN_STATE_CONNECTED)
                c->conn->state = CONN_STATE_ERROR;
        }

        if (op->iov) {
            zfree(op->iov);
            op->iov = NULL;
        }
        harvested++;
    }
    io_uring_cq_advance(&batch->ring, seen);

    batch->inflight_reads -= harvested;
    if (batch->inflight_reads < 0) batch->inflight_reads = 0;

    batch->read_count = 0;
    return harvested;
}

/* Build an iovec from a client's output buffers (buf + reply list) and
 * queue it for batch submission. Returns 0 on success, -1 on failure. */
int ioBatchAddClientWrite(struct client *c, ioBatchState *batch) {
    if (!batch || !c) return -1;

    int max_iov = IO_BATCH_MAX_IOVEC;
    struct iovec *iov = zmalloc(sizeof(struct iovec) * max_iov);
    int iovcnt = 0;
    size_t total = 0;

    /* Add the fixed buffer */
    if (c->bufpos > 0 && !c->buf_encoded) {
        iov[iovcnt].iov_base = c->buf + c->sentlen;
        iov[iovcnt].iov_len = c->bufpos - c->sentlen;
        total += iov[iovcnt].iov_len;
        iovcnt++;
    }

    /* Add reply list blocks */
    if (listLength(c->reply) > 0) {
        size_t offset = c->bufpos > 0 ? 0 : c->sentlen;
        listIter iter;
        listNode *next;
        listRewind(c->reply, &iter);
        while ((next = listNext(&iter)) && iovcnt < max_iov) {
            clientReplyBlock *o = listNodeValue(next);
            if (o->used == 0) continue;
            if (o->buf_encoded) {
                /* Encoded blocks need the complex writev path; bail out
                 * and let the caller use the synchronous code path. */
                zfree(iov);
                return -1;
            }
            iov[iovcnt].iov_base = o->buf + offset;
            iov[iovcnt].iov_len = o->used - offset;
            total += iov[iovcnt].iov_len;
            iovcnt++;
            offset = 0;
        }
    }

    if (iovcnt == 0) {
        zfree(iov);
        return 0;
    }

    return ioBatchAddWrite(batch, c, c->conn->fd, iov, iovcnt, total);
}

/* Prepare a client's querybuf for a batch read and queue the operation. */
int ioBatchAddClientRead(struct client *c, ioBatchState *batch) {
    if (!batch || !c || !c->conn || c->conn->fd < 0) return -1;

    size_t readlen = PROTO_IOBUF_LEN;
    if (c->querybuf == NULL) {
        c->querybuf = sdsempty();
    }

    size_t qblen = sdslen(c->querybuf);
    if (sdsavail(c->querybuf) < readlen) {
        c->querybuf = sdsMakeRoomFor(c->querybuf, readlen - sdsavail(c->querybuf));
    }

    void *buf = c->querybuf + qblen;
    size_t buf_len = sdsavail(c->querybuf);

    return ioBatchAddRead(batch, c, c->conn->fd, buf, buf_len);
}

int ioBatchPendingWrites(ioBatchState *batch) {
    return batch ? batch->write_count : 0;
}

int ioBatchPendingReads(ioBatchState *batch) {
    return batch ? batch->read_count : 0;
}

int ioBatchInflight(ioBatchState *batch) {
    return batch ? (batch->inflight_writes + batch->inflight_reads) : 0;
}

/* ============ Server-level io_uring lifecycle ============ */

void initIOUring(void) {
    if (!server.io_uring_enabled) {
        serverLog(LL_VERBOSE, "io_uring: disabled by configuration.");
        return;
    }

    server.io_uring_batch = ioBatchCreate(server.io_uring_sq_size);
    if (!server.io_uring_batch) {
        serverLog(LL_WARNING,
            "io_uring: failed to initialize batch I/O ring (sq_size=%d). "
            "Falling back to synchronous I/O.",
            server.io_uring_sq_size);
        server.io_uring_enabled = 0;
        return;
    }

    server.io_uring_batch->batch_writes_enabled = server.io_uring_batch_writes;
    server.io_uring_batch->batch_reads_enabled = server.io_uring_batch_reads;

    serverLog(LL_NOTICE,
        "io_uring: initialized (sq_size=%d, batch_writes=%s, batch_reads=%s)",
        server.io_uring_sq_size,
        server.io_uring_batch_writes ? "yes" : "no",
        server.io_uring_batch_reads ? "yes" : "no");
}

void freeIOUring(void) {
    if (server.io_uring_batch) {
        ioBatchFree(server.io_uring_batch);
        server.io_uring_batch = NULL;
    }
}

void harvestIOUringCompletions(void) {
    if (!server.io_uring_batch) return;
    if (ioBatchInflight(server.io_uring_batch) > 0) {
        ioBatchHarvestWrites(server.io_uring_batch);
        ioBatchHarvestReads(server.io_uring_batch);
    }
}

/* Batch read handler: given an array of fired fds from aeApiPoll,
 * submit io_uring read operations for all eligible readable clients.
 * Returns the number of fds handled via batch (these should be skipped
 * in the normal dispatch loop). */
int handleBatchReadsIOUring(int *fds, int nfds) {
    ioBatchState *batch = server.io_uring_batch;
    if (!batch || !batch->batch_reads_enabled || nfds == 0) return 0;

    int batched = 0;
    for (int i = 0; i < nfds; i++) {
        int fd = fds[i];
        if (fd < 0) continue;

        /* Get the connection from the event loop's client data */
        void *cd = aeGetFileClientData(server.el, fd);
        if (!cd) continue;

        connection *conn = (connection *)cd;
        if (!conn->read_handler || conn->state != CONN_STATE_CONNECTED)
            continue;

        client *c = connGetPrivateData(conn);
        if (!c) continue;

        /* Skip clients that shouldn't be batch-read */
        if (!(c->io_flags & CLIENT_IO_READ_ENABLED)) continue;
        if (c->flags & (CLIENT_BLOCKED | CLIENT_CLOSE_ASAP)) continue;
        if (c->flags & CLIENT_SLAVE) continue;

        if (ioBatchAddClientRead(c, batch) == 0) {
            fds[i] = -1; /* Mark as handled */
            batched++;
        }
    }

    if (batched > 0) {
        ioBatchSubmitReads(batch);
    }
    return batched;
}

#else /* !HAVE_IO_URING */

/* Provide empty stubs when io_uring is not available.
 * The config system and server code guard calls with #ifdef HAVE_IO_URING,
 * but the .o file must still compile cleanly. */
typedef int io_uring_batch_not_available;

#endif /* HAVE_IO_URING */
