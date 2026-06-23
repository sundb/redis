#include "server.h"
#include "client_comp.h"
#include <zstd.h>

/* Abstraction over compression library */
typedef struct compressionType {
    int (*init_compress)(struct compressionState *st, int level);
    int (*init_decompress)(struct compressionState *st);
    int (*compress)(struct compressionState *st, int flush);
    int (*decompress)(struct compressionState *st);
    void (*end)(struct compressionState *st);
} compressionType;

/* Temporary buffer used by compression library to store compressed/decompressed
 * data. */
typedef struct {
    unsigned char *data;
    int size;
    int written;
    int consumed;
} tempBuf;

/* Main compression state struct */
struct compressionState {
    const compressionType *type;
    tempBuf input;  /* Buffer holding compressed data */
    tempBuf output; /* Buffer holding uncompressed(decompressed) data */
    union {
        ZSTD_CStream *zstdCCtx;  /* Zstd compression ctx */
        ZSTD_DStream *zstdDCtx;  /* Zstd decompression ctx */
    } ctx;
    int write_flush_pending;    /* write flush not yet completed */
    int read_flush_pending;    /* read flush not yet completed */
    mstime_t last_write;  /* Time since last write. Used to check if it's time
                           * to flush the buffer */
    compressionDirection dir;
    int handle_pending;   /* When set, the read path only drains already-read
                           * compressed data without reading the socket. */
};

/* --- zstd --- */

static int zstdInitCompress(compressionState *st, int level) {
    st->ctx.zstdCCtx = ZSTD_createCStream();
    if (!st->ctx.zstdCCtx) {
        serverLog(LL_NOTICE, "Failed to create ZSTD compression context");
        return -1;
    }
    size_t res = ZSTD_CCtx_setParameter(st->ctx.zstdCCtx, ZSTD_c_compressionLevel, level);
    if (ZSTD_isError(res)) {
        ZSTD_freeCStream(st->ctx.zstdCCtx);
        serverLog(LL_NOTICE, "Failed to set compression level for ZSTD compression context");
        return -1;
    }

    /* temp buf storing compressed data */
    size_t outSize = ZSTD_CStreamOutSize();
    st->output.data = zmalloc(outSize);
    st->output.size = outSize;
    st->output.written = 0;
    st->output.consumed = 0;

    /* temp buf storing uncompressed data */
    size_t inSize = ZSTD_CStreamInSize();
    st->input.data = zmalloc(inSize);
    st->input.size = inSize;
    st->input.written = 0;
    st->input.consumed = 0;

    st->write_flush_pending = 0;

    return 0;
}

static int zstdInitDecompress(compressionState *st) {
    st->ctx.zstdDCtx = ZSTD_createDStream();
    if (!st->ctx.zstdDCtx) {
        serverLog(LL_NOTICE, "Failed to create ZSTD decompression context");
        return -1;
    }

    /* temp buf storing compressed data */
    size_t inSize = ZSTD_DStreamInSize();
    st->input.data = zmalloc(inSize);
    st->input.size = inSize;
    st->input.written = 0;
    st->input.consumed = 0;

    /* temp buf storing decompressed data */
    size_t outSize = ZSTD_DStreamOutSize();
    st->output.data = zmalloc(outSize);
    st->output.size = outSize;
    st->output.written = 0;
    st->output.consumed = 0;

    st->read_flush_pending = 0;

    return 0;
}

