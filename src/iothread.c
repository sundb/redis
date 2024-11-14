/* iothread.c -- The threaded io implementation.
 *
 * Copyright (c) 2024-Present, Redis Ltd.
 * All rights reserved.
 *
 * Licensed under your choice of the Redis Source Available License 2.0
 * (RSALv2) or the Server Side Public License v1 (SSPLv1).
 */

#include "server.h"

#define IO_THREADS_MAX_NUM 128
static ioThread io_threads[IO_THREADS_MAX_NUM] __attribute__((aligned(CACHE_LINE_SIZE)));

/* IO thread structure for the main thread. */
static list *pending_clients_for_io_threads[IO_THREADS_MAX_NUM] __attribute__((aligned(CACHE_LINE_SIZE)));
static list *main_thread_pending_clients[IO_THREADS_MAX_NUM] __attribute__((aligned(CACHE_LINE_SIZE)));
static pthread_mutex_t main_thread_pending_clients_mutexs[IO_THREADS_MAX_NUM] __attribute__((aligned(CACHE_LINE_SIZE)));
static eventNotifier* main_thread_pending_clients_notifier[IO_THREADS_MAX_NUM] __attribute__((aligned(CACHE_LINE_SIZE)));

void putInPendingClienstForMainThread(client *c) {
    /* The IO thread no longer manage it. */
    if (c->io_thread_client_list_node) {
        listDelNode(io_threads[c->tid].clients, c->io_thread_client_list_node);
        c->io_thread_client_list_node = NULL;
    }
    connSetReadHandler(c->conn, NULL);
    connSetWriteHandler(c->conn, NULL);
    listAddNodeTail(io_threads[c->tid].pending_clients_for_main_thread, c);
}

void putInPendingClienstForIOThreads(client *c) {
    connSetReadHandler(c->conn, NULL);
    connSetWriteHandler(c->conn, NULL);
    listAddNodeTail(pending_clients_for_io_threads[c->tid], c);
}

int isClientClosing(client *c) {
    int closing = 0;
    atomicGetWithSync(c->closing, closing);
    return closing;
}

/* Only the main thread can call these function. */
void pauseIOThread(int id) {
    if (!pthread_equal(pthread_self(), server.main_thread_id)) {
        return;
        // TODO: panic after we move somethings to main thread.
        // serverPanic("pauseIOThread() must be called in the main thread.");
    }
    int paused;
    atomicGetWithSync(io_threads[id].paused, paused);
    /* Don't support to call reentrant */
    serverAssert(paused == IO_THREAD_UNPAUSED);
    atomicSetWithSync(io_threads[id].paused, IO_THREAD_PAUSING);
    /* Just notify io thread, no actual job, since io threads
     * check paused status in beforesleep, so just try to notify. */
    triggerEventNotifier(io_threads[id].job_notifier);
    /* Wait for paused */
    while (paused != IO_THREAD_PAUSED) {
        atomicGetWithSync(io_threads[id].paused, paused);
        for (int i = 1; i < 1000; i++) {
            /* just wait a moment */
        }
    }
}

void resumeIOThread(int id) {
    /* Check if it is pause, since we must call 'pauseIOThread'
     * and resumeIOThread in pairs */
    int paused;
    atomicGetWithSync(io_threads[id].paused, paused);
    serverAssert(paused == IO_THREAD_PAUSED);
    /* Resume */
    atomicSetWithSync(io_threads[id].paused, IO_THREAD_UNPAUSED);
}

void pauseAllIOThreads(void) {
    for (int i = 1; i < server.io_threads_num; i++) {
        pauseIOThread(i);
    }
}

void resumeAllIOThreads(void) {
    for (int i = 1; i < server.io_threads_num; i++) {
        resumeIOThread(i);
    }
}

void updateIOThreadClientOutputBufferMemoryUsage(client *c) {
    serverAssert(c->running_tid != IOTHREAD_MAIN_THREAD_ID);
    size_t list_item_size = sizeof(listNode) + sizeof(clientReplyBlock);
    size_t mem = c->reply_bytes + (list_item_size*listLength(c->reply));
    atomicSet(c->output_buffer_mem, mem);
    atomicSet(c->output_buffer_len, listLength(c->reply));
}

size_t getIOThreadClientMemoryUsage(client *c, size_t *output_buffer_mem_usage) {
    serverAssert(c->running_tid != IOTHREAD_MAIN_THREAD_ID);
    size_t mem;
    atomicGet(c->output_buffer_mem, mem);
    if (output_buffer_mem_usage != NULL)
        *output_buffer_mem_usage = mem;
    mem += 0; //TODO: c->querybuf ? sdsZmallocSize(c->querybuf) : 0;
    mem += zmalloc_size(c);
    mem += c->buf_usable_size;
    /* subscribe, multi, tracking clients are managed by main thread. */
    return mem;
}

