/**
 * Long-running mixed-size allocation with a slowly changing live set, to
 * expose line/block fragmentation (ADR-2, gate G0c).
 *
 * The live set is a ring of slots. Each step frees a random slot and refills
 * it with an object whose size is drawn from a skewed distribution, so holes
 * of many sizes appear and must be reused. Resident set size is sampled from
 * /proc/self/statm over the whole run, not just at the peak.
 *
 * Usage: frag_longrun [steps] [slots] [sample-every]
 *
 * The roadmap asks for an hours-long run; the default finishes in seconds.
 * Pass e.g. `2000000000 1000000 10000000` for the real measurement.
 */
import core.memory;
import std.conv;
import std.file : readText;
import std.stdio;
import std.string : split;

__gshared size_t STEPS = 20_000_000;
__gshared size_t SLOTS = 200_000;
__gshared size_t EVERY = 2_000_000;

size_t rssKiB()
{
    version (linux)
        return readText("/proc/self/statm").split[1].to!size_t * 4;
    else
        return 0;
}

size_t pickSize(ref ulong rng)
{
    rng = rng * 6364136223846793005UL + 1442695040888963407UL;
    immutable r = rng >> 33;
    // ~60% small (16-256 B), ~30% medium (256 B-4 KiB), ~10% up to 64 KiB.
    switch (r % 10)
    {
        case 0: .. case 5: return 16 + (r >> 4) % 240;
        case 6: .. case 8: return 256 + (r >> 4) % 3840;
        default:           return 4096 + (r >> 4) % 61440;
    }
}

void main(string[] args)
{
    if (args.length > 1)
        STEPS = to!size_t(args[1]);
    if (args.length > 2)
        SLOTS = to!size_t(args[2]);
    if (args.length > 3)
        EVERY = to!size_t(args[3]);

    auto slots = new ubyte[][](SLOTS);
    ulong rng = 42;
    size_t liveBytes;

    foreach (step; 0 .. STEPS)
    {
        rng = rng * 6364136223846793005UL + 1442695040888963407UL;
        immutable i = (rng >> 33) % SLOTS;
        liveBytes -= slots[i].length;
        auto n = pickSize(rng);
        slots[i] = new ubyte[](n);
        slots[i][0] = 1;
        liveBytes += n;

        if (step % EVERY == 0)
            stderr.writefln("frag_longrun step=%s rss=%s KiB live=%s KiB",
                step, rssKiB, liveBytes / 1024);
    }
    GC.collect();
    stderr.writefln("frag_longrun end rss=%s KiB live=%s KiB", rssKiB, liveBytes / 1024);
}