static int zstdCompress(compressionState *st, int flush) {
    ZSTD_inBuffer input = {
        .src  = st->input.data,
        .size = st->input.written,
        .pos  = st->input.consumed
    };
    ZSTD_outBuffer output = {
        .dst  = st->output.data,
        .size = st->output.size,
        .pos  = st->output.written
    };

    ZSTD_EndDirective directive;
    /* We use ZSTD_e_end instead of ZSTD_e_flush when we want to flush zstd's.
     * This flushes zstd's internal buffers but also ends the current frame.
     * This of course lowers the compression ratio but massively increases speed
     * on the decompression side also, as it doesn't need to wait for more data.
     * The resulting compression ratio is still very good (tested with default
     * compression level). */
    if (flush || st->write_flush_pending)
        directive = ZSTD_e_end;
    else
        directive = ZSTD_e_continue;

    size_t ret;
    do {
        ret = ZSTD_compressStream2(st->ctx.zstdCCtx, &output, &input, directive);
        if (ZSTD_isError(ret)) {
            serverLog(LL_WARNING, "zstd compress error: %s", ZSTD_getErrorName(ret));
            return -1;
        }
    } while (ret > 0 && output.pos < output.size);

    /* If we pass a directive different than ZSTD_e_continue to zstd we want to
     * keep using that directive until compressStream2 returns 0. By keeping
     * this flag raised we know we are in the process of flushing data, i.e we
     * cannot use ZSTD_e_continue before we have flushed it all. */
    st->write_flush_pending = (directive == ZSTD_e_end && ret > 0);

    st->input.consumed = input.pos;
    st->output.written = output.pos;

    return 0;
}

static int zstdDecompress(compressionState *st) {
    ZSTD_inBuffer input = {
        .src  = st->input.data,
        .size = st->input.written,
        .pos  = st->input.consumed
    };
    ZSTD_outBuffer output = {
        .dst  = st->output.data,
        .size = st->output.size,
        .pos  = st->output.written
    };

    size_t ret = ZSTD_decompressStream(st->ctx.zstdDCtx, &output, &input);
    if (ZSTD_isError(ret)) {
        serverLog(LL_NOTICE, "zstd decompress error: %s", ZSTD_getErrorName(ret));
        return -1;
    }

    /* Don't try to flush again if we already tried, no more progress can be
     * made without additional input. */
    st->read_flush_pending = !st->read_flush_pending && (ret > 0);

    st->input.consumed = input.pos;
    st->output.written = output.pos;

    return 0;
}

static void zstdEnd(compressionState *st) {
    if (st->dir == COMPRESS && st->ctx.zstdCCtx) {
        /* Flush any pending data so context is in a good state before closing it */
        if (st->write_flush_pending) {
            size_t sz = ZSTD_CStreamOutSize();
            char *tmp = zmalloc(sz);
            ZSTD_inBuffer input = {
                .src  = NULL,
                .size = 0,
                .pos  = 0
            };
            ZSTD_outBuffer output = {
                .dst  = tmp,
                .size = sz,
                .pos  = 0
            };
            while (ZSTD_compressStream2(st->ctx.zstdCCtx, &output, &input, ZSTD_e_end) > 0) {
                /* Just ignore the output, we are closing the compression state
                 * anyways */
                output.pos = 0;
            }
            zfree(tmp);
        }
        ZSTD_freeCStream(st->ctx.zstdCCtx);
        st->ctx.zstdCCtx = NULL;
    } else if (st->dir == DECOMPRESS && st->ctx.zstdDCtx) {
        ZSTD_freeDStream(st->ctx.zstdDCtx);
        st->ctx.zstdDCtx = NULL;
    }
}

static const compressionType zstdType = {
    .init_compress = zstdInitCompress,
    .init_decompress = zstdInitDecompress,
    .compress = zstdCompress,
    .decompress = zstdDecompress,
    .end = zstdEnd,
};

int decompressInto(compressionState *state, char *buf, size_t buflen);
void compressionStateDestroy(compressionState *state);
static int compressionStateHasPendingFlush(compressionState *state);
static int compressionStateHasPendingData(compressionState *state);

/* Return the compression state attached to the client, or NULL if the client
 * has no compression state. Compression lives entirely at the user (client)
 * layer; the connection layer knows nothing about it. */
static compressionState *clientCompressionState(client *c) {
    return c->compr;
}

/* Return non-zero if the client has compression/decompression state attached. */
int clientHasCompression(client *c) {
    return c->compr != NULL;
}

/* Return non-zero if the client decompresses inbound data (i.e. a master
 * client reading a compressed replication stream). */
int clientIsDecompressing(client *c) {
    return c->compr != NULL && c->compr->dir == DECOMPRESS;
}