void ioThreadBeforeSleep(struct aeEventLoop *el) {
    ioThread *t = el->privdata;

    /* Check if i am pausing */
    int paused;
    atomicGetWithSync(t->paused, paused);
    if (paused == IO_THREAD_PAUSING) {
        atomicSetWithSync(t->paused, IO_THREAD_PAUSED);
        /* Wait for unpaused */
        while (paused == IO_THREAD_UNPAUSED) {
            atomicGetWithSync(t->paused, paused);
            for (int i = 1; i < 1000; i++) {
                /* just wait a moment */
            }
        }
    }

    if (listLength(t->pending_clients_for_main_thread) > 0) {
        pthread_mutex_lock(&main_thread_pending_clients_mutexs[t->id]);
        listJoin(main_thread_pending_clients[t->id], t->pending_clients_for_main_thread);
        pthread_mutex_unlock(&main_thread_pending_clients_mutexs[t->id]);
        triggerEventNotifier(main_thread_pending_clients_notifier[t->id]);
    }
}

void ioThreadAfterSleep(struct aeEventLoop *el) {
    UNUSED(el);
}

#define IO_THREAD_CRON_CLIENTS_ITERATIONS 10
int ioThreadCron(struct aeEventLoop *eventLoop, long long id, void *ptr) {
    UNUSED(eventLoop);
    UNUSED(id);

    ioThread *t = ptr;

    serverLog(LL_DEBUG, "io thead %ld, event loop size: %d", t->id, aeGetSetSize(t->el));

    /* Clients cron in io thread. */
    int iterations = IO_THREAD_CRON_CLIENTS_ITERATIONS;
    while (listLength(t->clients) && iterations--) {
        listNode *head = listFirst(t->clients);
        client *c = listNodeValue(head);
        listRotateHeadToTail(t->clients);

        serverAssert(c->tid == t->id);
        serverAssert(c->conn->write_handler || c->conn->read_handler);

        /* The client is asked to close, let main thread to free finally. */
        if (isClientClosing(c)) {
            putInPendingClienstForMainThread(c);
            continue;
        }
    }

    return 100; /* Run once per 100 millisecond */
}

void *ioThreadMain(void *ptr) {
    ioThread *t = ptr;
    char thdname[16];
    snprintf(thdname, sizeof(thdname), "io_thd_%ld", t->id);
    redis_set_thread_title(thdname);
    redisSetCpuAffinity(server.server_cpulist);
    makeThreadKillable();

    aeSetBeforeSleepProc(t->el, ioThreadBeforeSleep);
    aeSetAfterSleepProc(t->el, ioThreadAfterSleep);
    t->el->privdata = t;
    aeMain(t->el);
    return NULL;
}

void handleClientsFromIOThreads(struct aeEventLoop *el, int fd, void *ptr, int mask) {
    UNUSED(el);
    UNUSED(mask);

    ioThread *t = ptr;

    /* Handle fd first. */
    serverAssert(fd == getReadEventFd(main_thread_pending_clients_notifier[t->id]));
    handleEventNotifier(main_thread_pending_clients_notifier[t->id]);

    list *clients = listCreate();
    pthread_mutex_lock(&main_thread_pending_clients_mutexs[t->id]);
    listJoin(clients, main_thread_pending_clients[t->id]);
    pthread_mutex_unlock(&main_thread_pending_clients_mutexs[t->id]);
    if (listLength(clients) == 0) {
        listRelease(clients);
        return;
    }

    listIter li;
    listNode *ln;
    listRewind(clients, &li);
    while ((ln = listNext(&li))) {
        client *c = listNodeValue(ln);
        serverAssert(!c->conn->write_handler && !c->conn->read_handler);

        /* Let main thread to run it. */
        c->running_tid = IOTHREAD_MAIN_THREAD_ID;

        /* The client is asked to close. */
        if (isClientClosing(c)) {
            freeClient(c);
            continue;
        }

        /* Update the client in the mem usage */
        updateClientMemUsageAndBucket(c);

        if (processPendingCommandAndInputBuffer(c) == C_ERR) {
            /* If the client is no longer valid, we avoid
             * processing the client later. So we just go
             * to the next. */
            continue;
        }
        if (c->flags & CLIENT_CLOSE_ASAP) continue;

        /* We may have pending replies if a thread readQueryFromClient() produced
         * replies and did not put the client in pending write queue (it can't). */
        if (!(c->flags & CLIENT_PENDING_WRITE) && clientHasPendingReplies(c))
            putClientInPendingWriteQueue(c);

        /* If the client is still valid, let main thread handle it. */
        if (c->flags & CLIENT_PUBSUB ||
            c->flags & CLIENT_BLOCKED ||
            c->flags & CLIENT_SLAVE)
        {
            // TODO: main thread owns the client, rebind the event loop,
            // and set the read/write handler
        }

        /* If the client is still valid, let io threads handle its writing. */
        if (c->flags & CLIENT_PENDING_WRITE) {
            listUnlinkNode(server.clients_pending_write, &c->clients_pending_write_node);
            c->running_tid = c->tid;
            listAddNodeHead(pending_clients_for_io_threads[t->id], c);
            continue;
        }

        // TODO: remained clients are handled by main thread, what's the client status?
    }

    /* Update processed count on server */
    server.stat_io_reads_processed += listLength(clients);
    listRelease(clients);

    /* Trigger the io thread to handle the clients. */
    pthread_mutex_lock(&(t->pending_clients_mutex));
    listJoin(t->pending_clients, pending_clients_for_io_threads[t->id]);
    pthread_mutex_unlock(&(t->pending_clients_mutex));
    triggerEventNotifier(t->pending_clients_notifier);
}

