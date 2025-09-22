/* cmdpool.c - Client-specific command pool for pendingCommand structures
 *
 * Copyright (c) 2006-Present, Redis Ltd.
 * All rights reserved.
 *
 * Licensed under your choice of (a) the Redis Source Available License 2.0
 * (RSALv2); or (b) the Server Side Public License v1 (SSPLv1); or (c) the
 * GNU Affero General Public License v3 (AGPLv3).
 */

#include "server.h"
#include "zmalloc.h"
#include <string.h>

/* Cleanup a client command queue and its pool */
void cmdQueueCleanup(cmdQueue *queue) {
    if (!queue) return;

    /* Free all commands in the queue */
    pendingCommand *cmd = queue->head;
    while (cmd) {
        pendingCommand *next = cmd->next;
        if (cmd->argv) {
            for (int j = 0; j < cmd->argc; j++) {
                decrRefCount(cmd->argv[j]);
            }
            zfree(cmd->argv);
        }
        zfree(cmd);
        cmd = next;
    }
}

/* Return a pendingCommand to the client's pool */
void cmdQueuePutCommand(cmdQueue *queue, pendingCommand *cmd) {
    for (int j = 0; j < cmd->argc; j++)
        decrRefCount(cmd->argv[j]);

    if (cmd->argv) {
        zfree(cmd->argv);
        cmd->argv = NULL;
    }

    /* Pool is full, free the command */
    zfree(cmd);
}

/* Add a command to the tail of the queue */
void cmdQueueAddTail(cmdQueue *queue, pendingCommand *cmd) {
    cmd->next = NULL;
    cmd->prev = queue->tail;

    if (queue->tail) {
        queue->tail->next = cmd;
    } else {
        /* Queue was empty */
        queue->head = cmd;
    }

    queue->tail = cmd;
    queue->length++;
}

/* Remove and return the head command from the queue */
pendingCommand *cmdQueueRemoveHead(cmdQueue *queue) {
    pendingCommand *cmd = queue->head;
    queue->head = cmd->next;

    if (queue->head) {
        queue->head->prev = NULL;
    } else {
        /* Queue is now empty */
        queue->tail = NULL;
    }

    cmd->next = NULL;
    cmd->prev = NULL;
    queue->length--;

    return cmd;
}
