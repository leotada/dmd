import core.stdc.stdlib, core.stdc.string, core.stdc.stdio;
import core.time, core.thread;
void main() {
    enum frames = 1200, per = 5000;
    auto ft = new long[](frames);
    void*[64] ring;
    foreach (f; 0 .. frames) {
        auto a = MonoTime.currTime;
        foreach (k; 0 .. per) {
            auto sz = 32 + (k & 7) * 32;
            auto p = malloc(sz); memset(p, 0, sz);
            auto i = k & 63;
            if (ring[i]) free(ring[i]);
            ring[i] = p;
            if ((k & 63) == 0) { auto e = malloc(448); memset(e, 0, 448); free(e); }
        }
        ft[f] = (MonoTime.currTime - a).total!"usecs";
        long spent = ft[f];
        while (spent < 16666) { Thread.sleep(dur!"usecs"(500)); spent = (MonoTime.currTime - a).total!"usecs"; }
    }
    import std.algorithm : sort;
    auto s = ft.dup; sort(s);
    printf("malloc floor p50=%lld p99=%lld max=%lld\n", s[frames/2], s[frames*99/100], s[$-1]);
}
