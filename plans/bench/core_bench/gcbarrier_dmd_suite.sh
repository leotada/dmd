#!/bin/bash
# Runs DMD's own runnable and compilable tests with -preview=gcbarrier.
#
#   gcbarrier_dmd_suite.sh [extra run.d arguments]
#
# What it checks: that the barrier's code generation and the compiler still agree on everything the
# test suite compiles (inline expansion, clustering, ranges), and that no test changes behaviour. What it
# does not check: that the barrier marks the right cards. There is no collector here, so the card
# window is empty and every barrier is a no-op; mark_race_glue and cards_precision check the marking.
#
# The compiler's references to the card globals (and _d_gcBarrierRange) are satisfied by a stub object
# linked with -L. Pass it as an object, not as a C source argument: a source argument changes how DMD
# emits templates and breaks the link*.d tests for a reason that has nothing to do with the barrier.
set -u
REPO=${REPO:-/home/leonardo/Projetos/dmd}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/stub.c" <<'EOF'
#include <stddef.h>
size_t __sd_gc_card_lo;
size_t __sd_gc_card_n;
unsigned char *__sd_gc_card_base;
unsigned char *__sd_gc_card_summary_base;
void _d_gcBarrierRange(const void *addr, size_t n) { (void)addr; (void)n; }
EOF
gcc -fPIC -c "$WORK/stub.c" -o "$WORK/stub.o" || exit 2

cd "$REPO/compiler/test" && ./run.d runnable compilable "REQUIRED_ARGS=-preview=gcbarrier -L$WORK/stub.o" "$@"
