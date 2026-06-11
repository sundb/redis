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

#include "adlist.h"

/* Opaque handle to client's compression state used internally by client_comp */
typedef struct compressionState compressionState;

struct client;

typedef enum {
    CD_INVALID,
    COMPRESS,
    DECOMPRESS,
} compressionDirection;

int clientEnableCompression(struct client *c, compressionDirection dir);
void clientDisableCompression(struct client *c);
void clientDestroyCompressionState(struct client *c);

int clientCompressesWrites(struct client *c);
int clientDecompressesReads(struct client *c);

ssize_t clientCompressAndWriteBuf(struct client *c, const char *data, size_t len,
                                  ssize_t *socket_written);
int clientReadAndDecompress(struct client *c, char *buf, size_t buf_len,
                            size_t *socket_read);

int compressAndWrite(struct client *c, int *tot_written);

int readFromBufAndDecompress(struct client *c, char *input_buf, size_t input_len,
                             char *output_buf, size_t output_len,
                             size_t *consumed);

int clientHasPendingCompressionFlush(struct client *c);
int clientHasPendingCompressedData(struct client *c);

int compressionProcessPendingReads(list *compression_clients);

#endif /* __CLIENT_COMP_H */
