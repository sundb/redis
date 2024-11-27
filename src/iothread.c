/* iothread.c -- The threaded io implementation.
 *
 * Copyright (c) 2024-Present, Redis Ltd.
 * All rights reserved.
 *
 * Licensed under your choice of the Redis Source Available License 2.0
 * (RSALv2) or the Server Side Public License v1 (SSPLv1).
 */

#include "server.h"

/* IO threads. */
static ioThread io_threads[IO_THREADS_MAX_NUM] __attribute__((aligned(CACHE_LINE_SIZE)));

/* IO thread structure for the main thread. */
static list *pending_clients_for_io_threads[IO_THREADS_MAX_NUM] __attribute__((aligned(CACHE_LINE_SIZE)));
static list *main_thread_pending_clients[IO_THREADS_MAX_NUM] __attribute__((aligned(CACHE_LINE_SIZE)));
static list *main_thread_processing_clients[IO_THREADS_MAX_NUM] __attribute__((aligned(CACHE_LINE_SIZE)));
static pthread_mutex_t main_thread_pending_clients_mutexs[IO_THREADS_MAX_NUM] __attribute__((aligned(CACHE_LINE_SIZE)));
static eventNotifier* main_thread_pending_clients_notifier[IO_THREADS_MAX_NUM] __attribute__((aligned(CACHE_LINE_SIZE)));

/* Since main thread and IO thread may free the same client, we should use atomic
 * variable to make sure data race does not happen. */
int isClientClosing(client *c) {
    int closing = 0;
    atomicGetWithSync(c->closing, closing);
    return closing;
}

/* When IO threads read a complete query of clients or want to free clients,
 * it should remove it from its clients list and put the client in the list
 * for main thread, and will send these clients to main thread in beforeSleep.*/
void putInPendingClienstForMainThread(client *c) {
    /* The IO thread no longer manage it, just skip if it already is transferred.
     * The read and write events happen at the same time. */
    if (c->io_thread_client_list_node) {
        listDelNode(io_threads[c->tid].clients, c->io_thread_client_list_node);
        c->io_thread_client_list_node = NULL;
        /* Disable read and write to avoid race when main thread processes. */
        c->io_flags &= ~(CLIENT_IO_READ_ENABLED | CLIENT_IO_WRITE_ENABLED);
        listAddNodeTail(io_threads[c->tid].pending_clients_for_main_thread, c);
    }
}

/* Uninstall read and write handler of a client from io thread event loop,
 * to make sure that we can operate the client safely. */
void uninstallHandlerFromIOThreadEventLoop(client *c) {
    serverAssert(c->tid != IOTHREAD_MAIN_THREAD_ID);
    if (!connHasReadHandler(c->conn) && !connHasWriteHandler(c->conn)) return;
    /* As calling in main thread, we should pause the io thread to make it safe. */
    pauseIOThread(c->tid);
    connSetReadHandler(c->conn, NULL);
    connSetWriteHandler(c->conn, NULL);
    resumeIOThread(c->tid);
}

/* When main thread is processing a client from IO thread, and wants to keep it,
 * we should uninstall read and write handler from io thread event loop first,
 * and then bind the client connection into server's event loop. */
void keepClientInMainThread(client *c) {
    serverAssert(c->tid != IOTHREAD_MAIN_THREAD_ID);
    /* IO thread no longer manage it. */
    server.io_threads_clients_num[c->tid]--;
    /* Remove the client from io thread event loop. */
    uninstallHandlerFromIOThreadEventLoop(c);
    /* Let main thread to run it, rebind event loop and read handler */
    connRebindEventLoop(c->conn, server.el);
    connSetReadHandler(c->conn, readQueryFromClient);
    c->io_flags |= CLIENT_IO_READ_ENABLED | CLIENT_IO_WRITE_ENABLED;
    c->running_tid = IOTHREAD_MAIN_THREAD_ID;
    c->tid = IOTHREAD_MAIN_THREAD_ID;
    /* Main thread starts to manage it. */
    server.io_threads_clients_num[c->tid]++;
}

/* If updating maxclients config, we not only resize the event loop of main thread
 * but also resize the event loop of all io threads, and if one thread is failed,
 * it is failed totally, since a fd can be distributed into any IO thread. */