/* Return non-zero if the client compresses outbound data (i.e. a replica
 * client being fed a compressed replication stream). */
int clientIsCompressing(client *c) {
    return c->compr != NULL && c->compr->dir == COMPRESS;
}

/* The IO thread's pending-decompress list (IOThread.pending_decompress_clients)
 * holds clients that still have buffered decompressed data to drain even though
 * the socket may not have a read event pending. The client's
 * io_thread_pending_decompress_node points to its node in that list (NULL when
 * not linked), mirroring the compression_clients (write-flush) mechanism. We
 * only register on IO-thread loops (not the main loop), since on the main loop
 * the client is handed off to an IO thread soon enough; the IO thread is
 * reachable via el->privdata[0]. */
static void clientCompressionPendingAdd(client *c) {
    if (c->io_thread_pending_decompress_node) return;
    IOThread *t = c->conn->el->privdata[0];
    listAddNodeTail(t->pending_decompress_clients, c);
    c->io_thread_pending_decompress_node = listLast(t->pending_decompress_clients);
}

static void clientCompressionPendingRemove(client *c) {
    if (!c->io_thread_pending_decompress_node) return;
    /* Only IO-thread loops carry the pending list. If the client already left
     * the IO thread, the unbind/cleanup paths have unlinked the node and reset
     * the pointer, so we wouldn't reach here. */
    aeEventLoop *el = c->conn ? c->conn->el : NULL;
    if (!el || el == server.el) return;
    IOThread *t = el->privdata[0];
    listDelNode(t->pending_decompress_clients,
                c->io_thread_pending_decompress_node);
    c->io_thread_pending_decompress_node = NULL;
}

/* Decompress input compressed data and put it in `buf`. If decompressed data
 * is more than buflen this function must be called again so output data can
 * be consumed. If buflen is sufficiently large this function will decompress
 * as much data as possible. */
int decompressInto(compressionState *state, char *buf, size_t buflen) {
    if (buflen == 0)
      return 0;

    int consumed = 0;

    /* Decompress as much data as possible */
    while ((size_t)consumed < buflen &&
           (state->read_flush_pending ||
            state->input.written > state->input.consumed ||
            state->output.written > state->output.consumed))
    {
        /* Reset the decompressed buffer if all the available data is consumed */
        if (state->output.consumed == state->output.size) {
            state->output.written = 0;
            state->output.consumed = 0;
        }

        if ((state->read_flush_pending && state->output.size > state->output.written) ||
             state->input.written > state->input.consumed)
        {
            if (state->type->decompress(state) == -1) {
                return -1;
            }
        }

        /* Copy the decompressed data to the output buffer */
        if (state->output.written > state->output.consumed) {
            size_t nonconsumed_decompressed = state->output.written - state->output.consumed;
            int to_consume = min(buflen - consumed, nonconsumed_decompressed);
            memcpy(buf + consumed, state->output.data + state->output.consumed, to_consume);

            state->output.consumed += to_consume;
            consumed += to_consume;
        }
    }

    if (state->output.consumed == state->output.size)
    {
        state->output.written = 0;
        state->output.consumed = 0;
    }

    /* Reset the compressed buffer if we decompressed all the available data */
    if (state->input.consumed == state->input.size) {
        state->input.written = 0;
        state->input.consumed = 0;
    }

    serverAssert((size_t)consumed <= buflen);
    return consumed;
}

/* Read compressed data from the client's socket and decompress it into `buf`.
 * Tries to read and decompress as much as possible. Returns the number of
 * decompressed bytes written into `buf` (0 is valid, -1 on a fatal error that
 * closed the connection). *socket_read is set to the number of raw bytes read
 * from the socket (for network statistics).
 *
 * When the client's compression state has its handle_pending flag raised we do
 * NOT read from the socket: we only drain compressed/decompressed data already
 * buffered in the compression state. This is used by the pending-decompress
 * processing on IO-thread loops. */
