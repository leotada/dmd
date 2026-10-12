// For a program that is built with the card barrier (or links a runtime that
// is) but does not use our collector: the stock GC, or upstream symgc. The
// barrier refers to these symbols, and these definitions satisfy the linker.
//
// All zero is a complete answer: the window has no cards, so the range check
// of every barrier fails and nothing is marked. Nothing has to be mapped and
// nothing has to run before main, unlike the shim for the first ABI
// (card_shim_v1.d), which had to map a table in .preinit_array.
extern(C) __gshared size_t __sd_gc_card_lo;
extern(C) __gshared size_t __sd_gc_card_n;
extern(C) __gshared ubyte* __sd_gc_card_base;
extern(C) __gshared ubyte* __sd_gc_card_summary_base;
extern(C) void __sd_gc_card_range(void* dst, size_t size) {}
