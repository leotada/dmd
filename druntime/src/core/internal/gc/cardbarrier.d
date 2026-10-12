/**
 * The runtime side of the GC write barrier (`-preview=gcbarrier`).
 *
 * A concurrent collector marks while the program runs. The program can store a
 * pointer to an object the collector has not reached into an object it has
 * already scanned, and then drop the other path to it. Unless the collector
 * learns of the store, it frees an object that is in use. After each store of a
 * pointer to memory that is not a local variable, the compiler calls
 * `_d_gcBarrier` (or `_d_gcBarrierRange` after a copy), and the collector
 * rescans what they report.
 *
 * The collector's memory is one contiguous range, the window,
 * [`__sd_gc_card_lo`, `__sd_gc_card_lo` + `__sd_gc_card_n` * 512). Each 512
 * bytes of it has one byte in the table `__sd_gc_card_base`. The barrier is
 * range checked, so an address outside the window (malloc memory, a pointer
 * with a tag in its top byte) marks nothing. The three variables are zero until
 * a collector that wants the barrier sets them up, which makes every call a
 * no-op: with the default conservative GC, `_d_gcBarrier` does a compare and
 * returns.
 *
 * It is the barrier of LDC's `-gc-card-marking` too, with the same table: a
 * program built by DMD and one built by LDC can share a collector.
 *
 * Copyright: D Language Foundation 2026.
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 */
module core.internal.gc.cardbarrier;

import core.atomic : atomicStore, MemoryOrder;

nothrow @nogc:

/// One byte of the table per 512 bytes of the window.
enum CardShift = 9;

/// What the collector sets up when it starts. Zero until then.
extern (C) __gshared
{
    size_t __sd_gc_card_lo;             /// start of the window
    size_t __sd_gc_card_n;              /// number of cards in it
    ubyte* __sd_gc_card_base;           /// one byte per card
    ubyte* __sd_gc_card_summary_base;   /// one byte per 64 KiB, if the collector wants it
}

/**
 * Called after a store of a pointer to `addr`.
 *
 * The card is written with release ordering: on a CPU that reorders stores
 * (ARM), the collector must not find the card set before the pointer is
 * visible, or it could scan the memory, clear the card, and miss the pointer.
 * On x86 a release store is a plain `mov`.
 */
extern (C) void _d_gcBarrier(const(void)* addr) @trusted
{
    const idx = (cast(size_t) addr - __sd_gc_card_lo) >> CardShift;
    if (idx < __sd_gc_card_n)
        atomicStore!(MemoryOrder.rel)(*cast(shared(ubyte)*) (__sd_gc_card_base + idx), ubyte(1));
}

/**
 * Called after a copy of `n` bytes to `addr`, and after a store of a value
 * larger than a pointer (a slice, a delegate, a struct).
 *
 * A range that starts outside the window marks nothing: objects do not
 * straddle the window's edges. One that starts inside and runs past the end is
 * cut there.
 */
extern (C) void _d_gcBarrierRange(const(void)* addr, size_t n) @trusted
{
    const limit = __sd_gc_card_n << CardShift;
    const rel = cast(size_t) addr - __sd_gc_card_lo;
    if (n == 0 || rel >= limit)
        return;

    size_t lastByte = rel + n - 1;
    if (lastByte >= limit || lastByte < rel)
        lastByte = limit - 1;

    auto cards = __sd_gc_card_base;
    foreach (c; (rel >> CardShift) .. (lastByte >> CardShift) + 1)
        atomicStore!(MemoryOrder.raw)(*cast(shared(ubyte)*) (cards + c), ubyte(1));

    // Release once, after the stores: they all follow the data they describe.
    atomicStore!(MemoryOrder.rel)(*cast(shared(ubyte)*) (cards + (lastByte >> CardShift)), ubyte(1));
}