int readAndDecompress(client *c, char *buf, size_t buf_len, size_t *socket_read) {
    compressionState *state = c->compr;
    *socket_read = 0;
    serverAssert(state && state->dir == DECOMPRESS);

    size_t decompressed = 0;
    do {
        int curr = decompressInto(state, buf + decompressed, buf_len - decompressed);
        /* Decompression error, we should close the connection */
        if (curr < 0) {
            c->conn->state = CONN_STATE_CLOSED;
            break;
        }
        decompressed += curr;

        int nread = 0;
        /* If the handle_pending flag is raised we only decompress whatever data
         * we have read from the socket without reading anything more. Socket
         * reading will happen when the event loop handles a read event, in which
         * case the handle_pending flag wouldn't be raised. */
        if (!state->handle_pending) {
            nread = connRead(c->conn,
                             state->input.data + state->input.written,
                             state->input.size - state->input.written);

            if (nread < 0 && connGetState(c->conn) == CONN_STATE_ERROR) {
                *socket_read = -1;
                return -1;
            }
            /* Even if nread == 0 we continue the loop until decompressInto has
             * nothing more it can do. */
            if (nread > 0) {
                *socket_read += nread;
                state->input.written += nread;
            }
        }

        if (curr <= 0 && nread <= 0) break;
    } while (decompressed < buf_len);

    if (decompressed == 0 && connGetState(c->conn) == CONN_STATE_CONNECTED)
        return -1;

    /* Register/unregister the client for pending-decompress processing, but
     * only on IO-thread loops (see clientCompressionPendingAdd). */
    if (c->conn->el && c->conn->el != server.el) {
        if (connGetState(c->conn) == CONN_STATE_CONNECTED && compressionStateHasPendingData(state)) {
            clientCompressionPendingAdd(c);
        } else {
            clientCompressionPendingRemove(c);
        }
    }

    return decompressed;
}

/* Flush any compressed data available in the output buffer to the socket.
 * The compression library may not return compressed data immediately so this
 * call may not write anything to the socket. Force flushes the compressed
 * buffer according to compression_max_latency.
 * Returns 0 on success (with *tot_written set to the number of bytes written
 * to the socket) or 1 on a socket write error. */
int compressAndWrite(client *c, int *tot_written) {
    compressionState *state = c->compr;
    *tot_written = 0;
    if (!state || state->dir != COMPRESS)
        return 0;

    /* All available uncompressed data was consumed so we need to reset the
     * uncompressed buffer */
    if (state->input.written == state->input.size &&
        state->input.consumed == state->input.size)
    {
        state->input.written = 0;
        state->input.consumed = 0;
    }

    if (state->output.written < state->output.size) {
        /* Force flush after `compression_max_latency` ms have passed.
         * Note, this only makes sense when we have enough space for compressing
         * data. */
        int flush = mstime() - state->last_write > server.compression_max_latency;
        if (state->type->compress(state, flush) == -1) {
            /* Fatal compression error. Mark the connection as closed, mirroring
             * how the read path handles a fatal decompress error. The client
             * will then be torn down by the regular write-error handling, which
             * destroys the compression state. */
            c->conn->state = CONN_STATE_CLOSED;
            return 1;
        }
    }

    /* Try to write all the data available in the compressed buffer. */
    int towrite = state->output.written - state->output.consumed;
    do {
        int written = connWrite(
            c->conn, state->output.data + state->output.consumed, towrite);
        if (written < 0) {
            return 1;
        }

        state->output.consumed += written;
        *tot_written += written;
        towrite -= written;

        /* All of the compressed data was sent to the socket so we need to reset
         * the compression buffer. */
        if (state->output.consumed == state->output.size) {
            serverAssert(towrite == 0 && state->output.written == state->output.size);

            state->output.written = 0;
            state->output.consumed = 0;
        }
    } while (towrite > 0);

    if (*tot_written > 0)
        state->last_write = mstime();

    return 0;
}

/* Feed `len` bytes from `data` into the compressor and write whatever
 * compressed output becomes available to the socket. Returns the number of
 * uncompressed bytes consumed from `data` (so callers can advance their source
 * buffer position), or -1 on a fatal socket error. *socket_written is set to
 * the number of (compressed) bytes actually written to the socket, for
 * statistics. */