int resizeIOThreadsEventLoop(size_t newsize) {
    int result = AE_OK;
    if (server.io_threads_num <= 1) return result;

    /* To make context safe. */
    pauseAllIOThreads();
    for (int i = 1; i < server.io_threads_num; i++) {
        ioThread *t = &io_threads[i];
        /* If one thread is failed, it is failed totally. */
        if (aeResizeSetSize(t->el, newsize) == AE_ERR)
            result = AE_ERR;
    }
    resumeAllIOThreads();
    return result;
}

/* When the main thread accepts a new client, it assign the client to the IO thread
 * with the fewest clients. */
void assignClientToIOThread(client *c) {
    /* Find the IO thread with the fewest clients. */
    int min_id = 0;
    int min = INT_MAX;
    for (int i = 1; i < server.io_threads_num; i++) {
        if (server.io_threads_clients_num[i] < min) {
            min = server.io_threads_clients_num[i];
            min_id = i;
        }
    }

    /* Assign the client to the IO thread. */
    c->tid = min_id;
    c->running_tid = min_id;
    server.io_threads_clients_num[min_id]++;
    server.io_threads_clients_num[IOTHREAD_MAIN_THREAD_ID]--;

    /* Uninstall read and write handler, disable read and write, and then put in
     * the list, main thread will send these clients to IO thread in beforeSleep. */
    connSetReadHandler(c->conn, NULL);
    connSetWriteHandler(c->conn, NULL);
    c->io_flags &= ~(CLIENT_IO_READ_ENABLED | CLIENT_IO_WRITE_ENABLED);
    listAddNodeTail(pending_clients_for_io_threads[c->tid], c);
}

/* In the main thread, we may want to operate data of io threads, maybe uninstall
 * event handler, access query/output buffer or resize event loop, we need a clean
 * and safe context to do that. We pause io thread in its beforeSleep, do some jobs,
 * and then resume it. To avoid thead suspended, we use busy waiting to confirm the
 * target status. Besides we use atomic variable to make sure memory visibility and
 * ordering.
 *
 * Make sure that only the main thread can call these function,
 *  - pauseIOThread, resumeIOThread
 *  - pauseAllIOThreads, resumeAllIOThreads
 *  - pauseIOThreadsRange, resumeIOThreadsRange
 *
 * The main thread will pause the io thread, and then wait for the io thread to
 * be paused. The io thread will check the paused status in beforeSleep, and then
 * pause itself.
 *
 * The main thread will resume the io thread, and then wait for the io thread to
 * be resumed. The io thread will check the paused status in beforeSleep, and then
 * resume itself.
 */

/* We may pause the same io thread nestedly, so we need to record the times of
 * pausing, and only when the times of pausing is 0, we can pause the io thread,
 * and only when the times of pausing is 1, we can resume the io thread. */
static int PausedIOThreads[IO_THREADS_MAX_NUM] = {0};

/* Pause the specific range of io threads, and wait for them to be paused. */
void pauseIOThreadsRange(int start, int end) {
    if (server.io_threads_num <= 1) return;
    serverAssert(start >= 1 && end < server.io_threads_num && start <= end);
    serverAssert(pthread_equal(pthread_self(), server.main_thread_id));

    /* Try to make all io threads paused in parallel */
    for (int i = start; i <= end; i++) {
        PausedIOThreads[i]++;
        /* Skip if already paused */
        if (PausedIOThreads[i] > 1) continue;

        int paused;
        atomicGetWithSync(io_threads[i].paused, paused);
        /* Don't support to call reentrant */
        serverAssert(paused == IO_THREAD_UNPAUSED);
        atomicSetWithSync(io_threads[i].paused, IO_THREAD_PAUSING);
        /* Just notify io thread, no actual job, since io threads
         * check paused status in beforesleep, so just try to notify. */
        triggerEventNotifier(io_threads[i].job_notifier);
    }

    /* Wait for all io threads paused */
    for (int i = start; i <= end; i++) {
        if (PausedIOThreads[i] > 1) continue;
        int paused = IO_THREAD_PAUSING;
        while (paused != IO_THREAD_PAUSED) {
            atomicGetWithSync(io_threads[i].paused, paused);
        }
    }
}

