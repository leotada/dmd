// Bullet Hell Game Benchmark with Option 1: Game Engine Controls & Frame Telemetry
//
// Demonstrates:
// 1. Real-time Audio Exemption: GC.excludeCurrentThread() prevents audio buffer underruns.
// 2. Cooperative Inter-frame Pacing: GC.step() donates idle frame time before V-Sync.
// 3. Frame Telemetry: GC.frameStats() updates HUD with zero reflection or symbol scraping.
//
import core.memory : GC;
import core.stdc.stdio : printf, fprintf, stderr;
import core.stdc.stdlib : qsort;
import core.thread : Thread;
import core.time;
import std.algorithm : filter, remove;
import std.array : array, appender;
import std.format : format;
import std.conv : to;

struct Vec { float x = 0, y = 0; }

class Bullet {
	Vec pos, vel;
	int owner;
	float life;
	void delegate(Bullet) onExpire;
	this(Vec p, Vec v, int o, float l, void delegate(Bullet) cb) {
		pos = p; vel = v; owner = o; life = l; onExpire = cb;
	}
}

class Particle {
	Vec pos, vel;
	float life;
	string tag;
	this(Vec p, Vec v, float l, string t) { pos = p; vel = v; life = l; tag = t; }
}

class Enemy {
	Vec pos;
	int id, hp = 50;
	float cooldown = 0;
	string name;
	this(int i, Vec p) { id = i; pos = p; name = "enemy-" ~ i.to!string; }
}

class Tile {
	Tile[] neighbours;
	ubyte[] pixels;
	string name;
}

__gshared Tile[] level;
__gshared uint rngState = 12345;
uint rnd() { rngState = rngState * 1664525 + 1013904223; return rngState >> 8; }
float frand() { return (rnd() & 0xFFFF) / 65536.0f; }

extern(C) int cmpLong(const void* a, const void* b) {
	auto x = *cast(const long*) a, y = *cast(const long*) b;
	return x < y ? -1 : (x > y);
}

// Audio thread simulation: 1000 Hz processing
__gshared bool audioRunning = true;
__gshared size_t audioTicks = 0;
__gshared size_t audioGlitchCount = 0;
__gshared Duration audioMaxTickDuration = Duration.zero;

void audioLoop()
{
	GC.excludeCurrentThread();
	assert(GC.isThreadExcluded(), "Audio thread must be marked excluded");

	MonoTime prev = MonoTime.currTime;
	while (audioRunning) {
		MonoTime now = MonoTime.currTime;
		Duration elapsed = now - prev;
		prev = now;

		if (elapsed > 5.msecs && audioTicks > 10) {
			// A tick took more than 5ms => audio buffer underrun/glitch!
			audioGlitchCount++;
		}
		if (elapsed > audioMaxTickDuration) {
			audioMaxTickDuration = elapsed;
		}

		audioTicks++;
		Thread.sleep(1.msecs);
	}

	GC.includeCurrentThread();
}

