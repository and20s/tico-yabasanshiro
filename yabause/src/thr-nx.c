/*
        Copyright 2019 devMiyax(smiyaxdev@gmail.com)

This file is part of YabaSanshiro.

        YabaSanshiro is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

YabaSanshiro is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

        You should have received a copy of the GNU General Public License
along with YabaSanshiro; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
*/

#include <switch/kernel/thread.h>
#include <switch/kernel/svc.h>
#include <switch/kernel/mutex.h>
#include <switch/kernel/condvar.h>
#include <switch/result.h>
#include "core.h"
#include "threads.h"

#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <malloc.h>
#include <stdio.h>
#include <string.h>

//////////////////////////////////////////////////////////////////////////////

// Thread handles for each Yabause subthread
static Thread thread_handle[YAB_NUM_THREADS] = {0};

// Thread stacks for each Yabause subthread (to avoid leaks)
static void *thread_stack[YAB_NUM_THREADS] = {0};

/* ========================================================================= */
/* Per-thread Sleep/Wake using Mutex + CondVar                              */
/* On Linux, YabThreadSleep() calls pause() and YabThreadWake() sends       */
/* SIGUSR1. On NX, we replicate this with a per-thread condvar so threads   */
/* properly block instead of busy-looping (which wastes CPU cycles).        */
/* ========================================================================= */

static Mutex thread_sleep_mutex[YAB_NUM_THREADS];
static CondVar thread_sleep_cond[YAB_NUM_THREADS];
static int thread_sleep_flag[YAB_NUM_THREADS]; // 1 = woken, 0 = sleeping
static int thread_sleep_init[YAB_NUM_THREADS]; // 1 = initialized

// Which sleep slot is the current thread using? (set per-thread via thread-local)
static _Thread_local int tls_thread_id = -1;

int YabThreadInit()
{
    memset(thread_sleep_init, 0, sizeof(thread_sleep_init));
    memset(thread_sleep_flag, 0, sizeof(thread_sleep_flag));
    return 0;
}

void YabThreadDeInit(void)
{
    // Reset all per-thread sleep primitives so the next YabThreadInit()
    // starts with a clean slate. libnx Mutex/CondVar are value-types
    // (no kernel handle) so re-initializing is sufficient.
    for (int i = 0; i < YAB_NUM_THREADS; i++)
    {
        if (thread_sleep_init[i])
        {
            mutexInit(&thread_sleep_mutex[i]);
            condvarInit(&thread_sleep_cond[i]);
            thread_sleep_flag[i] = 0;
            thread_sleep_init[i] = 0;
        }
        // Ensure thread handles are zeroed (threads should already be
        // joined/closed by their respective DeInit calls).
        memset(&thread_handle[i], 0, sizeof(Thread));
        if (thread_stack[i])
        {
            // Only free if we believe the thread actually exited.
            // YabThreadWait already frees stacks for clean exits;
            // for force-paused threads it intentionally leaks. So
            // only free if the handle was zeroed by a clean join.
            // Since we can't distinguish safely, just NULL the pointer.
            thread_stack[i] = NULL;
        }
    }
    printf("YabThreadDeInit: all thread state reset\n");
}

static void InitSleepForThread(unsigned int id)
{
    if (!thread_sleep_init[id])
    {
        mutexInit(&thread_sleep_mutex[id]);
        condvarInit(&thread_sleep_cond[id]);
        thread_sleep_flag[id] = 0;
        thread_sleep_init[id] = 1;
    }
}

//////////////////////////////////////////////////////////////////////////////

// Wrapper that sets TLS thread ID before calling the real function
typedef struct
{
    void *(*func)(void *);
    void *arg;
    unsigned int id;
} ThreadWrapper;

static void ThreadEntryWrapper(void *arg)
{
    ThreadWrapper *w = (ThreadWrapper *)arg;
    tls_thread_id = w->id;
    void *(*func)(void *) = w->func;
    void *real_arg = w->arg;
    unsigned int id = w->id;
    free(w);

    // Initialize sleep primitives for this thread
    InitSleepForThread(id);

    func(real_arg);
}

