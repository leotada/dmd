/**
 * Build trees and lists of mixed-size nodes, then traverse them many times.
 * The traversal's cache behaviour depends on how the allocator laid the
 * nodes out, which is the locality argument for Immix (ADR-2, gate G0c).
 *
 * Measure last-level cache misses externally:
 *   perf stat -e LLC-loads,LLC-load-misses ./traverse_locality
 *
 * Usage: traverse_locality [nodes] [traversals]
 */
import core.memory;
import std.conv;

__gshared size_t NODES = 1_000_000;
__gshared size_t TRAVERSALS = 20;

struct Padding(size_t N) { ubyte[N] bytes; }

// Three node sizes, interleaved while building, so a size-segregated
// allocator spreads one logical structure over three regions.
final class Small { Small left, right; size_t v; }
final class Medium { Medium left, right; size_t v; Padding!96 pad; }
final class Large { Large left, right; size_t v; Padding!400 pad; }

// Garbage must escape, or LDC's GC2Stack pass moves it to the stack and the
// benchmark stops allocating it.
void* gcSink;

Small buildSmall(size_t n, ref ulong rng)
{
    if (!n)
        return null;
    auto s = new Small;
    s.v = n;
    // Allocate unrelated objects of other sizes between nodes.
    gcSink = cast(void*) new Medium;
    if (n % 4 == 0)
        gcSink = cast(void*) new Large;
    s.left = buildSmall(n / 2, rng);
    s.right = buildSmall(n - n / 2 - 1, rng);
    return s;
}

size_t sum(Small s)
{
    return s is null ? 0 : s.v + sum(s.left) + sum(s.right);
}

// A linked list through nodes that were allocated in order.
final class ListNode { ListNode next; size_t v; ubyte[24] pad; }

size_t sumList(ListNode n)
{
    size_t t;
    for (; n; n = n.next)
        t += n.v;
    return t;
}

void main(string[] args)
{
    if (args.length > 1)
        NODES = to!size_t(args[1]);
    if (args.length > 2)
        TRAVERSALS = to!size_t(args[2]);

    ulong rng = 1;
    auto tree = buildSmall(NODES, rng);

    ListNode head;
    foreach (i; 0 .. NODES)
    {
        auto n = new ListNode;
        n.v = i;
        n.next = head;
        head = n;
        if (i % 3 == 0)
            gcSink = (new ubyte[](200 + i % 600)).ptr; // garbage in between
    }

    // Drop the garbage, keep the structures; leaves holes between nodes.
    GC.collect();

    size_t total;
    foreach (_; 0 .. TRAVERSALS)
        total += sum(tree) + sumList(head);
    if (total == 0)
        assert(0);
}