void handleClientsFromMainThread(struct aeEventLoop *ae, int fd, void *ptr, int mask) {
    UNUSED(ae);
    UNUSED(mask);

    ioThread *t = ptr;

    /* Handle fd first. */
    serverAssert(fd == getReadEventFd(t->pending_clients_notifier));
    handleEventNotifier(t->pending_clients_notifier);

    list *clients = listCreate();
    pthread_mutex_lock(&t->pending_clients_mutex);
    listJoin(clients, t->pending_clients);
    pthread_mutex_unlock(&t->pending_clients_mutex);
    if (listLength(clients) == 0) {
        listRelease(clients);
        return;
    }

    listIter li;
    listNode *ln;
    listRewind(clients, &li);
    while((ln = listNext(&li))) {
        client *c = listNodeValue(ln);
        serverAssert(!c->conn->write_handler && !c->conn->read_handler);
        /* Main thread must handle clients with CLIENT_CLOSE_ASAP flag, since
         * we only set 'closing' state when clients in io thread are freed ASAP. */
        serverAssert(!(c->flags & CLIENT_CLOSE_ASAP));

        /* The client is asked to close. we just let main thread handle */
        if (isClientClosing(c)) {
            listAddNodeTail(t->pending_clients_for_main_thread, c);
            continue;
        }

        /* IO threads start to manage this client */
        listAddNodeTail(t->clients, c);
        c->io_thread_client_list_node = listLast(t->clients);

        /* TODO: Need to improve, do it only if needed */
        connRebindEventLoop(c->conn, t->el);

        /* We should install read handler first since writeToClient may free client,
         * otherwise we will rebind read handler after freeing client. */
        connSetReadHandler(c->conn, readQueryFromClient);

        if (c->flags & CLIENT_PENDING_WRITE) {
            c->flags &= ~CLIENT_PENDING_WRITE;
            writeToClient(c, 0);
            if (clientHasPendingReplies(c)) {
                connSetWriteHandler(c->conn, sendReplyToClient);
            }
        }

        /* TODO: Update the client in the mem usage after we're done processing it in the io-threads */
        // updateClientMemUsageAndBucket(c);
    }
    /* TODO: Update processed count on server */
    server.stat_io_writes_processed += listLength(clients);
    listRelease(clients);
}

void handleJobsFromMainThread(struct aeEventLoop *ae, int fd, void *ptr, int mask) {
    UNUSED(ae);
    UNUSED(fd);
    UNUSED(mask);

    ioThread *t = ptr;

    /* Handle fd first. */
    handleEventNotifier(t->job_notifier);
    
    list *jobs = listCreate();
    pthread_mutex_lock(&t->job_queue_mutext);
    listJoin(jobs, t->job_queue);
    pthread_mutex_unlock(&t->job_queue_mutext);
    if (listLength(jobs) == 0) {
        listRelease(jobs);
        return;
    }

    listIter li;
    listNode *ln;
    listRewind(jobs, &li);
    while ((ln = listNext(&li))) {
        ioThreadJob *job = listNodeValue(ln);
        switch (job->type) {
            case IO_THREAD_JOB_RESIZE_EVENT_LOOP: {
                unsigned int newsize = (long)job->data;
                if (aeResizeSetSize(t->el, newsize) == AE_ERR) {
                    /* How to handle failure*/
                    serverLog(LL_WARNING, "Failed to resize event loop.");
                }
                break;
            }
            default: {
                serverPanic("Unknown io thread job type");
                break;
            }
        }
    }
    listRelease(jobs);
}