int YabThreadStart(unsigned int id, const char *name, void *(*func)(void *), void *arg)
{
    Result result;

    // 2MB stack – the VDP/GL thread drives mesa/nouveau which needs
    // deep stack frames; 512KB overflows into the heap on Switch with NIR/NVC0.
    const size_t stack_size = 0x200000;
    void *stack = memalign(0x1000, stack_size);

    if (stack == NULL)
    {
        printf("Fail to allocate stack for thread %d\n", id);
        return -1;
    }

    thread_stack[id] = stack;

    // Initialize sleep primitives before thread starts
    InitSleepForThread(id);

    // Wrap the thread function to set TLS thread ID
    ThreadWrapper *wrapper = (ThreadWrapper *)malloc(sizeof(ThreadWrapper));
    if (!wrapper)
    {
        free(stack);
        thread_stack[id] = NULL;
        return -1;
    }
    wrapper->func = func;
    wrapper->arg = arg;
    wrapper->id = id;

    // Priority 0x20 (32) — higher than default 0x2C (44) for emulator threads
    if ((result = threadCreate(&thread_handle[id], ThreadEntryWrapper, wrapper, stack, stack_size, 0x20, -2)) != 0)
    {
        printf("Fail to create thread %d (0x%x)\n", id, result);
        free(wrapper);
        free(stack);
        thread_stack[id] = NULL;
        return -1;
    }

    if ((result = threadStart(&thread_handle[id])) != 0)
    {
        printf("Fail to start thread %d (0x%x)\n", id, result);
        threadClose(&thread_handle[id]);
        free(stack);
        thread_stack[id] = NULL;
        return -1;
    }
    return 0;
}

//////////////////////////////////////////////////////////////////////////////

void YabThreadWait(unsigned int id)
{
    printf("YabThreadWait: waiting for thread %d to exit...\n", id);

    // Wake thread in case it's sleeping, so it can check its exit condition
    YabThreadWake(id);

    // Use a timeout to prevent infinite hang if the thread is stuck.
    // Try up to 5 seconds (50 * 100ms), then force-stop.
    Result rc;
    int attempts = 0;
    const int max_attempts = 50; // 50 * 100ms = 5 seconds
    do
    {
        rc = svcWaitSynchronizationSingle(thread_handle[id].handle, 100000000ULL); // 100ms
        attempts++;
        if (attempts < max_attempts && R_VALUE(rc) == KERNELRESULT(TimedOut))
        {
            // Thread hasn't exited yet — wake it again in case it's stuck sleeping
            YabThreadWake(id);
            if (attempts % 10 == 0)
            {
                printf("YabThreadWait: thread %d still alive after %d ms\n", id, attempts * 100);
            }
        }
    } while (R_VALUE(rc) == KERNELRESULT(TimedOut) && attempts < max_attempts);

    if (attempts >= max_attempts)
    {
        printf("YabThreadWait: thread %d did not exit after %d ms — force-pausing!\n", id, max_attempts * 100);

        // CRITICAL: Force-pause the thread to prevent it from executing unmapped code
        // after the NRO is unloaded. __libnx_exit does NOT kill non-main threads,
        // so a leaked running thread will crash hbl when it tries to execute code
        // at an address that was unmapped.
        Result pause_rc = svcSetThreadActivity(thread_handle[id].handle, 1); // ThreadActivity_Paused
        printf("YabThreadWait: svcSetThreadActivity(Paused) for thread %d: 0x%x\n", id, pause_rc);

        // Close the handle but do NOT free the stack or unmap memory.
        // The thread is frozen and still references its stack. Freeing it
        // would corrupt memory. The kernel keeps the thread alive (paused)
        // until the process terminates.
        svcCloseHandle(thread_handle[id].handle);
        memset(&thread_handle[id], 0, sizeof(Thread));
        // thread_stack[id] intentionally leaked — thread still references it
        return;
    }

    printf("YabThreadWait: thread %d exited cleanly after %d ms\n", id, attempts * 100);

    threadClose(&thread_handle[id]);
    if (thread_stack[id])
    {
        free(thread_stack[id]);
        thread_stack[id] = NULL;
    }

    // Reset sleep state
    if (thread_sleep_init[id])
    {
        thread_sleep_flag[id] = 0;
    }
}

