// A multi-threaded game written without care for memory, to test the collector with
// the allocation patterns the single-threaded bullet hell does not have:
//
//  * a main thread at 60 fps that builds a scene graph each frame (class tree, arrays,
//    associative arrays, strings), nothing reused;
//  * two job threads running "pathfinding" and "AI" all the time: open/closed lists,
//    associative arrays, dynamic arrays that grow, small classes;
//  * a streaming thread that loads and drops 1 to 8 MiB "assets" (large allocations)
//    every few frames and keeps a window of them alive;
//  * a level of `levelMiB` of live data (map, entities).
//
// No pools, no GC.collect, no GC.disable. Measures the frame time of the main thread.
//
//   game_mt [seconds=60] [levelMiB=512]
import core.stdc.stdio : printf;
import core.stdc.stdlib : qsort;
import core.atomic : atomicLoad, atomicStore, atomicOp;
import core.thread : Thread;
import core.time;
import std.conv : to;
import std.format : format;
import std.array : array;
import std.algorithm : map, filter, sort;

shared bool stop;
shared size_t jobsDone, assetsLoaded;

uint seedOf(uint s) { return s * 1664525 + 1013904223; }

class Node
{
    string name;
    Node[] children;
    float[16] transform;
    Node parent;
    this(string n, Node p) { name = n; parent = p; }
}

class Tile { Tile[] neighbours; ubyte[] pixels; string name; }
__gshared Tile[] level;

struct Cell { int x, y; }

// "pathfinding": A*-like search on a hash grid, allocates all its containers
size_t search(uint seed)
{
    bool[Cell] closed;
    Cell[] open;
    open ~= Cell(0, 0);
    size_t expanded;
    while (open.length && expanded < 3000)
    {
        auto c = open[$ - 1];
        open = open[0 .. $ - 1];
        if (c in closed) continue;
        closed[c] = true;
        expanded++;
        seed = seedOf(seed);
        foreach (d; 0 .. 4)
        {
            auto n = Cell(c.x + cast(int)((seed >> (d * 3)) & 3) - 1, c.y + cast(int)((seed >> (d * 3 + 8)) & 3) - 1);
            if (n !in closed) open ~= n;
        }
    }
    return expanded + closed.length;
}

void jobThread(uint id)
{
    uint seed = id * 7919;
    while (!atomicLoad(stop))
    {
        seed = seedOf(seed);
        auto r = search(seed);
        auto names = new string[](32);
        foreach (i, ref n; names) n = "agent-" ~ (r + i).to!string;
        atomicOp!"+="(jobsDone, 1);
    }
}

void streamThread()
{
    ubyte[][] window;
    uint seed = 12345;
    while (!atomicLoad(stop))
    {
        seed = seedOf(seed);
        auto size = (1 + (seed >> 8) % 8) * 1024 * 1024;
        auto asset = new ubyte[](size);
        asset[0] = 1; asset[$ - 1] = 2;
        window ~= asset;
        if (window.length > 24) window = window[1 .. $];   // drop the oldest
        atomicOp!"+="(assetsLoaded, 1);
        Thread.sleep(dur!"msecs"(40));
    }
}

Node buildScene(uint frame, ref uint seed)
{
    auto root = new Node("root", null);
    foreach (i; 0 .. 40)
    {
        auto group = new Node(format("group-%d-%d", frame % 100, i), root);
        root.children ~= group;
        foreach (j; 0 .. 12)
        {
            seed = seedOf(seed);
            auto n = new Node("mesh-" ~ (seed % 1000).to!string, group);
            n.transform[0] = seed;
            group.children ~= n;
        }
    }
    return root;
}

extern(C) int cmpLong(const void* a, const void* b)
{
    auto x = *cast(const long*) a, y = *cast(const long*) b;
    return x < y ? -1 : (x > y);
}

void main(string[] args)
{
    auto seconds = args.length > 1 ? args[1].to!int : 60;
    auto levelMiB = args.length > 2 ? args[2].to!size_t : 512;

    level = new Tile[](levelMiB * 1024 * 1024 / (4096 + 128));
    foreach (i, ref t; level)
    {
        t = new Tile;
        t.pixels = new ubyte[](4096);
        t.name = "tile-" ~ i.to!string;
        if (i) t.neighbours = [level[i - 1]];
    }

    Thread[] ts;
    foreach (i; 0 .. 2) { auto t = new Thread({ jobThread(i); }); t.start(); ts ~= t; }
    auto st = new Thread(&streamThread); st.start(); ts ~= st;

    immutable total = seconds * 60;
    auto ft = new long[](total);
    uint seed = 99;
    size_t nodes;
    foreach (f; 0 .. total)
    {
        immutable t0 = MonoTime.currTime;
        auto scene = buildScene(f, seed);
        foreach (g; scene.children) nodes += g.children.length;
        auto hud = format("frame %d nodes %d jobs %d assets %d", f, nodes, atomicLoad(jobsDone), atomicLoad(assetsLoaded));
        // stream a few level tiles
        foreach (k; 0 .. 8)
        {
            seed = seedOf(seed);
            auto i = seed % level.length;
            auto t = new Tile;
            t.pixels = new ubyte[](4096);
            t.name = "tile-" ~ i.to!string;
            level[i] = t;
        }
        ft[f] = (MonoTime.currTime - t0).total!"usecs";
        long spent = ft[f];
        while (spent < 16_666)
        {
            Thread.sleep(dur!"usecs"(16_666 - spent < 500 ? 16_666 - spent : 500));
            spent = (MonoTime.currTime - t0).total!"usecs";
        }
    }

    atomicStore(stop, true);
    foreach (t; ts) t.join();

    auto sorted = ft.dup;
    qsort(sorted.ptr, sorted.length, long.sizeof, &cmpLong);
    long over(long us) { long n = 0; foreach (v; ft) if (v > us) n++; return n; }
    printf("game_mt: %d s, level %lu MiB, jobs %lu, assets %lu\n", seconds, cast(ulong) levelMiB,
           cast(ulong) atomicLoad(jobsDone), cast(ulong) atomicLoad(assetsLoaded));
    printf("frame_p50_us=%lld p99=%lld p999=%lld max=%lld over1ms=%lld over2ms=%lld over5ms=%lld over16ms=%lld frames=%lld\n",
           sorted[total / 2], sorted[total * 99 / 100], sorted[total * 999 / 1000], sorted[$ - 1],
           over(1000), over(2000), over(5000), over(16000), cast(long) total);
}
