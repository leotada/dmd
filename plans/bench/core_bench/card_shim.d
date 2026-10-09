// The LDC runtime in ldc-build-rt2 is built to work with the card barrier of our
// symgc and refers to its three symbols. A program that links the stock GC or
// the upstream symgc has no cards: these definitions satisfy the linker and do
// nothing (the compiler is not asked for the barrier, so nothing writes cards).
extern(C) __gshared ubyte* __sd_gc_card_base;
extern(C) __gshared ubyte* __sd_gc_card_summary_base;
extern(C) void __sd_gc_card_range(void* dst, size_t size) {}
