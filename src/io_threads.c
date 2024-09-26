#include "io_threads.h"

static __thread int thread_id = 0; /* Thread local var */
static pthread_t io_threads[IO_THREADS_MAX_NUM] = {0};
static pthread_mutex_t io_threads_mutex[IO_THREADS_MAX_NUM];

/* IO jobs queue functions - Used to send jobs from the main-thread to the IO thread. */
typedef void (*job_handler)(void *);
typedef struct iojob {
    job_handler handler;
    void *data;
} iojob;

typedef struct IOJobQueue {
    iojob *ring_buffer;
    size_t size;
    pthread_cond_t cond;
    pthread_mutex_t cond_mutex;
    _Atomic size_t head __attribute__((aligned(CACHE_LINE_SIZE))); /* Next write index for producer (main-thread) */
    _Atomic size_t tail __attribute__((aligned(CACHE_LINE_SIZE))); /* Next read index for consumer  (IO-thread) */
} IOJobQueue;
IOJobQueue io_jobs[IO_THREADS_MAX_NUM] = {0};

/* Initialize the job queue with a specified number of items. */
static void IOJobQueue_init(IOJobQueue *jq, size_t item_count) {
    debugServerAssertWithInfo(NULL, NULL, inMainThread());
    jq->ring_buffer = zcalloc(item_count * sizeof(iojob));
    jq->size = item_count; /* Total number of items */
    jq->head = 0;
    jq->tail = 0;
    pthread_mutex_init(&jq->cond_mutex, NULL);
    pthread_cond_init(&jq->cond, NULL);
}

/* Clean up the job queue and free allocated memory. */
static void IOJobQueue_cleanup(IOJobQueue *jq) {
    debugServerAssertWithInfo(NULL, NULL, inMainThread());
    zfree(jq->ring_buffer);
    memset(jq, 0, sizeof(*jq));
    pthread_cond_destroy(&jq->cond);
    pthread_mutex_destroy(&jq->cond_mutex);
}

static int IOJobQueue_isFull(const IOJobQueue *jq) {
    debugServerAssertWithInfo(NULL, NULL, inMainThread());
    size_t current_head = atomic_load_explicit(&jq->head, memory_order_relaxed);
    /* We don't use memory_order_acquire for the tail due to performance reasons,
     * In the worst case we will just assume wrongly the buffer is full and the main thread will do the job by itself. */
    size_t current_tail = atomic_load_explicit(&jq->tail, memory_order_relaxed);
    size_t next_head = (current_head + 1) % jq->size;
    return next_head == current_tail;
}

/* Attempt to push a new job to the queue from the main thread.
 * the caller must ensure the queue is not full before calling this function. */
static void IOJobQueue_push(IOJobQueue *jq, job_handler handler, void *data) {
    debugServerAssertWithInfo(NULL, NULL, inMainThread());
    /* Assert the queue is not full - should not happen as the caller should check for it before. */
    serverAssert(!IOJobQueue_isFull(jq));

    /* No need to use atomic acquire for the head, as the main thread is the only one that writes to the head index. */
    size_t current_head = atomic_load_explicit(&jq->head, memory_order_relaxed);
    size_t next_head = (current_head + 1) % jq->size;

    /* We store directly the job's fields to avoid allocating a new iojob structure. */
    serverAssert(jq->ring_buffer[current_head].data == NULL);
    serverAssert(jq->ring_buffer[current_head].handler == NULL);
    jq->ring_buffer[current_head].data = data;
    jq->ring_buffer[current_head].handler = handler;

    /* memory_order_release to make sure the data is visible to the consumer (the IO thread). */
    atomic_store_explicit(&jq->head, next_head, memory_order_release);
    pthread_cond_signal(&jq->cond);
}

/* Returns the number of jobs currently available for consumption in the given job queue.
 *
 * This function  ensures memory visibility for the jobs by
 * using a memory acquire fence when there are jobs available. */
