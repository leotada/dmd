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
struct Big { void*[100] p; }
void bigStructCopy(Big* d, Big* s) { *d = *s; }
void pointerFreeCopy(Q* d, Q* s) { *d = *s; }
void sliceCopy(N[] d, N[] s) { d[] = s[]; }
void intSliceCopy(int[] d, int[] s) { d[] = s[]; }
void sliceStore(N[]* d, N[] s) { *d = s; }
N valueUsed(N a, N b) { return a.next = b; }
void arrayLiteral(N a, N b) { auto x = [a, b]; }
class Wide { N a; ubyte[600] pad; N b; N c; }
class Tri { N a; N b; N c; N d; }
void threeFields(Tri t, N v) { t.a = v; t.b = v; t.c = v; }
void fourFields(Tri t, N v) { t.a = v; t.b = v; t.c = v; t.d = v; }
void twoSame(N a, N v) { a.next = v; a.next = v; }
void farFields(Wide w, N v) { w.a = v; w.b = v; }
void mixedBases(N a, N b, N v) { a.next = v; b.next = v; a.other = v; }
void afterCall(N a, N v) { a.next = v; afterCall(a, v); a.other = v; }
void sideEffectValue(N a, N v, N function() f) { a.next = v; a.other = f(); }
void threeAdjacent(N a, N v) { a.next = v; a.other = v; a.next = v; }
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
			# a card is marked by `movb $0x1,(...)`; the others are references to a symbol
			infn && sym == "CARDSTORE" && /movb +\$0x1,\(/ { n++ }
			infn && sym != "CARDSTORE" && /R_X86_64_/ && index($0, "\t" sym "-") { n++ }
			END { print n + 0 }'
}

fail=0
check() { # function  barrier  range
	local one range
	# barriers for stores of pointers are expanded in place: count the byte stores that mark
	# a card (three or more stores to one object that follow each other share two)
	one=$(count "$1" CARDSTORE)
	range=$(count "$1" _d_gcBarrierRange)
	if [ "$one" -eq "$2" ] && [ "$range" -eq "$3" ]; then
		printf "ok    %-18s single x%d, range x%d\n" "$1" "$one" "$range"
	else
		printf "FAIL  %-18s got x%d and x%d, expected x%d and x%d\n" "$1" "$one" "$range" "$2" "$3"
		fail=1
	fi
}

check twoFields        2 0   # two stores to different fields: two barriers (a shared one would cost as much)
check threeFields      2 0   # three: one barrier for the pair of cards (3 sequences before)
check fourFields       2 0
check twoSame          1 0   # the same field twice: one
check farFields        2 0   # Wide.a and .b are 600+ bytes apart: two
check threeAdjacent    2 0
check mixedBases       3 0   # the bases alternate: no run of the same one
check afterCall        2 0   # a call between the stores: they stay apart
check sideEffectValue  2 0   # a store whose value is a call is not part of a cluster
check intField         0 0   # not a pointer
check global           0 0   # a global is a root
check globalElem       0 0
check localVar         0 0   # a local is a root
check structCopy       2 0   # a small struct with pointers: two card tests in place (its span may cross a card)
check bigStructCopy    0 1   # over 512 bytes: the range call
check pointerFreeCopy  0 0   # ... without pointers: nothing
check sliceCopy        0 1   # memcpy of pointers, size unknown: the range
check intSliceCopy     0 0
check sliceStore       2 0   # a slice is two words: in place
check valueUsed        1 0   # the value of the store is used: still one call
check arrayLiteral     2 0   # the elements are stored by the code generator, not by an assignment
check viaRef           1 0
check delegateStore    2 0
check newWithLiteral   1 0
check globalElemIdx    0 0   # a global array, indexed
check throughGlobalPointer 1 0   # PIC and not: the tree is the same shape as a global's address in PIC
check throughGlobalSlice   1 0
check closure          3 0   # the frame field holding a (stored by the code generator; a null field needs none) and the delegate (two tests)

[ $fail -eq 0 ] && echo "ALL OK" || echo "FAILED"
exit $fail