int compressDataAndWrite(client *c, const char *data, size_t len, int *socket_written) {
    compressionState *state = c->compr;
    *socket_written = 0;
    serverAssert(state && state->dir == COMPRESS);

    int consumed = 0;
    while ((size_t)consumed != len) {
        int to_consume =
            min(state->input.size - state->input.written, (int)(len - consumed));
        serverAssert(to_consume >= 0);

        memcpy(state->input.data + state->input.written,
               data + consumed, to_consume);

        state->input.written += to_consume;
        consumed += to_consume;

        /* Write whatever we have available in the compressed buffer */
        int written = 0;
        int err = compressAndWrite(c, &written);
        if (err) {
            if (connGetState(c->conn) != CONN_STATE_CONNECTED) {
                return -1;
            }
            return consumed;
        }
        *socket_written += written;

        if (written == 0 && state->output.written == state->output.consumed)
            break;
    }

    return consumed;
}

/* Return non-zero if any client on this (IO-thread) event loop still has
 * buffered decompressed data to process. */
int compressionHasPendingReads(struct aeEventLoop *el) {
    IOThread *t = el->privdata[0];
    if (!t || !t->pending_decompress_clients)
        return 0;
    return listLength(t->pending_decompress_clients) > 0;
}

/* Drain pending decompressed data for clients on this event loop. We call the
 * client's read handler with the handle_pending flag raised so it only processes
 * data already buffered in the compression state and doesn't read the socket. */
int processPendingCompressionReads(struct aeEventLoop *el) {
    IOThread *t = el->privdata[0];
    if (!t || !t->pending_decompress_clients ||
        listLength(t->pending_decompress_clients) == 0)
        return 0;

    listIter li;
    listNode *ln;
    int processed = 0;
    listRewind(t->pending_decompress_clients,&li);
    while((ln = listNext(&li))) {
        client *c = listNodeValue(ln);
        if (!c || !c->conn || !c->compr || !connHasReadHandler(c->conn)) continue;

        c->compr->handle_pending = 1;
        c->conn->read_handler(c->conn);
        c->compr->handle_pending = 0;

        ++processed;
    }
    return processed;
}

/* Allocate and initialize a bare compression state. */
static compressionState *compressionStateCreate(void) {
    compressionState *st = zcalloc(sizeof(compressionState));
    st->type = &zstdType;
    st->last_write = 0;
    st->write_flush_pending = 0;
    st->read_flush_pending = 0;
    st->dir = CD_INVALID;
    st->handle_pending = 0;

    return st;
}

void compressionStateDestroy(compressionState *state) {
    if (state == NULL) return;

    state->type->end(state);
    zfree(state->input.data);
    zfree(state->output.data);
    zfree(state);
}

/* Create and initialize a compression state for the client. No-op if already
 * initialized. `dir` indicates the compression direction, i.e if the client
 * will compress or decompress data.
 * Currently only viable for master/replica clients. */
int clientCreateCompressionState(client *c, compressionDirection dir) {
    /* Client compression already initialized */
    if (clientHasCompression(c))
        return 1;

    compressionState *st = compressionStateCreate();

    if (dir == COMPRESS) {
        serverAssert(c->compression_level > 0 && c->flags & CLIENT_SLAVE);

        if (st->type->init_compress(st, c->compression_level) == -1) {
            compressionStateDestroy(st);
            return 0;
        }

        st->dir = COMPRESS;

        serverLog(LL_NOTICE, "Initialized compression at level %d for client #%llu...",
                c->compression_level, (unsigned long long)c->id);
    } else if (dir == DECOMPRESS) {
        serverAssert(server.repl_master_compression_level > 0);

        if (st->type->init_decompress(st) == -1) {
            compressionStateDestroy(st);
            return 0;
        }

        st->dir = DECOMPRESS;

        serverLog(LL_NOTICE, "Decompression for master client initialized.");
    } else {
        /* Inaccessible */
        serverAssert(0);
    }

    c->compr = st;

    return 1;
}