static size_t IOJobQueue_availableJobs(const IOJobQueue *jq) {
    debugServerAssertWithInfo(NULL, NULL, !inMainThread());
    /* We use memory_order_acquire to make sure the head and the job's fields are visible to the consumer (IO thread). */
    size_t current_head = atomic_load_explicit(&jq->head, memory_order_acquire);
    size_t current_tail = atomic_load_explicit(&jq->tail, memory_order_relaxed);

    if (current_head >= current_tail) {
        return current_head - current_tail;
    } else {
        return jq->size - (current_tail - current_head);
    }
}

/* Checks if the job Queue is empty.
 * returns 1 if the buffer is currently empty, 0 otherwise.
 * Called by the main-thread only.
 * This function uses relaxed memory order, so the caller need to use an acquire
 * memory fence before calling this function to be sure it has the latest index
 * from the other thread, especially when called repeatedly. */
static int IOJobQueue_isEmpty(const IOJobQueue *jq) {
    size_t current_head = atomic_load_explicit(&jq->head, memory_order_relaxed);
    size_t current_tail = atomic_load_explicit(&jq->tail, memory_order_relaxed);
    return current_head == current_tail;
}

/* Removes the next job from the given job queue by advancing the tail index.
 * Called by the IO thread.
 * The caller must ensure that the queue is not empty before calling this function.
 * This function uses relaxed memory order, so the caller need to use an release memory fence
 * after calling this function to make sure the updated tail is visible to the producer (main thread). */
static void IOJobQueue_removeJob(IOJobQueue *jq) {
    debugServerAssertWithInfo(NULL, NULL, !inMainThread());
    size_t current_tail = atomic_load_explicit(&jq->tail, memory_order_relaxed);
    jq->ring_buffer[current_tail].data = NULL;
    jq->ring_buffer[current_tail].handler = NULL;
    atomic_store_explicit(&jq->tail, (current_tail + 1) % jq->size, memory_order_relaxed);
}

/* Retrieves the next job handler and data from the job queue without removal.
 * Called by the consumer (IO thread). Caller must ensure queue is not empty.*/
static void IOJobQueue_peek(const IOJobQueue *jq, job_handler *handler, void **data) {
    debugServerAssertWithInfo(NULL, NULL, !inMainThread());
    size_t current_tail = atomic_load_explicit(&jq->tail, memory_order_relaxed);
    iojob *job = &jq->ring_buffer[current_tail];
    *handler = job->handler;
    *data = job->data;
}

/* End of IO job queue functions */

int inMainThread(void) {
    return thread_id == 0;
}

/* Wait until the IO-thread is done with the client */
void waitForClientIO(client *c) {
    /* No need to wait if the client was not offloaded to the IO thread. */
    if (c->io_read_state == CLIENT_IDLE && c->io_write_state == CLIENT_IDLE) return;

    /* Wait for read operation to complete if pending. */
    while (c->io_read_state == CLIENT_PENDING_IO) {
        atomic_thread_fence(memory_order_acquire);
    }

    /* Wait for write operation to complete if pending. */
    while (c->io_write_state == CLIENT_PENDING_IO) {
        atomic_thread_fence(memory_order_acquire);
    }

    /* Final memory barrier to ensure all changes are visible */
    atomic_thread_fence(memory_order_acquire);
}

static void *IOThreadMain(void *myid) {
    /* The ID is the thread ID number (from 1 to server.io_threads_num-1). ID 0 is the main thread. */
    long id = (long)myid;
    char thdname[32];

    serverAssert(server.io_threads_num > 0);
    serverAssert(id > 0 && id < server.io_threads_num);
    snprintf(thdname, sizeof(thdname), "io_thd_%ld", id);
    redis_set_thread_title(thdname);
    redisSetCpuAffinity(server.server_cpulist);
    makeThreadKillable();

    thread_id = (int)id;
    // printf("IOThreadMain: %d\n", thread_id);
    size_t jobs_to_process = 0;
    IOJobQueue *jq = &io_jobs[id];
    while (1) {
        /* Wait for jobs */
        // for (int j = 0; j < 1000000; j++) {
        //     jobs_to_process = IOJobQueue_availableJobs(jq);
        //     if (jobs_to_process) break;
        // }

        // /* Give the main thread a chance to stop this thread. */
        // if (jobs_to_process == 0) {
        //     pthread_mutex_lock(&io_threads_mutex[id]);
        //     pthread_mutex_unlock(&io_threads_mutex[id]);
        //     continue;
        // }

        pthread_mutex_lock(&jq->cond_mutex);
        while (!(jobs_to_process = IOJobQueue_availableJobs(jq))) {
            pthread_cond_wait(&jq->cond, &jq->cond_mutex);
        }
        pthread_mutex_unlock(&jq->cond_mutex);

        for (size_t j = 0; j < jobs_to_process; j++) {
            // printf("IOThreadMain job: %d\n", j);
            job_handler handler;
            void *data;
            /* We keep the job in the queue until it's processed. This ensures that if the main thread checks
             * and finds the queue empty, it can be certain that the IO thread is not currently handling any job. */
            IOJobQueue_peek(jq, &handler, &data);
            handler(data);
            /* Remove the job after it was processed */
            IOJobQueue_removeJob(jq);
        }
        /* Memory barrier to make sure the main thread sees the updated tail index.
         * We do it once per loop and not per tail-update for optimization reasons.
         * As the main-thread main concern is to check if the queue is empty, it's enough to do it once at the end. */
        atomic_thread_fence(memory_order_release);
    }
    return NULL;
}

