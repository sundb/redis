/*
 * Copyright (c) 2009-Present, Redis Ltd.
 * All rights reserved.
 *
 * Licensed under your choice of (a) the Redis Source Available License 2.0
 * (RSALv2); or (b) the Server Side Public License v1 (SSPLv1); or (c) the
 * GNU Affero General Public License v3 (AGPLv3).
 */

#ifndef __CLIENT_COMP_H
#define __CLIENT_COMP_H

#include <sys/types.h>

/* Opaque handle to client's compression state used internally by client_comp */
typedef struct compressionState compressionState;

struct client;

typedef enum {
    CD_INVALID,
    COMPRESS,
    DECOMPRESS,
} compressionDirection;

int clientCreateCompressionState(struct client *c, compressionDirection dir);
void clientDestroyCompressionState(struct client *c);

int clientEnableCompression(struct client *c, compressionDirection dir);

void clientDisableCompression(struct client *c);

/* Return non-zero if the client's connection is a compression connection
 * (i.e. it has an attached compression state). */
int clientHasCompression(struct client *c);

/* Direction-aware variants: decompressing = master client reading a compressed
 * stream; compressing = replica client being fed a compressed stream. */
int clientIsDecompressing(struct client *c);
int clientIsCompressing(struct client *c);

/* Flush pending compressed output to the socket. */
int compressAndWrite(struct client *c, int *tot_written);

/* Feed `len` bytes from `data` into the compressor and write the resulting
 * compressed output to the socket. Returns uncompressed bytes consumed. */
int compressDataAndWrite(struct client *c, const char *data, size_t len, int *socket_written);

/* Read compressed data from the client's socket and decompress into `buf`.
 * Returns decompressed bytes; *socket_read gets raw bytes read from socket. */
int readAndDecompress(struct client *c, char *buf, size_t buf_len, size_t *socket_read);

int readFromBufAndDecompress(struct client *c, char *input_buf, size_t input_len,
                             char *output_buf, size_t output_len,
                             size_t *consumed);

/* Event-loop pending-decompress draining (IO-thread loops only). */
struct aeEventLoop;
int compressionHasPendingReads(struct aeEventLoop *el);
int processPendingCompressionReads(struct aeEventLoop *el);

int clientHasPendingCompressionFlush(struct client *c);
int clientHasPendingCompressedData(struct client *c);

#endif /* __CLIENT_COMP_H */