/* Resume the specific range of io threads, and wait for them to be resumed. */
void resumeIOThreadsRange(int start, int end) {
    if (server.io_threads_num <= 1) return;
    serverAssert(start >= 1 && end < server.io_threads_num && start <= end);
    serverAssert(pthread_equal(pthread_self(), server.main_thread_id));

    for (int i = start; i <= end; i++) {
        serverAssert(PausedIOThreads[i] > 0);
        PausedIOThreads[i]--;
        if (PausedIOThreads[i] > 0) continue;

        int paused;
        /* Check if it is paused, since we must call 'pause' and
         * 'resume' in pairs */
        atomicGetWithSync(io_threads[i].paused, paused);
        serverAssert(paused == IO_THREAD_PAUSED);
        /* Resume */
        atomicSetWithSync(io_threads[i].paused, IO_THREAD_RESUMING);
        while (paused != IO_THREAD_UNPAUSED) {
            atomicGetWithSync(io_threads[i].paused, paused);
        }
    }
}

/* Pause the specific io thread, and wait for it to be paused. */
void pauseIOThread(int id) {
    pauseIOThreadsRange(id, id);
}

/* Resume the specific io thread, and wait for it to be resumed. */
void resumeIOThread(int id) {
    resumeIOThreadsRange(id, id);
}

/* Pause all io threads, and wait for them to be paused. */
void pauseAllIOThreads(void) {
    pauseIOThreadsRange(1, server.io_threads_num-1);
}

/* Resume all io threads, and wait for them to be resumed. */
void resumeAllIOThreads(void) {
    resumeIOThreadsRange(1, server.io_threads_num-1);
}

/* Add the pending clients to the list of IO threads, and trigger an event to
 * notify io threads to handle. */
int sendPendingClientsToIOThreads(void) {
    int processed = 0;
    for (int i = 1; i < server.io_threads_num; i++) {
        int len = listLength(pending_clients_for_io_threads[i]);
        if (len > 0) {
            ioThread *t = &io_threads[i];
            pthread_mutex_lock(&t->pending_clients_mutex);
            listJoin(t->pending_clients, pending_clients_for_io_threads[i]);
            pthread_mutex_unlock(&t->pending_clients_mutex);
            /* Trigger an event, maybe an error is returned when buffer is full
             * if using pipe, but no worry, io thread will handle all clients
             * in list when receiving a notification. */
            triggerEventNotifier(t->pending_clients_notifier);
        }
        processed += len;
    }
    return processed;
}

extern int ProcessingEventsWhileBlocked;

/* The main thread processes the clients from IO threads, these clients may have
 * a complete command to execute or need to be freed. Note that IO threads never
 * free client since this operation access much server data.
 *
 * And for some clients, we may keep them in the main thread, since they are not
 * suitable to be processed in IO threads.
 * Replica, pubsub, monitor, blocked, tracking, watching clients which main thread
 * may directly operate on them when conditions are met, script command with debug
 * may operate connection directly, we may change flags of client in transaction,
 * so we should keep them in the main thread.
 *
 * Please notice that this function may be called reentrantly, i,e, the same goes
 * for handleClientsFromIOThread and processClientsOfAllIOThreads. For example,
 * when processing script command, it may call processEventsWhileBlocked to
 * process new events, if the clients with fired events from the same io thread,
 * it may call this function reentrantly. */