void resizeIOThreadsEventLoop(unsigned int newsize) {
    if (server.io_threads_num <= 1) return;

    for (int i = 1; i < server.io_threads_num; i++) {
        ioThread *t = &io_threads[i];
        ioThreadJob *job = zmalloc(sizeof(*job));
        job->type = IO_THREAD_JOB_RESIZE_EVENT_LOOP;
        job->data = (void*)(long)newsize;
        pthread_mutex_lock(&t->job_queue_mutext);
        listAddNodeTail(t->job_queue, job);
        pthread_mutex_unlock(&t->job_queue_mutext);
        triggerEventNotifier(t->job_notifier);
    }
}

/* Initialize the data structures needed for threaded I/O. */
void initThreadedIO(void) {
    if (server.io_threads_num <= 1) return;

    server.io_threads_active = 1;

    if (server.io_threads_num > IO_THREADS_MAX_NUM) {
        serverLog(LL_WARNING,"Fatal: too many I/O threads configured. "
                             "The maximum number is %d.", IO_THREADS_MAX_NUM);
        exit(1);
    }

    /* Spawn and initialize the I/O threads. */
    for (int i = 1; i < server.io_threads_num; i++) {
        ioThread *t = &io_threads[i];
        t->id = i;
        t->el = aeCreateEventLoop(server.maxclients+CONFIG_FDSET_INCR);
        t->job_queue = listCreate();
        listSetFreeMethod(t->job_queue, zfree);
        t->pending_clients = listCreate();
        t->pending_clients_for_main_thread = listCreate();
        t->clients = listCreate();
        t->job_notifier = createEventNotifier();
        t->pending_clients_notifier = createEventNotifier();

        pthread_mutexattr_t *attr = NULL;
        #ifdef __linux__
        attr = zmalloc(sizeof(pthread_mutexattr_t));
        pthread_mutexattr_settype(attr, PTHREAD_MUTEX_ADAPTIVE_NP);
        #endif
        pthread_mutex_init(&t->job_queue_mutext, attr);
        pthread_mutex_init(&t->pending_clients_mutex, attr);

        if (aeCreateFileEvent(t->el, getReadEventFd(t->job_notifier),
                              AE_READABLE, handleJobsFromMainThread, t) != AE_OK)
        {
            serverPanic("Fatal: Can't register file event for io thread notifications.");
            exit(1);
        }

        if (aeCreateFileEvent(t->el, getReadEventFd(t->pending_clients_notifier),
                              AE_READABLE, handleClientsFromMainThread, t) != AE_OK)
        {
            serverPanic("Fatal: Can't register file event for io thread notifications.");
            exit(1);
        }

        if (aeCreateTimeEvent(t->el, 1, ioThreadCron, t, NULL) != AE_OK) {
            serverPanic("Can't create event loop timers.");
            exit(1);
        }
        /* Things we do only for the additional threads. */
        if (pthread_create(&t->tid, NULL, ioThreadMain, (void*)t) != 0) {
            serverLog(LL_WARNING,"Fatal: Can't initialize IO thread.");
            exit(1);
        }

        // Main thread
        pending_clients_for_io_threads[i] = listCreate();
        main_thread_pending_clients[i] = listCreate();
        pthread_mutex_init(&main_thread_pending_clients_mutexs[i], attr);
        main_thread_pending_clients_notifier[i] = createEventNotifier();
        if (aeCreateFileEvent(server.el, getReadEventFd(main_thread_pending_clients_notifier[i]),
                              AE_READABLE, handleClientsFromIOThreads, t) != AE_OK)
        {
            serverLog(LL_WARNING, "Fatal: Can't register file event for main thread notifications.");
            exit(1);
        }
    }
}

void killIOThreads(void) {
    if (server.io_threads_num <= 1) return;

    int err, j;
    for (j = 1; j < server.io_threads_num; j++) {
        if (io_threads[j].tid == pthread_self()) continue;
        if (io_threads[j].tid && pthread_cancel(io_threads[j].tid) == 0) {
            if ((err = pthread_join(io_threads[j].tid,NULL)) != 0) {
                serverLog(LL_WARNING,
                    "IO thread(tid:%lu) can not be joined: %s",
                        (unsigned long)io_threads[j].tid, strerror(err));
            } else {
                serverLog(LL_WARNING,
                    "IO thread(tid:%lu) terminated",(unsigned long)io_threads[j].tid);
            }
        }
    }
}

/* Add the pending clients to the list of IO threads, and trigger an event to
 * notify io threads to handle. */
void sendPendingClientsToIOThreads(void) {
    if (server.io_threads_num <= 1) return;
    for (int i = 1; i < server.io_threads_num; i++) {
        if (listLength(pending_clients_for_io_threads[i]) > 0) {
            ioThread *t = &io_threads[i];
            pthread_mutex_lock(&t->pending_clients_mutex);
            listJoin(t->pending_clients, pending_clients_for_io_threads[i]);
            pthread_mutex_unlock(&t->pending_clients_mutex);
            /* Trigger an event. */
            triggerEventNotifier(t->pending_clients_notifier);
        }
    }
}
