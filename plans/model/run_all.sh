#!/bin/sh
# Reproduces the Phase 0 / 0.5 results: clean runs must pass and every planted
# bug must be detected. Usage: ./run_all.sh [path-to-dmd]
set -u
DMD=${1:-dmd}
cd "$(dirname "$0")" || exit 1
$DMD -O -release -inline -of=gc_model gc_model.d || exit 1

status=0

clean() { # name args...
    name=$1; shift
    if ./gc_model "$@" > "out_$name.log" 2>&1 && grep -q '^OK' "out_$name.log"; then
        echo "PASS  clean  $name: $(grep '^OK' "out_$name.log")"
    else
        echo "FAIL  clean  $name"; status=1
    fi
}

bug() { # bug-name args...
    b=$1; shift
    if ./gc_model --bug="$b" "$@" > "out_bug_$b.log" 2>&1; then
        echo "FAIL  bug $b was NOT detected"; status=1
    else
        echo "PASS  bug $b detected: $(grep -m1 VIOLATION "out_bug_$b.log")"
    fi
}

# Track A: SATB only.
clean A_2t_3o_1s --track=A --threads=2 --objects=3 --stack=1
for b in nodelete nohybrid noescapescan nostw1scan sweepnoprotect; do
    bug $b --track=A --threads=2 --objects=3 --stack=1
done

# Track B: local domains. One stack slot cannot store a pointer into a held
# object, so the local-domain bugs need two slots (and one thread suffices).
clean B_2t_3o_1s --track=B --threads=2 --objects=3 --stack=1
clean B_1t_3o_2s --track=B --threads=1 --objects=3 --stack=2
for b in nodelete nohybrid noescapescan nostw1scan sweepnoprotect nopublish noglobalize nopromotegrey noskip; do
    bug $b --track=B --threads=2 --objects=3 --stack=1
done
bug nolocaltrace --track=B --threads=1 --objects=3 --stack=2

# Fibers (Phase 4.7): lazy scanning of suspended fibers; switch-in scanning is necessary.
clean A_fibers_1t_3o_1s --track=A --threads=1 --objects=3 --stack=1 --fibers=1
bug nofiberscan --track=A --threads=1 --objects=3 --stack=1 --fibers=1

# Slab layer and explicit free (P2 lazy sweep design): objects grouped in slabs with bin membership,
# a per-slab sweep, allocation only from swept slabs, and mutator free(). Object renaming is off, so
# these runs use few objects. Explicit free during marking must apply the deletion barrier to the
# freed object's fields (nofreebarrier is found even without slabs).
clean A_free_2t_3o --track=A --threads=2 --objects=3 --stack=2 --free
bug nofreebarrier --track=A --threads=1 --objects=3 --stack=2 --free
clean A_rootrm_2t_3o_1s --track=A --threads=2 --objects=3 --stack=1 --rootrm
bug noremoveroot --track=A --threads=2 --objects=3 --stack=1 --rootrm
clean A_slabs_free_1t_3o --track=A --threads=1 --objects=3 --stack=2 --slabs=2 --free
for b in allocunswept freeunswept missedinsert nofreebarrier; do
    bug $b --track=A --threads=1 --objects=3 --stack=2 --slabs=2 --free
done

# Threads that exit and start during a cycle (--threadlife). A started thread must be registered as not yet
# scanned (or its argument shaded), and an exiting thread must flush its SATB buffer.
clean A_threadlife_2t_3o_1s --track=A --threads=2 --objects=3 --stack=1 --threadlife
for b in startnoscan exitnoflush; do
    bug $b --track=A --threads=2 --objects=3 --stack=1 --threadlife
done
# Many short walks find these shallow interleavings; long walks dilute them.
swarm_clean_short() { # name args...
    name=$1; shift
    if ./gc_model "$@" > "out_$name.log" 2>&1 && grep -q '^OK' "out_$name.log"; then
        echo "PASS  random $name: $(grep '^OK' "out_$name.log" | cut -c1-110)"
    else
        echo "FAIL  random $name"; status=1
    fi
}
swarm_clean_short A_threadlife_3t_4o --track=A --threads=3 --objects=4 --stack=2 --fields=2 --threadlife --free --rootrm --swarm=100000 --len=80

# Racing writers (two-step stores). The barrier as written in RFC 4.4 (test the marking flag,
# then store) is NOT safe if a cycle can start between the two: this must produce a violation.
# Exchange-then-test is safe. The second case enumerates about 50M states (about 7 minutes).
expect_violation() { # name args...
    name=$1; shift
    if ./gc_model "$@" > "out_$name.log" 2>&1; then
        echo "FAIL  expected a violation: $name"; status=1
    else
        echo "PASS  violation found as expected, $name: $(grep -m1 VIOLATION "out_$name.log")"
    fi
}
expect_violation race_plain --track=A --threads=2 --objects=3 --stack=1 --race
[ "${LONG:-0}" = 1 ] && clean A_race_xchg_2t_3o_1s --track=A --threads=2 --objects=3 --stack=1 --race --fix=xchg

# Randomized walks at 3 threads / 5 objects (not exhaustive). Clean runs must pass; the planted
# bugs must be found. noescapescan needs a 10-step interleaving and is only found exhaustively.
swarm_clean() { # name args...
    name=$1; shift
    if ./gc_model "$@" > "out_$name.log" 2>&1 && grep -q '^OK' "out_$name.log"; then
        echo "PASS  random $name: $(grep '^OK' "out_$name.log" | cut -c1-110)"
    else
        echo "FAIL  random $name"; status=1
    fi
}
SW="--threads=3 --objects=5 --stack=2 --fields=2 --swarm=1500 --len=3000"
swarm_clean A_3t_5o --track=A $SW
swarm_clean B_3t_5o --track=B $SW
swarm_clean B_3t_5o_fibers_race_xchg --track=B $SW --fibers=1 --race --fix=xchg
for b in nodelete nohybrid nopublish noglobalize nolocaltrace nopromotegrey noskip sweepnoprotect nostw1scan; do
    bug $b --track=B $SW
done

exit $status
