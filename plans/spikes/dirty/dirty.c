// Spike: can the kernel tell us which pages of a 2 GiB heap were written during a concurrent mark, cheaply?
// Linux >= 6.7: userfaultfd with UFFD_FEATURE_WP_ASYNC + the PAGEMAP_SCAN ioctl.
//
//   gcc -O2 -o dirty dirty.c -lpthread && ./dirty [MiB]
//
// Measures: arming the whole region, the cost of the first write to an armed page, scanning the dirty set (and re-arming
// it in the same call) for 0, 1k, 10k, 100k dirty pages, and what a concurrent writer pays while we scan.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <linux/userfaultfd.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define PAGE 4096UL

static double now_us(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e6 + t.tv_nsec / 1e3;
}

static int pagemap_fd;

// Scan [start, end): report written pages in `regions` and re-arm them. Returns the number of regions, or -1.
static long scan(void *start, void *end, struct page_region *regions, size_t cap, unsigned long flags, unsigned long *pages_out) {
    struct pm_scan_arg arg;
    memset(&arg, 0, sizeof arg);
    arg.size = sizeof arg;
    arg.flags = flags;
    arg.start = (uint64_t)(uintptr_t)start;
    arg.end = (uint64_t)(uintptr_t)end;
    arg.vec = (uint64_t)(uintptr_t)regions;
    arg.vec_len = cap;
    arg.category_mask = PAGE_IS_WRITTEN;
    arg.return_mask = PAGE_IS_WRITTEN;
    long n = ioctl(pagemap_fd, PAGEMAP_SCAN, &arg);
    if (n < 0) return -1;
    if (pages_out) {
        unsigned long p = 0;
        for (long i = 0; i < n; i++) p += regions[i].end - regions[i].start;
        p /= PAGE;
        *pages_out = p;
    }
    // walk_end tells how far it got; if it stopped early (vec full) the caller would continue from there.
    if (arg.walk_end != arg.end) return -2;
    return n;
}

static volatile int stop_writer;
static char *region;
static size_t npages;
static double writer_worst_us, writer_total_us;
static unsigned long writer_ops;

static void *writer(void *arg) {
    (void)arg;
    uint64_t x = 88172645463325252ULL;
    while (!stop_writer) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        size_t p = x % npages;
        double t0 = now_us();
        region[p * PAGE] = (char)x;
        double dt = now_us() - t0;
        writer_total_us += dt;
        writer_ops++;
        if (dt > writer_worst_us) writer_worst_us = dt;
        // about 20 writes per ms, like a frame that dirties a few hundred pages
        struct timespec ts = {0, 50000};
        nanosleep(&ts, NULL);
    }
    return NULL;
}

