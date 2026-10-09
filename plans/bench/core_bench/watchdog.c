#define _GNU_SOURCE
#include <signal.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <execinfo.h>
#include <stdatomic.h>
#include <ucontext.h>
#include <sys/syscall.h>
#include <dirent.h>
// A watcher thread notices that a frame has been running for more than a threshold and asks the main thread
// (by signal) where it is.
static pthread_t target;
static _Atomic long frame_start_us;   // 0 = not in a frame
static _Atomic long frame_id;
#define MAXS 4096
static void* samples[MAXS][16]; static int nframes[MAXS]; static long sample_us[MAXS]; static int ns; static int sample_tid[MAXS]; static long sample_group[MAXS]; static _Atomic long group_id; static int main_tid;
static long now_us(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000000L + t.tv_nsec / 1000; }
static void handler(int s) {
  int idx = __atomic_fetch_add(&ns, 1, __ATOMIC_RELAXED);
  if (idx < MAXS) { nframes[idx] = backtrace(samples[idx], 16); sample_us[idx] = now_us() - frame_start_us; sample_tid[idx] = syscall(SYS_gettid); sample_group[idx] = group_id; }
}
static void signal_all(void) {
  DIR* d = opendir("/proc/self/task"); struct dirent* e;
  while ((e = readdir(d))) { int tid = atoi(e->d_name); if (tid > 0) syscall(SYS_tgkill, getpid(), tid, SIGUSR2); }
  closedir(d);
}
static void* watcher(void* a) {
  long threshold = (long) a, last = -1;
  while (1) {
    long st = frame_start_us, id = frame_id;
    if (st != 0 && id != last && now_us() - st > threshold) { last = id; group_id = id; signal_all(); }
    usleep(50);
  }
  return 0;
}
void wd_start(long threshold_us) {
  target = pthread_self(); main_tid = syscall(SYS_gettid);
  struct sigaction sa = {0}; sa.sa_handler = handler; sa.sa_flags = SA_RESTART; sigaction(SIGUSR2, &sa, 0);
  pthread_t t; pthread_create(&t, 0, watcher, (void*) threshold_us);
}
void wd_frame_begin(long id) { frame_id = id; frame_start_us = now_us(); }
void wd_frame_end(void) { frame_start_us = 0; }
void wd_dump(void) {
  for (int i = 0; i < ns && i < MAXS; i++) {
    fprintf(stderr, "WD frame=%ld %s tid=%d %ldus:", sample_group[i], sample_tid[i] == main_tid ? "MAIN" : "other", sample_tid[i], sample_us[i]);
    for (int j = 0; j < nframes[i]; j++) fprintf(stderr, " %p", samples[i][j]);
    fprintf(stderr, "\n");
  }
}
