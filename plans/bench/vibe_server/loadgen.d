/**
 * Load generator for gcbench_vibe: keep-alive HTTP/1.1 clients on plain sockets.
 *
 * Usage: loadgen [port] [clients] [requests-per-client] [idle-connections] [items]
 *
 * Every client sends a mix of GET /item/n (80%), POST /item/n (10%) and GET /search
 * (10%), one request at a time, and records the round-trip latency. `idle-connections`
 * extra connections are opened and left idle for the whole run: each holds a fiber and
 * its stack in the server, which is the "many suspended fibers" root set.
 * Prints "p50= p99= p99.9= max=" (microseconds) to stderr, then asks the server to quit.
 */
import core.thread;
import core.time;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.socket;
import std.stdio;
import std.string : indexOf;

__gshared ushort port = 8089;
__gshared size_t perClient = 5000, items = 100_000;

string readResponse(Socket s, ref ubyte[] buf)
{
    // Headers end at \r\n\r\n; body length from Content-Length.
    size_t have;
    ptrdiff_t hdrEnd = -1;
    size_t bodyLen;
    while (true)
    {
        if (have == buf.length)
            buf.length = buf.length * 2;
        auto n = s.receive(buf[have .. $]);
        if (n <= 0)
            throw new Exception("connection closed");
        have += n;
        auto text = cast(string) buf[0 .. have];
        if (hdrEnd < 0)
        {
            auto p = text.indexOf("\r\n\r\n");
            if (p < 0)
                continue;
            hdrEnd = p + 4;
            auto cl = text[0 .. p].indexOf("Content-Length: ");
            if (cl < 0)
                cl = text[0 .. p].indexOf("content-length: ");
            if (cl >= 0)
            {
                auto rest = text[cl + 16 .. p];
                auto e = rest.indexOf("\r\n");
                bodyLen = to!size_t(e < 0 ? rest : rest[0 .. e]);
            }
        }
        if (have >= hdrEnd + bodyLen)
            return cast(string) buf[0 .. have].idup;
    }
}

long[] runClient(size_t id)
{
    auto s = new TcpSocket;
    s.connect(new InternetAddress("127.0.0.1", port));
    s.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);
    auto buf = new ubyte[](64 * 1024);
    auto lat = new long[](perClient);
    size_t seed = id * 7919 + 1;
    foreach (i; 0 .. perClient)
    {
        seed = seed * 6364136223846793005UL + 1442695040888963407UL;
        immutable roll = (seed >> 40) % 10;
        immutable n = (seed >> 20) % items;
        string req;
        if (roll < 8)
            req = "GET /item/" ~ to!string(n) ~ " HTTP/1.1\r\nHost: x\r\n\r\n";
        else if (roll < 9)
            req = "POST /item/" ~ to!string(n) ~ " HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n";
        else
            req = "GET /search HTTP/1.1\r\nHost: x\r\n\r\n";
        immutable t0 = MonoTime.currTime;
        s.send(req);
        readResponse(s, buf);
        lat[i] = (MonoTime.currTime - t0).total!"usecs";
    }
    s.close();
    return lat;
}

// A function parameter gives each thread its own copy of the client id.
Thread makeClient(size_t id, long[][] results)
{
    return new Thread({ results[id] = runClient(id); });
}

void main(string[] args)
{
    if (args.length > 1) port = to!ushort(args[1]);
    immutable clients = args.length > 2 ? to!size_t(args[2]) : 8;
    if (args.length > 3) perClient = to!size_t(args[3]);
    immutable idle = args.length > 4 ? to!size_t(args[4]) : 0;
    if (args.length > 5) items = to!size_t(args[5]);

    Socket[] idleSockets;
    foreach (i; 0 .. idle)
    {
        auto s = new TcpSocket;
        s.connect(new InternetAddress("127.0.0.1", port));
        s.send("GET /item/1 HTTP/1.1\r\nHost: x\r\n\r\n"); // one request, then keep the connection open
        auto b = new ubyte[](16 * 1024);
        readResponse(s, b);
        idleSockets ~= s;
    }

    long[][] results = new long[][](clients);
    Thread[] ts;
    immutable t0 = MonoTime.currTime;
    foreach (c; 0 .. clients)
    {
        auto t = makeClient(c, results);
        t.start();
        ts ~= t;
    }
    foreach (t; ts)
        t.join();
    immutable wall = (MonoTime.currTime - t0).total!"msecs";

    long[] all;
    foreach (i, r; results)
    {
        if (r.length != perClient)
            stderr.writefln("warning: client %s completed %s of %s requests", i, r.length, perClient);
        all ~= r;
    }
    all.sort();
    stderr.writefln("vibe: clients=%s idle=%s requests=%s wall=%s ms (%s req/s)",
        clients, idle, all.length, wall, all.length * 1000 / (wall ? wall : 1));
    stderr.writefln("  p50=%s us  p99=%s us  p99.9=%s us  max=%s us",
        all[all.length / 2], all[all.length * 99 / 100], all[all.length * 999 / 1000], all[$ - 1]);

    auto q = new TcpSocket;
    q.connect(new InternetAddress("127.0.0.1", port));
    q.send("GET /quit HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    auto b = new ubyte[](4096);
    q.receive(b);
    q.close();
}