#define IO_JOB_QUEUE_SIZE 2048
static void createIOThread(int id) {
    pthread_t tid;
    pthread_mutex_init(&io_threads_mutex[id], NULL);
    IOJobQueue_init(&io_jobs[id], IO_JOB_QUEUE_SIZE);
    // pthread_mutex_lock(&io_threads_mutex[id]); /* Thread will be stopped. */
    if (pthread_create(&tid, NULL, IOThreadMain, (void *)(long)id) != 0) {
        serverLog(LL_WARNING, "Fatal: Can't initialize IO thread, pthread_create failed with: %s", strerror(errno));
        exit(1);
    }
    io_threads[id] = tid;
}

void killIOThreads(void) {
    int err, j;
    for (j = 0; j < server.io_threads_num; j++) {
        if (io_threads[j] == pthread_self()) continue;
        if (io_threads[j] && pthread_cancel(io_threads[j]) == 0) {
            if ((err = pthread_join(io_threads[j],NULL)) != 0) {
                serverLog(LL_WARNING,
                    "IO thread(tid:%lu) can not be joined: %s",
                        (unsigned long)io_threads[j], strerror(err));
            } else {
                serverLog(LL_WARNING,
                    "IO thread(tid:%lu) terminated",(unsigned long)io_threads[j]);
            }
        }
    }
}


/* Initialize the data structures needed for I/O threads. */
void initIOThreads(void) {
    /* Don't spawn any thread if the user selected a single thread:
     * we'll handle I/O directly from the main thread. */
    if (server.io_threads_num == 1) return;

    serverAssert(server.io_threads_num <= IO_THREADS_MAX_NUM);

    /* Spawn and initialize the I/O threads. */
    for (int i = 1; i < server.io_threads_num; i++) {
        createIOThread(i);
    }
}

int trySendReadToIOThreads(client *c) {
    if (server.io_threads_num <= 1) return C_ERR;
    if (!server.io_threads_do_reads) return C_ERR;
    /* If IO thread is areadty reading, return C_OK to make sure the main thread will not handle it. */
    if (c->io_read_state != CLIENT_IDLE) return C_OK;
    /* Currently, replica/master writes are not offloaded and are processed synchronously. */
    if (c->flags & CLIENT_MASTER || getClientType(c) == CLIENT_TYPE_SLAVE) return C_ERR;
    /* With Lua debug client we may call connWrite directly in the main thread */
    if (c->flags & CLIENT_LUA_DEBUG) return C_ERR;
    /* For simplicity let the main-thread handle the blocked clients */
    if (c->flags & CLIENT_BLOCKED || c->flags & CLIENT_UNBLOCKED) return C_ERR;
    if (c->flags & CLIENT_CLOSE_ASAP) return C_ERR;
    size_t tid = (c->id % (server.io_threads_num - 1)) + 1;

    /* Handle case where client has a pending IO write job on a different thread:
     * 1. A write job is still pending (io_write_state == CLIENT_PENDING_IO)
     * 2. The pending job is on a different thread (c->cur_tid != tid)
     *
     * This situation can occur if active_io_threads_num increased since the
     * original job assignment. In this case, we keep the job on its current
     * thread to ensure the same thread handles the client's I/O operations. */
    if (c->io_write_state == CLIENT_PENDING_IO && c->cur_tid != (uint8_t)tid) tid = c->cur_tid;

    IOJobQueue *jq = &io_jobs[tid];
    if (IOJobQueue_isFull(jq)) return C_ERR;

    c->cur_tid = tid;
    c->read_flags = canParseCommand(c) ? 0 : READ_FLAGS_DONT_PARSE;
    c->read_flags |= authRequired(c) ? READ_FLAGS_AUTH_REQUIRED : 0;

    c->io_read_state = CLIENT_PENDING_IO;
    connSetPostponeUpdateState(c->conn, 1);
    IOJobQueue_push(jq, ioThreadReadQueryFromClient, c);
    c->flags |= CLIENT_PENDING_READ;
    listLinkNodeTail(server.clients_pending_io_read, &c->pending_read_list_node);
    return C_OK;
}

