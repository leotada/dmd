#define _GNU_SOURCE
#include <signal.h>
#include <sys/time.h>
#include <ucontext.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/syscall.h>
#define MAXS 400000
static unsigned long samples[MAXS]; static int tids[MAXS]; static volatile int n;
static void h(int s, siginfo_t* si, void* uc) { ucontext_t* c = uc; int i = __atomic_fetch_add(&n, 1, __ATOMIC_RELAXED); if (i < MAXS) { samples[i] = c->uc_mcontext.gregs[REG_RIP]; tids[i] = syscall(SYS_gettid); } }
static void dump(int s) {
  FILE* f = fopen(getenv("PROF_OUT") ? getenv("PROF_OUT") : "/tmp/prof2.out", "w");
  int m = n < MAXS ? n : MAXS;
  for (int i = 0; i < m; i++) fprintf(f, "%d %lx\n", tids[i], samples[i]);
  fclose(f);
}
__attribute__((constructor)) static void init(void) {
  struct sigaction sa = {0}; sa.sa_sigaction = h; sa.sa_flags = SA_SIGINFO | SA_RESTART; sigaction(SIGPROF, &sa, 0);
  struct sigaction sd = {0}; sd.sa_handler = dump; sigaction(SIGRTMIN + 4, &sd, 0);
  struct itimerval it = {{0, 10000}, {0, 10000}}; setitimer(ITIMER_PROF, &it, 0);
}
