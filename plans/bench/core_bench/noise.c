#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <pthread.h>
#include <unistd.h>
static long now_us(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000000L + t.tv_nsec / 1000; }
static volatile int stop;
static void* burner(void* a) { volatile unsigned long x = 0; while (!stop) { for (int i = 0; i < 1000; i++) x += i; } return 0; }
int main(int argc, char** argv) {
  int secs = atoi(argv[1]), nburn = atoi(argv[2]);
  pthread_t t[64];
  for (int i = 0; i < nburn; i++) pthread_create(&t[i], 0, burner, 0);
  // main emulates a game thread: 60 Hz, 250 us of work, sleeping in between; measures frame wall time
  long over1 = 0, over2 = 0, mx = 0, n = 0;
  long end = now_us() + secs * 1000000L;
  while (now_us() < end) {
    long t0 = now_us(); volatile unsigned long x = 0;
    while (now_us() - t0 < 250) { for (int i = 0; i < 100; i++) x += i; }
    long d = now_us() - t0;
    if (d > 1000) over1++; if (d > 2000) over2++; if (d > mx) mx = d; n++;
    long rest = 16666 - d; if (rest > 0) usleep(rest);
  }
  stop = 1;
  printf("noise: %d burner threads, %ld frames of 250us work: max=%ld us over1ms=%ld over2ms=%ld\n", nburn, n, mx, over1, over2);
}