int main(int argc, char **argv) {
    size_t mib = argc > 1 ? strtoul(argv[1], 0, 10) : 2048;
    size_t size = mib << 20;
    npages = size / PAGE;

    region = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (region == MAP_FAILED) { perror("mmap"); return 1; }
    madvise(region, size, MADV_NOHUGEPAGE); // 4 KiB granularity, like a worst case
    double t0 = now_us();
    memset(region, 1, size);
    printf("region %zu MiB (%zu pages) faulted in: %.0f ms\n", mib, npages, (now_us() - t0) / 1e3);

    int uffd = syscall(SYS_userfaultfd, O_CLOEXEC | O_NONBLOCK | UFFD_USER_MODE_ONLY);
    if (uffd < 0) { perror("userfaultfd"); return 2; }
    struct uffdio_api api = {.api = UFFD_API, .features = UFFD_FEATURE_WP_ASYNC | UFFD_FEATURE_WP_UNPOPULATED};
    if (ioctl(uffd, UFFDIO_API, &api) < 0) { perror("UFFDIO_API (WP_ASYNC)"); return 3; }
    struct uffdio_register reg = {.range = {.start = (uintptr_t)region, .len = size}, .mode = UFFDIO_REGISTER_MODE_WP};
    if (ioctl(uffd, UFFDIO_REGISTER, &reg) < 0) { perror("UFFDIO_REGISTER"); return 4; }

    pagemap_fd = open("/proc/self/pagemap", O_RDONLY);
    if (pagemap_fd < 0) { perror("pagemap"); return 5; }

    enum { CAP = 1 << 20 };
    struct page_region *regions = malloc(CAP * sizeof *regions);

    // Arm everything: all pages count as written the first time, so this scan write-protects the lot.
    t0 = now_us();
    unsigned long pages = 0;
    long n = scan(region, region + size, regions, CAP, PM_SCAN_WP_MATCHING | PM_SCAN_CHECK_WPASYNC, &pages);
    double arm_ms = (now_us() - t0) / 1e3;
    printf("arm (write-protect %zu MiB): %.2f ms (regions=%ld pages=%lu)\n", mib, arm_ms, n, pages);
    if (n == -1) { perror("PAGEMAP_SCAN"); return 6; }

    // Nothing written since: the scan must be empty.
    t0 = now_us();
    n = scan(region, region + size, regions, CAP, PM_SCAN_WP_MATCHING | PM_SCAN_CHECK_WPASYNC, &pages);
    printf("scan with nothing written: %.2f ms (regions=%ld pages=%lu)\n", (now_us() - t0) / 1e3, n, pages);

    // Cost of the first write to an armed page (the fault is resolved by the kernel, no signal, no handler).
    {
        enum { K = 20000 };
        double w0 = now_us();
        for (size_t i = 0; i < K; i++) region[(i * 97 % npages) * PAGE] = 2;
        double first = (now_us() - w0) / K;
        w0 = now_us();
        for (size_t i = 0; i < K; i++) region[(i * 97 % npages) * PAGE] = 3;
        double second = (now_us() - w0) / K;
        printf("write to an armed page: %.2f us first time, %.2f us afterwards\n", first, second);
        n = scan(region, region + size, regions, CAP, PM_SCAN_WP_MATCHING | PM_SCAN_CHECK_WPASYNC, &pages);
    }

    // Scan cost against the number of dirty pages (spread out, so many separate regions).
    size_t counts[] = {1000, 10000, 100000, 400000};
    for (size_t c = 0; c < sizeof counts / sizeof *counts; c++) {
        size_t k = counts[c] < npages ? counts[c] : npages;
        size_t stride = npages / k;
        for (size_t i = 0; i < k; i++) region[i * stride * PAGE] = 4;
        t0 = now_us();
        n = scan(region, region + size, regions, CAP, PM_SCAN_WP_MATCHING | PM_SCAN_CHECK_WPASYNC, &pages);
        printf("scan + re-arm with %zu dirty pages: %.2f ms (regions=%ld pages=%lu)\n", k, (now_us() - t0) / 1e3, n, pages);
    }

    // A writer thread dirties ~20 pages a ms while we scan repeatedly. What does it pay?
    pthread_t th;
    stop_writer = 0;
    pthread_create(&th, NULL, writer, NULL);
    for (int i = 0; i < 50; i++) {
        usleep(20000);
        scan(region, region + size, regions, CAP, PM_SCAN_WP_MATCHING | PM_SCAN_CHECK_WPASYNC, &pages);
    }
    stop_writer = 1;
    pthread_join(th, NULL);
    printf("writer during 50 scans of %zu MiB: %lu writes, mean %.2f us, worst %.0f us\n", mib, writer_ops,
           writer_total_us / writer_ops, writer_worst_us);

    // Kernel-mode access to an armed page: read() into the region must still work.
    int fd = open("/dev/zero", O_RDONLY);
    scan(region, region + size, regions, CAP, PM_SCAN_WP_MATCHING | PM_SCAN_CHECK_WPASYNC, &pages);
    ssize_t r = read(fd, region + 10 * PAGE, 3 * PAGE);
    printf("read() into armed pages: %zd (errno %d)\n", r, r < 0 ? errno : 0);
    n = scan(region, region + size, regions, CAP, PM_SCAN_WP_MATCHING | PM_SCAN_CHECK_WPASYNC, &pages);
    printf("those pages are reported dirty: %lu\n", pages);
    return 0;
}
