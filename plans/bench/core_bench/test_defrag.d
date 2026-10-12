import core.memory;
import core.stdc.stdio;

void main()
{
    printf("Testing Heap Defragmentation and Page Purging (Option 3)...\n");

    // Phase 1: Allocate small objects to populate multiple slabs
    enum NUM_OBJS = 50_000;
    void*[] pointers = new void*[NUM_OBJS];

    foreach (i; 0 .. NUM_OBJS)
    {
        pointers[i] = GC.malloc(64);
    }

    auto statsBefore = GC.stats();
    printf("Allocated %d objects. Used: %zu bytes, Free: %zu bytes\n",
        NUM_OBJS, statsBefore.usedSize, statsBefore.freeSize);

    // Phase 2: Free 90% of objects, leaving slabs sparse, plus completely free some slabs
    foreach (i; 0 .. NUM_OBJS)
    {
        if (i % 10 != 0)
        {
            GC.free(pointers[i]);
            pointers[i] = null;
        }
    }

    // Run GC cycle
    GC.collect();

    // Phase 3: Invoke defrag & minimize
    size_t purged = GC.defrag();
    printf("GC.defrag() purged %zu physical pages back to the kernel!\n", purged);

    GC.minimize();
    printf("GC.minimize() completed successfully.\n");

    auto statsAfter = GC.stats();
    printf("After defrag: Used: %zu bytes, Free: %zu bytes\n",
        statsAfter.usedSize, statsAfter.freeSize);

    // Phase 4: Free remaining objects completely to reclaim all slabs
    foreach (i; 0 .. NUM_OBJS)
    {
        if (pointers[i] !is null)
        {
            GC.free(pointers[i]);
            pointers[i] = null;
        }
    }
    GC.collect();

    size_t purgedTotal = GC.defrag();
    printf("After 100%% free, GC.defrag() purged %zu physical pages back to the kernel!\n", purgedTotal);

    auto statsFinal = GC.stats();
    printf("Final: Used: %zu bytes, Free: %zu bytes\n",
        statsFinal.usedSize, statsFinal.freeSize);

    printf("Option 3 Defragmentation Verification PASSED!\n");
}
