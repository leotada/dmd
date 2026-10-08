// Phobos-heavy stress under a given GC: fibers, std.parallelism, std.concurrency, AAs, strings, classes
// with destructors. Prints "STRESS OK <checksum>" when every internal check holds.
//   dmd ... phobos_stress.d <symgc sources> ; ./phobos_stress --DRT-gcopt=gc:sdcq
import core.thread : Fiber, Thread;
import core.memory : GC;
import std.algorithm : map, sort, sum, filter;
import std.array : array, appender;
import std.concurrency;
import std.conv : to;
import std.format : format;
import std.parallelism : parallel, taskPool, task;
import std.range : iota;
import std.stdio : writeln;
import std.string : split, join;

shared size_t destroyed;

class Node {
    Node next;
    ulong[] data;
    ulong id;
    this(ulong i, Node n) { id = i; next = n; data = new ulong[](8); data[0] = i; }
    ~this() { atomicOpAdd(); }
    static void atomicOpAdd() { import core.atomic : atomicOp; atomicOp!"+="(destroyed, 1); }
}

ulong chain(uint len, ulong seed) {
    Node head;
    foreach (i; 0 .. len) head = new Node(seed + i, head);
    ulong s;
    for (auto n = head; n; n = n.next) {
        assert(n.data[0] == n.id, "corrupted node");
        s += n.id;
    }
    return s;
}

ulong fiberWork(ulong seed) {
    ulong total;
    auto f = new Fiber({
        foreach (r; 0 .. 50) {
            auto keep = new Node(seed + r, null);
            Fiber.yield();
            assert(keep.data[0] == keep.id);
            total += keep.id;
        }
    });
    while (f.state != Fiber.State.TERM) {
        f.call();
        auto junk = new ubyte[](4096);   // allocate between resumes
        junk[0] = 1;
    }
    return total;
}

void worker(Tid parent, ulong seed) {
    ulong s;
    foreach (i; 0 .. 200) {
        string[string] aa;
        foreach (j; 0 .. 50) aa[format("k%d_%d", seed, j)] = format("v%d", i * j);
        s += aa.length;
        s += chain(100, seed);
    }
    send(parent, s);
}

int main() {
    ulong checksum;
    enum Rounds = 6;
    foreach (round; 0 .. Rounds) {
        // std.parallelism: results stored into a shared array
        auto results = new ulong[](64);
        foreach (i; parallel(iota(64))) results[i] = chain(2000, i * 1000);
        foreach (r; results) checksum += r;

        // std.concurrency: threads that allocate and send results back
        Tid[] tids;
        foreach (i; 0 .. 4) tids ~= spawn(&worker, thisTid, cast(ulong)(round * 10 + i));
        foreach (i; 0 .. 4) checksum += receiveOnly!ulong();

        // fibers
        foreach (i; 0 .. 20) checksum += fiberWork(i);

        // strings, sorting, appenders
        auto words = iota(20000).map!(i => format("w%05d", (i * 7919) % 20000)).array;
        words.sort();
        auto joined = words.join(",");
        assert(joined.split(",").length == words.length);
        checksum += joined.length;

        // a big live structure plus garbage
        auto live = new ulong[][](2000);
        foreach (i, ref l; live) l = new ulong[](1000 + i);
        foreach (i, l; live) assert(l.length == 1000 + i);
        GC.collect();
        foreach (i; 0 .. 30000) { auto t = new ulong[](100); t[0] = i; }
    }
    GC.collect();
    writeln("STRESS OK ", checksum, " destroyed=", destroyed);
    return 0;
}
