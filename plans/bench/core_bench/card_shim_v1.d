// The LDC runtime in ldc-build-rt2 is built to work with the card barrier of our
// symgc and refers to its three symbols. A program that links the stock GC or
// the upstream symgc has no cards: these definitions satisfy the linker and
// map the address range via .preinit_array so any barrier stores in druntime
// during static initialization do not segfault.
import core.sys.posix.sys.mman;

extern(C) __gshared ubyte* __sd_gc_card_base;
extern(C) __gshared ubyte* __sd_gc_card_summary_base;
extern(C) void __sd_gc_card_range(void* dst, size_t size) {}

extern(C) void __sd_gc_card_shim_init() {
	enum NoReserve = 0x4000;
	enum TableSize = size_t(1) << (47 - 9);
	enum SummarySize = size_t(1) << (47 - 16);
	if (__sd_gc_card_summary_base is null)
		__sd_gc_card_summary_base = cast(ubyte*) mmap(null, SummarySize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | NoReserve, -1, 0);
	if (__sd_gc_card_base is null)
		__sd_gc_card_base = cast(ubyte*) mmap(null, TableSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | NoReserve, -1, 0);
}

import ldc.attributes : section;
@section(".preinit_array") __gshared extern(C) void function() __sd_gc_card_shim_preinit = &__sd_gc_card_shim_init;

