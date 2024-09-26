#ifndef IO_THREADS_H
#define IO_THREADS_H

#include "server.h"

#define IO_THREADS_MAX_NUM 128

void initIOThreads(void);
void killIOThreads(void);
int inMainThread(void);
int trySendReadToIOThreads(client *c);
int trySendWriteToIOThreads(client *c);
int tryOffloadFreeObjToIOThreads(robj *o);
int tryOffloadFreeArgvToIOThreads(client *c);
void adjustIOThreadsByEventLoad(int numevents, int increase_only);
void drainIOThreadsQueue(void);
void trySendPollJobToIOThreads(void);

#endif /* IO_THREADS_H */