void processClientsFromIOThread(ioThread *t) {
    listNode *node = NULL;

    while (listLength(main_thread_processing_clients[t->id])) {
        /* Each time we pop up only the first client to process to guarantee
         * reentrancy safety. */
        if (node) zfree(node);
        node = listFirst(main_thread_processing_clients[t->id]);
        listUnlinkNode(main_thread_processing_clients[t->id], node);
        client *c = listNodeValue(node);

        /* Make sure the client is readable or writable in io thread to
         * avoid data race. */
        serverAssert(!(c->io_flags & (CLIENT_IO_READ_ENABLED | CLIENT_IO_WRITE_ENABLED)));
        serverAssert(!(c->flags & CLIENT_CLOSE_ASAP));

        /* Let main thread to run it, set running thread id first. */
        c->running_tid = IOTHREAD_MAIN_THREAD_ID;

        /* If a read error occurs, handle it in the main thread first, since we
         * want to print logs about client information before freeing. */
        if (c->read_error) handleClientReadError(c);

        /* The client is asked to close. */
        if (isClientClosing(c)) {
            freeClient(c);
            continue;
        }

        /* Update the client in the mem usage */
        updateClientMemUsageAndBucket(c);

        /* Process the pending command and input buffer. */
        if (!c->read_error && c->io_flags & CLIENT_IO_PENDING_COMMAND) {
            c->flags |= CLIENT_PENDING_COMMAND;
            if (processPendingCommandAndInputBuffer(c) == C_ERR) {
                /* If the client is no longer valid, it must be freed safely. */
                continue;
            }
        }

        /* We may have pending replies if io thread may not finish writing
         * reply to client, so we did not put the client in pending write
         * queue. And we should do that first since we may keep the client
         * in main thread instead of returning to io threads. */
        if (!(c->flags & CLIENT_PENDING_WRITE) && clientHasPendingReplies(c))
            putClientInPendingWriteQueue(c);

        /* The client only can be processed in the main thread, otherwise data
         * race will happen, since we may touch client's data in main thread. */
        if (c->flags & CLIENT_CLOSE_ASAP ||
            c->flags & CLIENT_SLAVE ||
            c->flags & CLIENT_PUBSUB ||
            c->flags & CLIENT_MONITOR ||
            c->flags & CLIENT_BLOCKED ||
            c->flags & CLIENT_UNBLOCKED ||
            c->flags & CLIENT_TRACKING ||
            c->flags & CLIENT_MULTI ||
            c->flags & CLIENT_LUA_DEBUG ||
            c->flags & CLIENT_LUA_DEBUG_SYNC)
        {
            keepClientInMainThread(c);
            continue;
        }

        /* If the client is still valid, let io threads handle its writing. */
        if (c->flags & CLIENT_PENDING_WRITE ||
            c->flags & (CLIENT_REPLY_SKIP|CLIENT_REPLY_OFF|CLIENT_REPLY_SKIP_NEXT))
        {
            /* Remove this client from pending write clients queue of main thread. */
            if (c->flags & CLIENT_PENDING_WRITE) {
                c->flags &= ~CLIENT_PENDING_WRITE;
                listUnlinkNode(server.clients_pending_write, &c->clients_pending_write_node);
            }
            c->running_tid = c->tid;
            listLinkNodeHead(pending_clients_for_io_threads[c->tid], node);
            node = NULL;
            continue;
        }

        /* TODO: remaining clients are handled by main thread, what's the client status?
         * it should not reach here? */
        serverPanic("Unknown client status");
        keepClientInMainThread(c); /* Keep it mian thread if we don't know its status? */
    }
    if (node) zfree(node);

    /* Trigger the io thread to handle these clients ASAP to make them processed
     * in parallel.
     *
     * If AOF fsync policy is always, we should not let io thread handle these
     * clients now since we don't flush AOF buffer to file and sync yet.
     * So these clients will be delayed to send io threads in beforeSleep after
     * flushAppendOnlyFile. 
     * 
     * If we are in processEventsWhileBlocked, we don't send clients to io threads
     * now, we want to update server.events_processed_while_blocked accurately. */
    if (listLength(pending_clients_for_io_threads[t->id]) &&
        server.aof_fsync != AOF_FSYNC_ALWAYS &&
        !ProcessingEventsWhileBlocked)
    {
        pthread_mutex_lock(&(t->pending_clients_mutex));
        listJoin(t->pending_clients, pending_clients_for_io_threads[t->id]);
        pthread_mutex_unlock(&(t->pending_clients_mutex));
        triggerEventNotifier(t->pending_clients_notifier);
    }
}

/* When the io thread finishes processing the client with the read event, it will
 * notify the main thread through event triggering in beforesleep. The main thread
 * handles the event through this function. */
void handleClientsFromIOThread(struct aeEventLoop *el, int fd, void *ptr, int mask) {
    UNUSED(el);
    UNUSED(mask);

    ioThread *t = ptr;

    /* Handle fd event first. */
    serverAssert(fd == getReadEventFd(main_thread_pending_clients_notifier[t->id]));
    handleEventNotifier(main_thread_pending_clients_notifier[t->id]);

    /* Get the list of clients to process. */
    pthread_mutex_lock(&main_thread_pending_clients_mutexs[t->id]);
    listJoin(main_thread_processing_clients[t->id], main_thread_pending_clients[t->id]);
    pthread_mutex_unlock(&main_thread_pending_clients_mutexs[t->id]);
    if (listLength(main_thread_processing_clients[t->id]) == 0) return;

    /* Process the clients from IO threads. */
    processClientsFromIOThread(t);
}

