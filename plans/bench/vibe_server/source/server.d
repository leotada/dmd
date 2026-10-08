/**
 * vibe.d HTTP server with a GC-heavy request handler, the shape of a typical
 * D web service: a long-lived in-memory store, per-request parsing and
 * rendering, and thousands of idle fibers (keep-alive connections).
 *
 * Usage: GCB_PORT=8089 GCB_LIVE_MIB=128 gcbench_vibe [--DRT-gcopt=...]
 * Stops after GET /quit.
 *
 * Routes:
 *   GET /item/<n>   render one stored record as JSON-like text (allocates)
 *   POST /item/<n>  replace record n (churns the live set)
 *   GET /search     scan 200 records into a fresh array, sort and render
 *   GET /quit
 */
import core.memory;
import std.algorithm.sorting : sort;
import std.array : appender;
import std.conv : to;
import std.format : formattedWrite;
import std.string : startsWith;
import vibe.core.core;
import vibe.core.log;
import vibe.http.router;
import vibe.http.server;

final class Record
{
    size_t id;
    string name;
    string[] tags;
    double[] samples;
    Record parent;
}

__gshared Record[] store;
__gshared size_t seed = 1;

Record makeRecord(size_t id)
{
    auto r = new Record;
    r.id = id;
    r.name = "record-" ~ to!string(id);
    foreach (k; 0 .. 4)
        r.tags ~= "tag" ~ to!string((id + k) % 97);
    r.samples = new double[](16);
    foreach (k, ref s; r.samples)
        s = cast(double) (id * 31 + k);
    if (id)
        r.parent = store[id - 1];
    return r;
}

string render(Record r)
{
    auto a = appender!string;
    formattedWrite(a, `{"id":%s,"name":"%s","tags":[`, r.id, r.name);
    foreach (i, t; r.tags)
        formattedWrite(a, i ? `,"%s"` : `"%s"`, t);
    a.put(`],"samples":[`);
    foreach (i, s; r.samples)
        formattedWrite(a, i ? `,%s` : `%s`, s);
    a.put("]}");
    return a.data;
}

void main()
{
    // vibe's runApplication rejects unknown command-line options, so configure by environment.
    import core.stdc.stdlib : getenv;
    import std.string : fromStringz;
    auto envPort = getenv("GCB_PORT");
    auto envLive = getenv("GCB_LIVE_MIB");
    ushort port = envPort ? to!ushort(fromStringz(envPort)) : 8089;
    size_t liveMiB = envLive ? to!size_t(fromStringz(envLive)) : 128;
    // About 700 bytes per record including its strings and arrays.
    immutable count = liveMiB * 1024 * 1024 / 700;
    store = new Record[](count);
    foreach (i; 0 .. count)
        store[i] = makeRecord(i);

    auto router = new URLRouter;
    router.get("/item/:n", (HTTPServerRequest req, HTTPServerResponse res) {
        auto n = to!size_t(req.params["n"]) % count;
        res.writeBody(render(store[n]), "application/json");
    });
    router.post("/item/:n", (HTTPServerRequest req, HTTPServerResponse res) {
        auto n = to!size_t(req.params["n"]) % count;
        store[n] = makeRecord(n);
        res.writeBody("ok");
    });
    router.get("/search", (HTTPServerRequest req, HTTPServerResponse res) {
        seed = seed * 6364136223846793005UL + 1442695040888963407UL;
        Record[] found;
        foreach (k; 0 .. 200)
            found ~= store[((seed >> 33) + k * 7919) % count];
        found.sort!((a, b) => a.name < b.name);
        auto a = appender!string;
        foreach (r; found)
            a.put(render(r));
        res.writeBody(a.data, "application/json");
    });
    router.get("/quit", (HTTPServerRequest req, HTTPServerResponse res) {
        res.writeBody("bye");
        // vibe leaves through a path that skips druntime's profile:1 summary, so print it here.
        import std.stdio : stderr;
        auto p = GC.profileStats();
        stderr.writefln("Number of collections:  %s", p.numCollections);
        stderr.writefln("Grand total GC time:  %s milliseconds", p.totalCollectionTime.total!"msecs");
        stderr.writefln("Max Pause Time:  %s milliseconds", p.maxPauseTime.total!"msecs");
        exitEventLoop();
    });

    auto settings = new HTTPServerSettings;
    settings.port = port;
    settings.bindAddresses = ["127.0.0.1"];
    settings.options = HTTPServerOption.none; // single worker thread, no reuse-port tricks
    listenHTTP(settings, router);
    runApplication();
}