//////////////////////////////////////////////////////////////////////////////

void YabThreadYield(void)
{
    svcSleepThread(0);
}

//////////////////////////////////////////////////////////////////////////////

void YabThreadSleep(void)
{
    // Block the current thread until YabThreadWake() signals it.
    // On Linux this is pause() + SIGUSR1. Here we use condvar.
    int id = tls_thread_id;
    if (id < 0 || id >= YAB_NUM_THREADS || !thread_sleep_init[id])
    {
        // Fallback: yield briefly instead of busy-looping
        svcSleepThread(1000000); // 1ms
        return;
    }

    mutexLock(&thread_sleep_mutex[id]);
    while (!thread_sleep_flag[id])
    {
        // Wait with 10ms timeout to prevent permanent deadlock
        // if wake signal was missed before we entered wait
        condvarWaitTimeout(&thread_sleep_cond[id], &thread_sleep_mutex[id], 10000000ULL);
    }
    thread_sleep_flag[id] = 0; // Consume the wake signal
    mutexUnlock(&thread_sleep_mutex[id]);
}

void YabThreadUSleep(unsigned int stime)
{
    svcSleepThread((u64)stime * 1000);
}

int YabNanosleep(u64 ns)
{
    svcSleepThread(ns);
    return 0;
}

//////////////////////////////////////////////////////////////////////////////

void YabThreadRemoteSleep(unsigned int id)
{
}

//////////////////////////////////////////////////////////////////////////////

void YabThreadWake(unsigned int id)
{
    if (id >= YAB_NUM_THREADS || !thread_sleep_init[id])
        return;

    mutexLock(&thread_sleep_mutex[id]);
    thread_sleep_flag[id] = 1;
    condvarWakeOne(&thread_sleep_cond[id]);
    mutexUnlock(&thread_sleep_mutex[id]);
}

/* ========================================================================= */
/* Optimized Event Queue using Mutex + CondVar (Producer-Consumer)          */
/* ========================================================================= */

typedef struct YabEventQueue_switch
{
    int *buffer;
    int capacity;
    int size;
    int in;
    int out;
    Mutex mutex;
    CondVar cond_not_full;  // Wait here if queue is full
    CondVar cond_not_empty; // Wait here if queue is empty
} YabEventQueue_switch;

YabEventQueue *YabThreadCreateQueue(int qsize)
{
    YabEventQueue_switch *p = (YabEventQueue_switch *)malloc(sizeof(YabEventQueue_switch));
    if (!p)
        return NULL;

    p->buffer = (int *)malloc(sizeof(int) * qsize);
    if (!p->buffer)
    {
        free(p);
        return NULL;
    }

    p->capacity = qsize;
    p->size = 0;
    p->in = 0;
    p->out = 0;
    mutexInit(&p->mutex);
    condvarInit(&p->cond_not_full);
    condvarInit(&p->cond_not_empty);

    return (YabEventQueue *)p;
}

void YabThreadDestoryQueue(YabEventQueue *queue_t)
{
    if (!queue_t)
        return;
    YabEventQueue_switch *queue = (YabEventQueue_switch *)queue_t;

    free(queue->buffer);
    free(queue);
    // Mutex/CondVar do not need explicit destruction in libnx if malloc'd memory is freed
}

void YabAddEventQueue(YabEventQueue *queue_t, int evcode)
{
    YabEventQueue_switch *queue = (YabEventQueue_switch *)queue_t;

    mutexLock(&queue->mutex);

    // Wait while full, with timeout to prevent permanent deadlocks
    while (queue->size == queue->capacity)
    {
        condvarWaitTimeout(&queue->cond_not_full, &queue->mutex, 100000000ULL); // 100ms
    }

    queue->buffer[queue->in] = evcode;
    queue->in = (queue->in + 1) % queue->capacity;
    queue->size++;

    // Signal consumer
    condvarWakeOne(&queue->cond_not_empty);
    mutexUnlock(&queue->mutex);
    // printf("YabAddEventQueue\n");
}