/* This function attempts to offload the client's write to an I/O thread.
 * Returns C_OK if the client's writes were successfully offloaded to an I/O thread,
 * or C_ERR if the client is not eligible for offloading. */
int trySendWriteToIOThreads(client *c) {
    if (server.io_threads_num <= 1) return C_ERR;
    /* The I/O thread is already writing for this client. */
    if (c->io_write_state != CLIENT_IDLE) return C_OK;
    /* Nothing to write */
    if (!clientHasPendingReplies(c)) return C_ERR;
    /* Currently, replica/master writes are not offloaded and are processed synchronously. */
    if (c->flags & CLIENT_MASTER || getClientType(c) == CLIENT_TYPE_SLAVE) return C_ERR;
    /* We can't offload debugged clients as the main-thread may read at the same time  */
    if (c->flags & CLIENT_LUA_DEBUG) return C_ERR;

    size_t tid = (c->id % (server.io_threads_num - 1)) + 1;
    /* Handle case where client has a pending IO read job on a different thread:
     * 1. A read job is still pending (io_read_state == CLIENT_PENDING_IO)
     * 2. The pending job is on a different thread (c->cur_tid != tid)
     *
     * This situation can occur if active_io_threads_num increased since the
     * original job assignment. In this case, we keep the job on its current
     * thread to ensure the same thread handles the client's I/O operations. */
    if (c->io_read_state == CLIENT_PENDING_IO && c->cur_tid != (uint8_t)tid) tid = c->cur_tid;

    IOJobQueue *jq = &io_jobs[tid];
    if (IOJobQueue_isFull(jq)) return C_ERR;

    c->cur_tid = tid;
    if (c->flags & CLIENT_PENDING_WRITE) {
        /* We move the client to the io pending write queue */
        listUnlinkNode(server.clients_pending_write, &c->clients_pending_write_node);
    } else {
        c->flags |= CLIENT_PENDING_WRITE;
    }
    serverAssert(c->clients_pending_write_node.prev == NULL && c->clients_pending_write_node.next == NULL);
    listLinkNodeTail(server.clients_pending_io_write, &c->clients_pending_write_node);

    /* Save the last block of the reply list to io_last_reply_block and the used
     * position to io_last_bufpos. The I/O thread will write only up to
     * io_last_bufpos, regardless of the c->bufpos value. This is to prevent I/O
     * threads from reading data that might be invalid in their local CPU cache. */
    c->io_last_reply_block = listLast(c->reply);
    if (c->io_last_reply_block) {
        c->io_last_bufpos = ((clientReplyBlock *)listNodeValue(c->io_last_reply_block))->used;
    } else {
        c->io_last_bufpos = (size_t)c->bufpos;
    }
    serverAssert(c->bufpos > 0 || c->io_last_bufpos > 0);

    /* The main-thread will update the client state after the I/O thread completes the write. */
    connSetPostponeUpdateState(c->conn, 1);
    c->write_flags = 0;
    c->io_write_state = CLIENT_PENDING_IO;

    IOJobQueue_push(jq, ioThreadWriteToClient, c);
    // printf("trySendWriteToIOThreads\n");
    return C_OK;
}