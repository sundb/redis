/* Linux io_uring based ae.c module with epoll fallback
 *
 * Copyright (c) 2024-Present, Redis Ltd.
 * All rights reserved.
 *
 * Licensed under your choice of (a) the Redis Source Available License 2.0
 * (RSALv2); or (b) the Server Side Public License v1 (SSPLv1); or (c) the
 * GNU Affero General Public License v3 (AGPLv3).
 *
 * This module uses io_uring multishot poll for event readiness notification.
 * Requires Linux 5.6+ and liburing. If io_uring initialization fails at
 * runtime (old kernel, insufficient resources), falls back to epoll
 * transparently within the same binary.
 */

#include <liburing.h>
#include <sys/epoll.h>
#include <poll.h>

#define AE_IO_URING_RING_ENTRIES 4096

#define IOURING_USERDATA(fd, mask) (((uint64_t)(unsigned)(fd)) | ((uint64_t)(mask) << 32))
#define IOURING_USERDATA_FD(ud) ((int)((ud) & 0xFFFFFFFF))
#define IOURING_USERDATA_MASK(ud) ((int)((ud) >> 32))

#define IOURING_TAG_BATCH_READ  0x100
#define IOURING_TAG_BATCH_WRITE 0x200

typedef struct aeApiState {
    int use_io_uring;
    /* epoll fallback state */
    int epfd;
    struct epoll_event *epoll_events;
    /* io_uring state */
    struct io_uring ring;
    int ring_entries;
} aeApiState;

static int aeApiCreate(aeEventLoop *eventLoop) {
    aeApiState *state = zmalloc(sizeof(aeApiState));
    if (!state) return -1;
    memset(state, 0, sizeof(*state));
    state->epfd = -1;

    int entries = eventLoop->setsize;
    if (entries < AE_IO_URING_RING_ENTRIES)
        entries = AE_IO_URING_RING_ENTRIES;

    if (io_uring_queue_init(entries, &state->ring, 0) == 0) {
        state->use_io_uring = 1;
        state->ring_entries = entries;
        eventLoop->apidata = state;
        return 0;
    }

    /* io_uring unavailable, fall back to epoll */
    state->use_io_uring = 0;
    state->epoll_events = zmalloc(sizeof(struct epoll_event) * eventLoop->setsize);
    if (!state->epoll_events) {
        zfree(state);
        return -1;
    }
    state->epfd = epoll_create(1024);
    if (state->epfd == -1) {
        zfree(state->epoll_events);
        zfree(state);
        return -1;
    }
    anetCloexec(state->epfd);
    eventLoop->apidata = state;
    return 0;
}

static int aeApiResize(aeEventLoop *eventLoop, int setsize) {
    aeApiState *state = eventLoop->apidata;
    if (state->use_io_uring) return 0;
    state->epoll_events = zrealloc(state->epoll_events,
                                   sizeof(struct epoll_event) * setsize);
    return 0;
}

static void aeApiFree(aeEventLoop *eventLoop) {
    aeApiState *state = eventLoop->apidata;
    if (state->use_io_uring) {
        io_uring_queue_exit(&state->ring);
    } else {
        close(state->epfd);
        zfree(state->epoll_events);
    }
    zfree(state);
}

static int aeApiAddEvent(aeEventLoop *eventLoop, int fd, int mask) {
    aeApiState *state = eventLoop->apidata;

    if (state->use_io_uring) {
        int old_mask = eventLoop->events[fd].mask;
        int full_mask = old_mask | mask;

        /* Cancel existing multishot poll if modifying */
        if (old_mask != AE_NONE) {
            struct io_uring_sqe *sqe = io_uring_get_sqe(&state->ring);
            if (!sqe) return -1;
            io_uring_prep_poll_remove(sqe, IOURING_USERDATA(fd, old_mask));
            io_uring_sqe_set_data64(sqe, 0);
            io_uring_submit(&state->ring);

            struct io_uring_cqe *cqe;
            io_uring_wait_cqe(&state->ring, &cqe);
            io_uring_cqe_seen(&state->ring, cqe);
        }

        struct io_uring_sqe *sqe = io_uring_get_sqe(&state->ring);
        if (!sqe) return -1;

        unsigned poll_mask = 0;
        if (full_mask & AE_READABLE) poll_mask |= POLLIN;
        if (full_mask & AE_WRITABLE) poll_mask |= POLLOUT;

        io_uring_prep_poll_multishot(sqe, fd, poll_mask);
        io_uring_sqe_set_data64(sqe, IOURING_USERDATA(fd, full_mask));
        io_uring_submit(&state->ring);
        return 0;
    }

    /* epoll fallback */
    struct epoll_event ee = {0};
    int op = eventLoop->events[fd].mask == AE_NONE ?
            EPOLL_CTL_ADD : EPOLL_CTL_MOD;
    ee.events = 0;
    mask |= eventLoop->events[fd].mask;
    if (mask & AE_READABLE) ee.events |= EPOLLIN;
    if (mask & AE_WRITABLE) ee.events |= EPOLLOUT;
    ee.data.fd = fd;
    if (epoll_ctl(state->epfd, op, fd, &ee) == -1) return -1;
    return 0;
}