int YabClearEventQueue(YabEventQueue *queue_t)
{
    YabEventQueue_switch *queue = (YabEventQueue_switch *)queue_t;

    mutexLock(&queue->mutex);
    queue->size = 0;
    queue->in = 0;
    queue->out = 0;
    condvarWakeAll(&queue->cond_not_full);
    mutexUnlock(&queue->mutex);
    return 0;
}

int YabWaitEventQueue(YabEventQueue *queue_t)
{
    int value;
    YabEventQueue_switch *queue = (YabEventQueue_switch *)queue_t;

    mutexLock(&queue->mutex);

    // Wait while empty, with timeout to prevent permanent deadlocks.
    // Use 100ms timeout — if the signal was lost, we re-check the condition.
    while (queue->size == 0)
    {
        condvarWaitTimeout(&queue->cond_not_empty, &queue->mutex, 100000000ULL); // 100ms
    }

    // printf("YabWaitEventQueue: Get\n");
    value = queue->buffer[queue->out];
    queue->out = (queue->out + 1) % queue->capacity;
    queue->size--;

    // Signal producer that space is available
    condvarWakeOne(&queue->cond_not_full);
    mutexUnlock(&queue->mutex);

    return value;
}

int YaGetQueueSize(YabEventQueue *queue_t)
{
    int size = 0;
    YabEventQueue_switch *queue = (YabEventQueue_switch *)queue_t;
    mutexLock(&queue->mutex);
    size = queue->size;
    mutexUnlock(&queue->mutex);
    return size;
}

/* ========================================================================= */
/* Mutex Wrapper                                                            */
/* ========================================================================= */

typedef struct YabMutex_switch
{
    Mutex mutex;
} YabMutex_switch;

void YabThreadLock(YabMutex *mtx)
{
    if (!mtx)
        return;
    YabMutex_switch *pmtx = (YabMutex_switch *)mtx;
    mutexLock(&pmtx->mutex);
}

void YabThreadUnLock(YabMutex *mtx)
{
    if (!mtx)
        return;
    YabMutex_switch *pmtx = (YabMutex_switch *)mtx;
    mutexUnlock(&pmtx->mutex);
}

int YabThreadIsLockedByCurrentThread(YabMutex *mtx)
{
    if (!mtx)
        return 0;
    YabMutex_switch *pmtx = (YabMutex_switch *)mtx;
    return mutexIsLockedByCurrentThread(&pmtx->mutex) ? 1 : 0;
}

YabMutex *YabThreadCreateMutex()
{
    YabMutex_switch *mtx = (YabMutex_switch *)malloc(sizeof(YabMutex_switch));
    if (mtx)
        mutexInit(&mtx->mutex);
    return (YabMutex *)mtx;
}

void YabThreadFreeMutex(YabMutex *mtx)
{
    if (mtx != NULL)
    {
        YabMutex_switch *pmtx = (YabMutex_switch *)mtx;
        free(pmtx);
    }
}

/* ========================================================================= */
/* CPU Affinity                                                             */
/* ========================================================================= */

// Switch has 4 Cortex-A57 cores: 0, 1, 2 are available to apps (core 3 is reserved by HOS).
// Return core 0 as the "fastest" (all cores are identical, but core 0 is the default).
// NOTE: The VDP thread overrides this — see vdp2.cpp VdpProc() which pins to core 2.
int YabThreadGetFastestCpuIndex()
{
    return 0;
}

void YabThreadSetCurrentThreadAffinityMask(int mask)
{
    // Set preferred core for the calling thread and restrict affinity to that core only
    // This effectively pins the thread to the specified core.
    if (mask >= 0 && mask <= 2)
    {
        // preferred_core = mask, affinity_mask = (1 << mask)
        svcSetThreadCoreMask(CUR_THREAD_HANDLE, mask, (1ULL << mask));
    }
}

int YabThreadGetCurrentThreadAffinityMask()
{
    return 0;
}