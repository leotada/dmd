import core.stdc.stdlib, core.stdc.string, core.stdc.stdio, core.time;
void main(string[] args) {
    enum N = 5_000_000;
    foreach (ringSize; [64, 1 << 16, 1 << 20, 1 << 22]) {
        auto ring = cast(void**) calloc(ringSize, (void*).sizeof);
        auto t = MonoTime.currTime;
        foreach (k; 0 .. N) {
            auto sz = 32 + (k & 7) * 32;
            auto p = malloc(sz); memset(p, 0, sz);
            auto i = k & (ringSize - 1);
            if (ring[i]) free(ring[i]);
            ring[i] = p;
        }
        printf("malloc ring=%d: %.1f ns/alloc\n", ringSize, (MonoTime.currTime - t).total!"nsecs" / cast(double) N);
    }
}