/* In the new threaded io design, one thread may process multiple clients, so when
 * an io thread notifies the main thread of an event, there may be multiple clients
 * with commands that need to be processed. But in the event handler function
 * handleClientsFromIOThread may be blocked when processing the specific command,
 * the previous clients can not get a reply, and the subsequent clients can not be
 * processed, so we need to handle this scenario in beforeSleep. The function is to
 * process the commands of subsequent clients from io threads. And another function
 * sendPendingClientsToIOThreads make sure clients from io thread can get replies.
 * See also beforeSleep.*/
void processClientsOfAllIOThreads(void) {
    for (int i = 1; i < server.io_threads_num; i++) {
        processClientsFromIOThread(&io_threads[i]);
    }
}

/* After the main thread processes the clients, it will send the clients back to
 * io threads to handle, and fire an event, the io thread handles the event by
 * this function. If the client is not binded to the event loop, we should bind
 * it first and install read handler, and we don't uninstall client read handler
 * unless freeing client. If the client has pending reply, we just reply to client
 * first, and then install write handler if needed. */
void handleClientsFromMainThread(struct aeEventLoop *ae, int fd, void *ptr, int mask) {
    UNUSED(ae);
    UNUSED(mask);

    ioThread *t = ptr;

    /* Handle fd event first. */
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
        serverAssert(!(c->io_flags & (CLIENT_IO_READ_ENABLED | CLIENT_IO_WRITE_ENABLED)));
        /* Main thread must handle clients with CLIENT_CLOSE_ASAP flag, since
         * we only set 'closing' state when clients in io thread are freed ASAP. */
        serverAssert(!(c->flags & CLIENT_CLOSE_ASAP));

        /* Link client in IO thread clients list first. */
        serverAssert(c->io_thread_client_list_node == NULL);
        listAddNodeTail(t->clients, c);
        c->io_thread_client_list_node = listLast(t->clients);

        /* The client is asked to close, we just let main thread free it. */
        if (isClientClosing(c)) {
            connSetReadHandler(c->conn, NULL);
            connSetWriteHandler(c->conn, NULL);
            putInPendingClienstForMainThread(c);
            continue;
        }

        /* Enable read and write and reset some flags. */
        c->io_flags |= CLIENT_IO_READ_ENABLED | CLIENT_IO_WRITE_ENABLED;
        c->io_flags &= ~CLIENT_IO_PENDING_COMMAND;

        /* Only bind once, we never remove read handler unless freeing client. */
        if (!connHasReadHandler(c->conn)) {
            connRebindEventLoop(c->conn, t->el);
            connSetReadHandler(c->conn, readQueryFromClient);
        }

        /* If the client has pending replies, write replies to client. */
        if (clientHasPendingReplies(c)) {
            writeToClient(c, 0);
            if (!isClientClosing(c) && clientHasPendingReplies(c)) {
                connSetWriteHandler(c->conn, sendReplyToClient);
            }
        }
    }
    listRelease(clients);
}

/* Handle the jobs from main thread, currently just to wake io thread up from
 * sleep, i.e. waiting events in aeApiPoll. */
void handleJobsFromMainThread(struct aeEventLoop *ae, int fd, void *ptr, int mask) {
    UNUSED(ae);
    UNUSED(fd);
    UNUSED(mask);

    /* Just handle event, do nothing now. */
    ioThread *t = ptr;
    handleEventNotifier(t->job_notifier);
}