static void aeApiDelEvent(aeEventLoop *eventLoop, int fd, int delmask) {
    aeApiState *state = eventLoop->apidata;

    if (state->use_io_uring) {
        int old_mask = eventLoop->events[fd].mask;
        int new_mask = old_mask & (~delmask);

        struct io_uring_sqe *sqe = io_uring_get_sqe(&state->ring);
        if (!sqe) return;
        io_uring_prep_poll_remove(sqe, IOURING_USERDATA(fd, old_mask));
        io_uring_sqe_set_data64(sqe, 0);
        io_uring_submit(&state->ring);

        struct io_uring_cqe *cqe;
        io_uring_wait_cqe(&state->ring, &cqe);
        io_uring_cqe_seen(&state->ring, cqe);

        if (new_mask != AE_NONE) {
            sqe = io_uring_get_sqe(&state->ring);
            if (!sqe) return;

            unsigned poll_mask = 0;
            if (new_mask & AE_READABLE) poll_mask |= POLLIN;
            if (new_mask & AE_WRITABLE) poll_mask |= POLLOUT;

            io_uring_prep_poll_multishot(sqe, fd, poll_mask);
            io_uring_sqe_set_data64(sqe, IOURING_USERDATA(fd, new_mask));
            io_uring_submit(&state->ring);
        }
        return;
    }

    /* epoll fallback */
    struct epoll_event ee = {0};
    int mask = eventLoop->events[fd].mask & (~delmask);
    ee.events = 0;
    if (mask & AE_READABLE) ee.events |= EPOLLIN;
    if (mask & AE_WRITABLE) ee.events |= EPOLLOUT;
    ee.data.fd = fd;
    if (mask != AE_NONE) {
        epoll_ctl(state->epfd, EPOLL_CTL_MOD, fd, &ee);
    } else {
        epoll_ctl(state->epfd, EPOLL_CTL_DEL, fd, &ee);
    }
}

static int aeApiPoll(aeEventLoop *eventLoop, struct timeval *tvp) {
    aeApiState *state = eventLoop->apidata;

    if (state->use_io_uring) {
        int numevents = 0;
        struct io_uring_cqe *cqe;

        if (tvp != NULL) {
            struct __kernel_timespec ts;
            ts.tv_sec = tvp->tv_sec;
            ts.tv_nsec = tvp->tv_usec * 1000;
            int ret = io_uring_submit_and_wait_timeout(&state->ring, &cqe,
                                                       1, &ts, NULL);
            if (ret < 0 && ret != -ETIME && ret != -EINTR)
                return 0;
        } else {
            int ret = io_uring_submit_and_wait(&state->ring, 1);
            if (ret < 0 && ret != -EINTR)
                return 0;
        }

        unsigned head;
        int seen = 0;
        io_uring_for_each_cqe(&state->ring, head, cqe) {
            uint64_t ud = io_uring_cqe_get_data64(cqe);
            int tag = IOURING_USERDATA_MASK(ud);
            seen++;

            /* Skip cancel completions and batch I/O completions */
            if (ud == 0 || tag >= IOURING_TAG_BATCH_READ)
                continue;

            int fd = IOURING_USERDATA_FD(ud);
            int res = cqe->res;
            int mask = 0;

            if (res < 0) {
                mask = AE_READABLE | AE_WRITABLE;
            } else {
                if (res & POLLIN)  mask |= AE_READABLE;
                if (res & POLLOUT) mask |= AE_WRITABLE;
                if (res & POLLERR) mask |= AE_READABLE | AE_WRITABLE;
                if (res & POLLHUP) mask |= AE_READABLE | AE_WRITABLE;
            }

            if (mask && numevents < eventLoop->setsize) {
                eventLoop->fired[numevents].fd = fd;
                eventLoop->fired[numevents].mask = mask;
                numevents++;
            }
        }
        io_uring_cq_advance(&state->ring, seen);
        return numevents;
    }

    /* epoll fallback */
    int retval, numevents = 0;
    retval = epoll_wait(state->epfd, state->epoll_events, eventLoop->setsize,
            tvp ? (tvp->tv_sec*1000 + (tvp->tv_usec + 999)/1000) : -1);
    if (retval > 0) {
        int j;
        numevents = retval;
        for (j = 0; j < numevents; j++) {
            int mask = 0;
            struct epoll_event *e = state->epoll_events + j;

            if (e->events & EPOLLIN) mask |= AE_READABLE;
            if (e->events & EPOLLOUT) mask |= AE_WRITABLE;
            if (e->events & EPOLLERR) mask |= AE_WRITABLE | AE_READABLE;
            if (e->events & EPOLLHUP) mask |= AE_WRITABLE | AE_READABLE;
            eventLoop->fired[j].fd = e->data.fd;
            eventLoop->fired[j].mask = mask;
        }
    } else if (retval == -1 && errno != EINTR) {
        panic("aeApiPoll: epoll_wait, %s", strerror(errno));
    }
    return numevents;
}

static char *aeApiName(void) {
    return "io_uring";
}
