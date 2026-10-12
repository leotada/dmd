#!/bin/bash
# Checks WHERE dmd -preview=gcbarrier puts barrier calls, by counting the calls to
# _d_gcBarrier / _d_gcBarrierRange in the assembly of small functions. It is a
# regression test for completeness: the barrier is a pass over the backend's
# elements precisely so that stores the code generator makes by itself are
# covered, and this fails if one stops being.
#
#   DMD=<dmd> ./gcbarrier_codegen_check.sh
set -u
REPO=${REPO:-/home/leonardo/Projetos/dmd}
DMD=${DMD:-$REPO/generated/linux/release/64/dmd}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/t.d" <<'EOF'
class N { N next; N other; int x; }
struct P { void* a; void* b; long c; }
struct Q { int a; int b; }
struct Wrap { N n; }
__gshared N gslot;
__gshared N[4] gslots;

void twoFields(N a, N b) { a.next = b; a.other = b; }
void intField(N a) { a.x = 5; }
void global(N a) { gslot = a; }
void globalElem(N a) { gslots[1] = a; }
void globalElemIdx(N a, size_t i) { gslots[i] = a; }
// A pointer held in a global is not the global: the store goes to the heap.
__gshared void** gpp;
__gshared N[] garr;
void throughGlobalPointer(void* v) { *gpp = v; }
void throughGlobalSlice(N a, size_t i) { garr[i] = a; }
void localVar(N a) { N l = a; l = a; }
void structCopy(P* d, P* s) { *d = *s; }
void pointerFreeCopy(Q* d, Q* s) { *d = *s; }
void sliceCopy(N[] d, N[] s) { d[] = s[]; }
void intSliceCopy(int[] d, int[] s) { d[] = s[]; }
void sliceStore(N[]* d, N[] s) { *d = s; }
N valueUsed(N a, N b) { return a.next = b; }
void arrayLiteral(N a, N b) { auto x = [a, b]; }
void viaRef(ref N slot, N v) { slot = v; }
void delegateStore(void delegate()* d, void delegate() v) { *d = v; }
Wrap* newWithLiteral(N a) { return new Wrap(a); }
void closure(N a, void delegate()* d) { *d = () { cast(void) a.x; }; }
EOF

# EXTRA: more dmd flags, e.g. EXTRA=-fPIC (globals are reached differently with PIC,
# and the check has to hold for both)
$DMD -conf= -I"$REPO/druntime/import" -preview=gcbarrier -O -release -inline ${EXTRA:-} -c "$WORK/t.d" -of="$WORK/t.o" || exit 1

# calls of each kind in a function
count() {
	objdump -dr --no-show-raw-insn "$WORK/t.o" |
		awk -v fn="_D1t$(printf '%d' ${#1})$1" -v sym="$2" '
			/^[0-9a-f]+ <.*>:$/ { infn = index($0, fn "F") > 0 }
			infn && index($0, "R_X86_64_PLT32\t" sym "-") || infn && index($0, "R_X86_64_PC32\t" sym "-") { n++ }
			END { print n + 0 }'
}

fail=0
check() { # function  barrier  range
	local one range
	one=$(count "$1" _d_gcBarrier)
	range=$(count "$1" _d_gcBarrierRange)
	if [ "$one" -eq "$2" ] && [ "$range" -eq "$3" ]; then
		printf "ok    %-18s _d_gcBarrier x%d, _d_gcBarrierRange x%d\n" "$1" "$one" "$range"
	else
		printf "FAIL  %-18s got x%d and x%d, expected x%d and x%d\n" "$1" "$one" "$range" "$2" "$3"
		fail=1
	fi
}

check twoFields        2 0   # one call per store (no clustering yet)
check intField         0 0   # not a pointer
check global           0 0   # a global is a root
check globalElem       0 0
check localVar         0 0   # a local is a root
check structCopy       0 1   # a struct with pointers: the range
check pointerFreeCopy  0 0   # ... without pointers: nothing
check sliceCopy        0 1   # memcpy of pointers: the range
check intSliceCopy     0 0
check sliceStore       0 1   # a slice is two words
check valueUsed        1 0   # the value of the store is used: still one call
check arrayLiteral     2 0   # the elements are stored by the code generator, not by an assignment
check viaRef           1 0
check delegateStore    0 1
check newWithLiteral   1 0
check globalElemIdx    0 0   # a global array, indexed
check throughGlobalPointer 1 0   # PIC and not: the tree is the same shape as a global's address in PIC
check throughGlobalSlice   1 0
check closure          2 1   # the frame's fields (stored by the code generator) and the delegate

[ $fail -eq 0 ] && echo "ALL OK" || echo "FAILED"
exit $fail
