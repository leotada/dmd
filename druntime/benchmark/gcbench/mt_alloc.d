/**
 * N threads allocating short-lived small objects, with no sharing.
 *
 * This is the best case for thread-local collection domains: nothing ever
 * escapes a thread, so every allocation could be reclaimed locally.
 *
 * Usage: mt_alloc [allocations-per-thread] [threads]
 */
import core.thread;
import std.conv;

__gshared size_t N = 2_000_000;
__gshared int NT = 4;

void* gcSink; // thread-local, so the workers do not contend on it

class Node
{
    Node next;
    size_t payload;
}

void worker()
{
    // Keep a short window of live objects so that the collector has both
    // live and dead data on every block.
    enum window = 64;
    Node[window] ring;
    foreach (i; 0 .. N)
    {
        auto n = new Node;
        n.payload = i;
        // Link to another slot's node on odd iterations only. Linking each node to the
        // previous node of its own slot would chain every node ever allocated and keep
        // the whole history alive; this keeps chains short (geometric, mean about 2).
        n.next = (i & 1) ? ring[(i + 1) % window] : null;
        ring[i % window] = n;
        // Occasionally allocate a small array too, to mix size classes.
        if ((i & 15) == 0)
        {
            auto a = new ubyte[](16 + (i & 0x3F0));
            a[0] = cast(ubyte) i;
            gcSink = a.ptr; // escape, or LDC's GC2Stack moves the array to the stack
        }
    }
}

void main(string[] args)
{
    if (args.length > 1)
        N = to!size_t(args[1]);
    if (args.length > 2)
        NT = to!int(args[2]);

    auto threads = new Thread[NT];
    foreach (ref t; threads)
    {
        t = new Thread(&worker);
        t.start();
    }
    foreach (t; threads)
        t.join();
}
