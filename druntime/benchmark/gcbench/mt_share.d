/**
 * Producer/consumer over std.concurrency: every message crosses a thread
 * boundary, so this is the worst case for the escape rate (G0b).
 *
 * Messages are `immutable` strings (cheap to promote, ADR-3) and
 * `shared` class instances (promotion graph of one node).
 *
 * Usage: mt_share [messages] [producer-consumer-pairs]
 */
import core.thread;
import std.concurrency;
import std.conv;

__gshared size_t N = 200_000;
__gshared int PAIRS = 2;

final class Msg
{
    size_t id;
    string text;
    this(size_t id, string text) immutable { this.id = id; this.text = text; }
}

void consumer(Tid owner)
{
    size_t count;
    bool done;
    while (!done)
    {
        receive(
            (string s) { count += s.length; },
            (immutable(Msg) m) { count += m.text.length; },
            (bool) { done = true; });
    }
    send(owner, count);
}

void main(string[] args)
{
    if (args.length > 1)
        N = to!size_t(args[1]);
    if (args.length > 2)
        PAIRS = to!int(args[2]);

    auto tids = new Tid[PAIRS];
    foreach (ref t; tids)
        t = spawn(&consumer, thisTid);

    foreach (i; 0 .. N)
    {
        auto t = tids[i % PAIRS];
        string s = "message-" ~ to!string(i);
        if (i & 1)
            send(t, s.idup);
        else
            send(t, new immutable(Msg)(i, s.idup));
    }
    foreach (t; tids)
        send(t, true);
    foreach (_; tids)
        receiveOnly!size_t();
}