void clientDestroyCompressionState(client *c) {
    if (!clientHasCompression(c)) return;

    compressionState *st = c->compr;
    /* Unlink from the event loop's pending-decompress list before freeing. */
    clientCompressionPendingRemove(c);
    c->compr = NULL;

    compressionStateDestroy(st);
    c->compression_level = 0;
    c->io_flags &= ~CLIENT_IO_COMPRESSION_ENABLED;

    serverLog(LL_NOTICE, "Compression state for client #%llu%s destroyed...",
              (unsigned long long)c->id,
              c->flags & CLIENT_MASTER ? " (master)" : c->flags & CLIENT_SLAVE ?
              " (slave)" : "");
}

/* Enable client compression and create compression state if not present.
 * Currently only valid for primary/replica clients.
 * Return 0 if compression state was not created and failed to be initialized,
 * 1 if compression was enabled. */
int clientEnableCompression(client *c, compressionDirection dir) {
    serverAssert((c->flags & CLIENT_MASTER) || (c->flags & CLIENT_SLAVE));
    if (!clientCreateCompressionState(c, dir)) {
        return 0;
    }

    c->io_flags |= CLIENT_IO_COMPRESSION_ENABLED;
    return 1;
}

/* Disable compression without destroying compression state. */
void clientDisableCompression(client *c) {
    c->io_flags &= ~CLIENT_IO_COMPRESSION_ENABLED;
}

/* Read data from input_buf and decompress it immediately. The result is written
 * into output_buf.
 * Return number of bytes decompressed. *consumed stores number of bytes consumed
 * from input_buf.
 * Note, that we may have enough compressed data inside input buf so that decompressing
 * it will exceed output_len. The function must be ran in a loop until input_buf
 * is fully consumed - so make sure to have free space in output_buf on each call. */
int readFromBufAndDecompress(client *c, char *input_buf, size_t input_len,
                             char *output_buf, size_t output_len, size_t *consumed)
{
    compressionState *state = clientCompressionState(c);
    if (!state) {
        return -1;
    }

    int tot_decompressed = 0;
    *consumed = 0;
    while (*consumed <= input_len && (size_t)tot_decompressed < output_len) {
        int to_consume =
            min(state->input.size - state->input.written,
                (int)(input_len - *consumed));

        if (to_consume)
            memcpy(state->input.data + state->input.written,
                   input_buf + *consumed, to_consume);

        *consumed += to_consume;

        state->input.written += to_consume;

        int decompressed = decompressInto(state, output_buf + tot_decompressed,
                                          output_len - tot_decompressed);
        if (decompressed <= 0)
            break;
        tot_decompressed += decompressed;
    }

    return tot_decompressed;
}

/* Check if we need to flush compressed data. Compression library may wait for
 * a lot of compressed data before it finishes a frame and gives it back to user.
 * While this gives the best compression ratio it introduces a lot of latency so
 * we make a compromise and flush periodically. */
static int compressionStateHasPendingFlush(compressionState *state) {
    if (!state) return 0;
    if (state->dir != COMPRESS) return 0;

    return state->write_flush_pending || (mstime() - state->last_write >= server.compression_max_latency);
}

int clientHasPendingCompressionFlush(client *c) {
    return compressionStateHasPendingFlush(clientCompressionState(c));
}

/* Check if we still have pending compressed data. This may mean that either the
 * compression library still has data in it's internal buffers, we still have
 * compressed data that needs to be consumed by the library or we have stored
 * decompressed data that we still have not consumed. */
static int compressionStateHasPendingData(compressionState *state) {
    if (!state) return 0;
    if (state->dir != DECOMPRESS) return 0;

    return (state->read_flush_pending && state->output.size > state->output.written) ||
           state->input.written > state->input.consumed ||
           state->output.written > state->output.consumed;
}

int clientHasPendingCompressedData(client *c) {
    return compressionStateHasPendingData(clientCompressionState(c));
}