void ioThreadBeforeSleep(struct aeEventLoop *el) {
    ioThread *t = el->privdata;

    /* Check if i am pausing */
    int paused;
    atomicGetWithSync(t->paused, paused);
    if (paused == IO_THREAD_PAUSING) {
        atomicSetWithSync(t->paused, IO_THREAD_PAUSED);
        /* Wait for resuming */
        while (paused != IO_THREAD_RESUMING) {
            atomicGetWithSync(t->paused, paused);
        }
        atomicSetWithSync(t->paused, IO_THREAD_UNPAUSED);
    }

    /* Check if there are clients to be processed in main thread, and then join
     * them to the list of main thread. */
    if (listLength(t->pending_clients_for_main_thread) > 0) {
        pthread_mutex_lock(&main_thread_pending_clients_mutexs[t->id]);
        listJoin(main_thread_pending_clients[t->id], t->pending_clients_for_main_thread);
        pthread_mutex_unlock(&main_thread_pending_clients_mutexs[t->id]);
        /* Trigger an event, maybe an error is returned when buffer is full
         * if using pipe, but no worry, main thread will handle all clients
         * in list when receiving a notification. */
        triggerEventNotifier(main_thread_pending_clients_notifier[t->id]);
    }
}

#define IO_THREAD_CRON_CLIENTS_ITERATIONS 10
/* Do the cron job in IO thread, now only support to handle clients and check. */
int ioThreadCron(struct aeEventLoop *eventLoop, long long id, void *ptr) {
    UNUSED(eventLoop);
    UNUSED(id);

    ioThread *t = ptr;

    /* Clients cron in io thread, and iterate over all clients in 1s. */
    int iterations = max(IO_THREAD_CRON_CLIENTS_ITERATIONS, listLength(t->clients)/10);
    iterations = min(iterations, (int)listLength(t->clients));
    while (listLength(t->clients) && iterations--) {
        listNode *head = listFirst(t->clients);
        client *c = listNodeValue(head);
        listRotateHeadToTail(t->clients);

        serverAssert(c->tid == t->id);
        serverAssert(c->running_tid == t->id);
        serverAssert(connHasReadHandler(c->conn));

        /* The client is asked to close, let main thread to free finally. */
        if (isClientClosing(c)) {
            connSetReadHandler(c->conn, NULL);
            connSetWriteHandler(c->conn, NULL);
            putInPendingClienstForMainThread(c);
            continue;
        }
    }

    return 100; /* Run once per 100 millisecond */
}

/* The main function of IO thread, it will run an event loop. The mian thread
 * and IO thread will communicate through event notifier. */
void *ioThreadMain(void *ptr) {
    ioThread *t = ptr;
    char thdname[16];
    snprintf(thdname, sizeof(thdname), "io_thd_%ld", t->id);
    redis_set_thread_title(thdname);
    redisSetCpuAffinity(server.server_cpulist);
    makeThreadKillable();
    aeSetBeforeSleepProc(t->el, ioThreadBeforeSleep);
    t->el->privdata = t;
    aeMain(t->el);
    return NULL;
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
        atomicSetWithSync(t->paused, IO_THREAD_UNPAUSED);

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
            serverLog(LL_WARNING, "Fatal: Can't register file event for io thread notifications.");
            exit(1);
        }

        if (aeCreateFileEvent(t->el, getReadEventFd(t->pending_clients_notifier),
                              AE_READABLE, handleClientsFromMainThread, t) != AE_OK)
        {
            serverLog(LL_WARNING, "Fatal: Can't register file event for io thread notifications.");
            exit(1);
        }

        if (aeCreateTimeEvent(t->el, 1, ioThreadCron, t, NULL) != AE_OK) {
            serverLog(LL_WARNING, "Fatal: Can't create event loop timers.");
            exit(1);
        }

        /* Create IO thread */
        if (pthread_create(&t->tid, NULL, ioThreadMain, (void*)t) != 0) {
            serverLog(LL_WARNING, "Fatal: Can't initialize IO thread.");
            exit(1);
        }

        /* For main thread */
        pending_clients_for_io_threads[i] = listCreate();
        main_thread_pending_clients[i] = listCreate();
        main_thread_processing_clients[i] = listCreate();
        pthread_mutex_init(&main_thread_pending_clients_mutexs[i], attr);
        main_thread_pending_clients_notifier[i] = createEventNotifier();
        if (aeCreateFileEvent(server.el, getReadEventFd(main_thread_pending_clients_notifier[i]),
                              AE_READABLE, handleClientsFromIOThread, t) != AE_OK)
        {
            serverLog(LL_WARNING, "Fatal: Can't register file event for main thread notifications.");
            exit(1);
        }
        if (attr) zfree(attr);
    }
}

/* Kill the IO threads, TODO: release the applied resources. */
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
