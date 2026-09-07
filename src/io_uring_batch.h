/* io_uring batch I/O engine for Redis
 *
 * Copyright (c) 2024-Present, Redis Ltd.
 * All rights reserved.
 *
 * Licensed under your choice of (a) the Redis Source Available License 2.0
 * (RSALv2); or (b) the Server Side Public License v1 (SSPLv1); or (c) the
 * GNU Affero General Public License v3 (AGPLv3).
 */

#ifndef __IO_URING_BATCH_H
#define __IO_URING_BATCH_H

#ifdef HAVE_IO_URING

#include <liburing.h>
#include <sys/uio.h>

#define IO_BATCH_DEFAULT_SQ_SIZE 1024
#define IO_BATCH_MAX_IOVEC 128
#define IO_BATCH_OP_WRITE 1
#define IO_BATCH_OP_READ  2

struct client;

typedef struct ioBatchOp {
    struct client *c;
    int fd;
    int type;
    struct iovec *iov;
    int iovcnt;
    size_t total_len;
} ioBatchOp;

typedef struct ioBatchState {
    struct io_uring ring;
    int ring_initialized;
    ioBatchOp *write_ops;
    int write_count;
    int write_capacity;
    ioBatchOp *read_ops;
    int read_count;
    int read_capacity;
    int inflight_writes;
    int inflight_reads;
    int sq_size;
    int batch_writes_enabled;
    int batch_reads_enabled;
} ioBatchState;

/* Lifecycle */
ioBatchState *ioBatchCreate(int sq_size);
void ioBatchFree(ioBatchState *batch);

/* Write batching */
int ioBatchAddWrite(ioBatchState *batch, struct client *c, int fd,
                    struct iovec *iov, int iovcnt, size_t total_len);
int ioBatchSubmitWrites(ioBatchState *batch);
int ioBatchHarvestWrites(ioBatchState *batch);

/* Read batching */
int ioBatchAddRead(ioBatchState *batch, struct client *c, int fd,
                   void *buf, size_t buf_len);
int ioBatchSubmitReads(ioBatchState *batch);
int ioBatchHarvestReads(ioBatchState *batch);

/* High-level helpers that build iovecs from client buffers */
int ioBatchAddClientWrite(struct client *c, ioBatchState *batch);
int ioBatchAddClientRead(struct client *c, ioBatchState *batch);

/* Query state */
int ioBatchPendingWrites(ioBatchState *batch);
int ioBatchPendingReads(ioBatchState *batch);
int ioBatchInflight(ioBatchState *batch);

#endif /* HAVE_IO_URING */
#endif /* __IO_URING_BATCH_H */
