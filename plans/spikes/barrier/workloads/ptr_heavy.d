/**
 * Pointer-store microbenchmark for the barrier-cost spike: no allocation in
 * the timed loops, so the GC does not dominate and the store barrier is as
 * exposed as it gets. This is the worst case for M4, not a typical program.
 *
 * Usage: ptr_heavy [nodes] [rounds]
 */
import std.conv;
import std.stdio;

final class Node
{
    Node next, other;
    size_t v;
}

void main(string[] args)
{
    immutable n = args.length > 1 ? to!size_t(args[1]) : 1_000_000;
    immutable rounds = args.length > 2 ? to!size_t(args[2]) : 30;

    auto nodes = new Node[](n);
    foreach (i, ref p; nodes)
    {
        p = new Node;
        p.v = i;
    }

    size_t rng = 88172645463325252UL;
    size_t next() { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

    size_t sink;
    foreach (r; 0 .. rounds)
    {
        // 1. Shuffle the pointer array (array-element pointer stores).
        foreach_reverse (i; 1 .. n)
        {
            immutable j = next() % (i + 1);
            auto t = nodes[i];
            nodes[i] = nodes[j];
            nodes[j] = t;
        }
        // 2. Relink into a list in array order (field stores).
        foreach (i; 0 .. n - 1)
            nodes[i].next = nodes[i + 1];
        nodes[n - 1].next = null;
        // 3. Reverse the list in place (three pointer stores per node).
        Node prev = null, cur = nodes[0];
        while (cur !is null)
        {
            auto nx = cur.next;
            cur.next = prev;
            prev = cur;
            cur = nx;
        }
        // 4. Cross links (second pointer field).
        foreach (i; 0 .. n)
            nodes[i].other = nodes[(i * 7 + r) % n];
        sink += prev.v;
    }
    writeln(sink);
}
