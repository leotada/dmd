/**
 * The std.parallelism result-array pattern (RFC section 2.4, channel 7): the
 * caller allocates the result array, worker threads store freshly allocated
 * objects into it. Every stored object is published to another thread.
 *
 * Usage: parallel_map [elements] [rounds]
 */
import std.conv;
import std.parallelism;
import std.range : iota;

__gshared size_t N = 100_000;
__gshared size_t ROUNDS = 20;

final class Item
{
    size_t id;
    ubyte[] data;
    this(size_t id) { this.id = id; data = new ubyte[](32 + id % 96); }
}

string toStr(size_t i) { return (i * 7).to!string; }

void main(string[] args)
{
    if (args.length > 1)
        N = to!size_t(args[1]);
    if (args.length > 2)
        ROUNDS = to!size_t(args[2]);

    size_t sink;
    foreach (r; 0 .. ROUNDS)
    {
        // Result array allocated by the caller, filled by workers.
        auto items = new Item[](N);
        foreach (i, ref slot; parallel(items))
            slot = new Item(i);

        // taskPool.map: results are collected in a heap array as well.
        auto strs = taskPool.amap!toStr(iota(N / 10));
        sink += items[N / 2].id + strs.length;
    }
    if (sink == 0)
        assert(0);
}
