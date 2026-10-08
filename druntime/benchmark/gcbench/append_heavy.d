/**
 * Array-append workload: `~=`, `.capacity`, `reserve` and `assumeSafeAppend`.
 *
 * These paths go through the GC's block-info and `getArrayUsed` /
 * `setArrayUsed` interface, which Phase 1 must reimplement efficiently.
 *
 * Usage: append_heavy [outer-iterations]
 */
import core.memory;
import std.conv;

__gshared size_t N = 20_000;

void main(string[] args)
{
    if (args.length > 1)
        N = to!size_t(args[1]);

    size_t sink;

    // 1. Many short arrays grown by ~=.
    foreach (i; 0 .. N)
    {
        int[] a;
        foreach (j; 0 .. 100)
            a ~= cast(int) j;
        sink += a.length + a.capacity;
    }

    // 2. One buffer reused through assumeSafeAppend.
    int[] buf;
    foreach (i; 0 .. N)
    {
        buf.length = 0;
        assumeSafeAppend(buf);
        foreach (j; 0 .. 100)
            buf ~= cast(int) j;
        sink += buf.length;
    }

    // 3. Appending to slices of a shared backing block (stomping checks).
    auto base = new int[](1024);
    foreach (i; 0 .. N)
    {
        auto s = base[0 .. i % 1024];
        s ~= 1;
        sink += s.capacity;
    }

    // 4. reserve() followed by exact fill, then a growing string.
    foreach (i; 0 .. N / 4)
    {
        int[] a;
        a.reserve(256);
        foreach (j; 0 .. 256)
            a ~= cast(int) j;
        string str;
        foreach (j; 0 .. 64)
            str ~= 'x';
        sink += a.length + str.length;
    }

    if (sink == 0)
        assert(0); // keep the loops alive
}