void main(string[] args)
{
	int seconds = args.length > 1 ? args[1].to!int : 10;
	size_t levelMiB = args.length > 2 ? args[2].to!size_t : 512;
	int perSecond = args.length > 3 ? args[3].to!int : 20000;
	bool enablePacing = args.length > 4 ? (args[4].to!int != 0) : true;

	// Populate the static level
	size_t tileBytes = 4096;
	size_t numTiles = (levelMiB * 1024 * 1024) / tileBytes;
	level = new Tile[](numTiles);
	foreach (i; 0 .. numTiles) {
		auto t = new Tile;
		t.pixels = new ubyte[](tileBytes);
		t.name = "tile-" ~ i.to!string;
		level[i] = t;
	}
	foreach (i; 0 .. numTiles) {
		level[i].neighbours = [level[(i + 1) % numTiles], level[(i + 3) % numTiles]];
	}

	// Spawn enemies
	Enemy[] enemies;
	foreach (i; 0 .. 64) {
		enemies ~= new Enemy(i, Vec(frand() * 640, frand() * 200 + 40));
	}

	Bullet[] bullets;
	Particle[] particles;

	// Start real-time audio thread
	auto audioThread = new Thread(&audioLoop);
	audioThread.isDaemon = true;
	audioThread.start();

	size_t total = seconds * 60;
	auto ft = new long[](total);
	auto gcAllocFt = new long[](total);
	auto gcCollectFt = new long[](total);
	auto gcPauseFt = new long[](total);

	size_t peakBullets = 0;
	int score = 0, hits = 0;
	string hud;

	GC.FrameStats lastFs = GC.frameStats();

	for (size_t f = 0; f < total; ++f) {
		auto t0 = MonoTime.currTime;
		auto fs0 = GC.frameStats();

		// Spawn bullets
		int toSpawn = perSecond / 60;
		foreach (k; 0 .. toSpawn) {
			auto e = enemies[rnd() % enemies.length];
			float angle = frand() * 6.283185f;
			float speed = 80 + frand() * 120;
			Vec vel = Vec(speed * 0.5f, speed * 0.866f);
			bullets ~= new Bullet(e.pos, vel, e.id, 1.5f + frand() * 1.5f, (b) { score += 10; });
		}
		if (bullets.length > peakBullets) peakBullets = bullets.length;

		// Move bullets
		foreach (b; bullets) {
			b.pos.x += b.vel.x / 60;
			b.pos.y += b.vel.y / 60;
			b.life -= 1.0f / 60;
			if (b.life <= 0 && b.onExpire !is null) {
				b.onExpire(b);
			}
		}
		bullets = bullets.filter!(b => b.life > 0).array;

		// Collision & particles
		foreach (b; bullets) {
			immutable dx = b.pos.x - 320, dy = b.pos.y - 500;
			if (dx * dx + dy * dy < 400) {
				hits++;
				b.life = 0;
				foreach (k; 0 .. 6)
					particles ~= new Particle(b.pos, Vec(frand() * 80 - 40, frand() * 80 - 40), 0.5f, "spark" ~ k.to!string);
			}
		}
		foreach (p; particles) {
			p.pos.x += p.vel.x / 60;
			p.pos.y += p.vel.y / 60;
			p.life -= 1.0f / 60;
		}
		particles = particles.filter!(p => p.life > 0).array;

		// Level streaming
		foreach (k; 0 .. 8) {
			auto i = rnd() % level.length;
			auto t = new Tile;
			t.pixels = new ubyte[](tileBytes);
			t.name = "tile-" ~ i.to!string;
			t.neighbours = [level[(i + 1) % level.length]];
			level[i] = t;
		}

		auto fs1 = GC.frameStats();
		gcAllocFt[f] = (fs1.threadAllocTime - fs0.threadAllocTime).total!"usecs";
		gcCollectFt[f] = (fs1.threadCollectTime - fs0.threadCollectTime).total!"usecs";
		gcPauseFt[f] = (fs1.threadPauseTime - fs0.threadPauseTime).total!"usecs";

		// HUD format using live frame telemetry
		hud = format("score %d hits %d bullets %d live %d MB alloc_us %d coll_us %d pauses %d",
			score, hits, cast(int) bullets.length, cast(int)(fs1.usedSize / (1024 * 1024)),
			cast(long) gcAllocFt[f], cast(long) gcCollectFt[f], cast(int) fs1.numCollections);

		// Frame timing & pacing
		ft[f] = (MonoTime.currTime - t0).total!"usecs";
		long spent = ft[f];

		// Cooperative inter-frame pacing: donate leftover budget before 16.6ms deadline
		if (enablePacing && spent < 15_000 && spent >= 0) {
			long budget = 15_000 - spent;
			if (budget > 1_000) {
				GC.step(dur!"usecs"(budget));
			}
		}

		spent = (MonoTime.currTime - t0).total!"usecs";
		while (spent < 16_666 && spent >= 0) {
			Thread.sleep(dur!"usecs"(16_666 - spent < 500 ? 16_666 - spent : 500));
			spent = (MonoTime.currTime - t0).total!"usecs";
		}
	}

	audioRunning = false;
	audioThread.join();

	auto sorted = ft.dup;
	qsort(sorted.ptr, sorted.length, long.sizeof, &cmpLong);
	long over(long us) { long n = 0; foreach (v; ft) if (v > us) n++; return n; }

	auto finalFs = GC.frameStats();

	printf("==========================================================================\n");
	printf("BULLET HELL GC TELEMETRY BENCHMARK RESULTS (%d s, level %lu MiB, %d bullets/s)\n",
		seconds, cast(ulong) levelMiB, perSecond);
	printf("==========================================================================\n");
	printf("Audio Thread Ticks: %zu | Audio Glitches/Underruns: %zu | Max Audio Tick: %lld us\n",
		audioTicks, audioGlitchCount, cast(long) audioMaxTickDuration.total!"usecs");
	printf("GC Collections: %zu | Live Heap: %lu MiB | Free Heap: %lu MiB | Active Cycle: %d\n",
		finalFs.numCollections, cast(ulong)(finalFs.usedSize / (1024 * 1024)),
		cast(ulong)(finalFs.freeSize / (1024 * 1024)), finalFs.isCycleActive ? 1 : 0);
	printf("Total Alloc Time: %lld us | Total Collect Time: %lld us | Total Pause Time: %lld us\n",
		cast(long) finalFs.totalAllocTime.total!"usecs",
		cast(long) finalFs.totalCollectTime.total!"usecs",
		cast(long) finalFs.totalPauseTime.total!"usecs");
	printf("Frame Distribution:\n");
	printf("  p50: %lld us | p99: %lld us | p99.9: %lld us | max: %lld us\n",
		sorted[total / 2], sorted[total * 99 / 100], sorted[total * 999 / 1000], sorted[$ - 1]);
	printf("  over 1ms: %lld | over 2ms: %lld | over 5ms: %lld | over 16ms: %lld\n",
		over(1000), over(2000), over(5000), over(16000));
	printf("Last HUD: %.*s\n", cast(int) hud.length, hud.ptr);
	printf("==========================================================================\n");
}
