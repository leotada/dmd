/**
 * Barrier-cost spike (RFC Phase 0.3): insert the section 4.4 store barrier into
 * LLVM IR emitted by LDC.
 *
 * This is a stand-in for a real LDC change. LDC is not buildable here (no LLVM
 * development files), so the IR text is rewritten instead:
 *
 *     ldc2 -O3 -release -c -output-ll x.d          # optimized IR
 *     rdmd rewrite_ir.d --mode=publish+vis x.ll xb.ll
 *     clang -O2 -c xb.ll                           # same LLVM 19 as LDC
 *
 * Every non-atomic, non-volatile `store ptr` is replaced by a call to an
 * always-inline function containing the fast path; clang inlines it.
 *
 * Modes (cumulative):
 *   none          no rewriting, only a copy (control)
 *   satb          while-marking test only
 *   satb+vis      + stack-visibility range compare on the stored value
 *   publish       satb + publication test (owner lookups through the block table)
 *   publish+vis   everything
 *   split[+vis]   publication test slot-first: a store into my own block needs no
 *                 look at the value (one table lookup instead of two)
 *   arena[+vis]   publication test with a per-thread contiguous address arena:
 *                 ownership is a range compare, no table (a design option)
 *
 * Options:
 *   --elide-fresh  skip stores into memory returned by an allocation call in the
 *                  same function (the RFC's "initializing store" elision; an
 *                  optimistic bound, since it ignores that the object may have
 *                  escaped before the store).
 *
 *   --invariant    mark the loads of per-thread stack/arena bounds and the heap
 *                  table as `!invariant.load`, so LLVM can hoist them across stores.
 *                  Valid for fields that do not change after thread start.
 *
 * Limitations (so numbers are not over-read):
 *   - Stores through memcpy/memmove (struct and array copies) are not barriered;
 *     the RFC uses the bulk barrier for those.
 *   - The IR is post-optimization, so LLVM did not get to optimize around the
 *     barrier. That is mildly pessimistic. Stores LLVM already promoted to
 *     registers are gone, as they would be in the real implementation.
 *   - Stores to allocas are never barriered; stores whose address LLVM could not
 *     prove local are.
 *   - Only code compiled in the module is rewritten. Precompiled Phobos and
 *     druntime code is not (templates instantiated into the module are).
 */
module rewrite_ir;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.getopt;
import std.regex;
import std.stdio;
import std.string;

string mode = "publish+vis";
bool elideFresh;
bool invariantLoads;

struct Stats
{
    size_t seen, rewritten, elidedAlloca, elidedFresh, skippedAtomic;
}

/// Split the first top-level operand off `s` (stops at a comma outside brackets).
string takeOperand(string s, out string rest)
{
    int depth;
    foreach (i, c; s)
    {
        if (c == '(' || c == '[' || c == '{' || c == '<') ++depth;
        else if (c == ')' || c == ']' || c == '}' || c == '>') --depth;
        else if (c == ',' && depth == 0)
        {
            rest = s[i .. $];
            return s[0 .. i].strip;
        }
    }
    rest = "";
    return s.strip;
}

string barrierIr()
{
    immutable vis = mode.endsWith("+vis");
    immutable kind = mode.startsWith("publish") ? "publish"
        : mode.startsWith("split") ? "split"
        : mode.startsWith("arena") ? "arena" : "";
    immutable pub = kind.length != 0;

    string ir = `
%GcSpikeTS = type { i8, i8, i8, i8, i16, i16, i64, i64, i64, i64 }
%GcSpikeHeap = type { i64, i64, ptr }
@gcts = external thread_local(initialexec) global %GcSpikeTS
@gcheap = external global %GcSpikeHeap
declare void @_d_gc_store_slow(ptr, ptr)
declare void @_d_gc_publish_slow(ptr, ptr)
declare void @_d_gc_stack_escaped()
declare i1 @llvm.expect.i1(i1, i1)

define internal void @__gcspike_store(ptr noundef %slot, ptr noundef %v) alwaysinline nounwind {
entry:
  %mp = getelementptr inbounds %GcSpikeTS, ptr @gcts, i32 0, i32 0
  %m = load i8, ptr %mp, align 64
  %marking = icmp ne i8 %m, 0
  %e0 = call i1 @llvm.expect.i1(i1 %marking, i1 false)
  br i1 %e0, label %satb, label %vis
satb:
  call void @_d_gc_store_slow(ptr %slot, ptr %v)
  br label %vis
`;
    string next = pub ? "pub" : "done";
    if (vis)
        ir ~= `
vis:
  %slp = getelementptr inbounds %GcSpikeTS, ptr @gcts, i32 0, i32 6
  %lo = load i64, ptr %slp, align 8
  %szp = getelementptr inbounds %GcSpikeTS, ptr @gcts, i32 0, i32 7
  %sz = load i64, ptr %szp, align 8
  %vi = ptrtoint ptr %v to i64
  %vd = sub i64 %vi, %lo
  %vin = icmp ult i64 %vd, %sz
  %e1 = call i1 @llvm.expect.i1(i1 %vin, i1 false)
  br i1 %e1, label %vis2, label %` ~ next ~ `
vis2:
  %si = ptrtoint ptr %slot to i64
  %sd = sub i64 %si, %lo
  %sin = icmp ult i64 %sd, %sz
  br i1 %sin, label %` ~ next ~ `, label %visslow
visslow:
  call void @_d_gc_stack_escaped()
  br label %` ~ next ~ `
`;
    else
        ir ~= "vis:\n  br label %" ~ next ~ "\n";

    if (kind == "split")
        ir ~= `
pub:
  %lop = getelementptr inbounds %GcSpikeTS, ptr @gcts, i32 0, i32 2
  %lon = load i8, ptr %lop, align 2
  %on = icmp ne i8 %lon, 0
  br i1 %on, label %own, label %done
own:
  %mep = getelementptr inbounds %GcSpikeTS, ptr @gcts, i32 0, i32 4
  %me = load i16, ptr %mep, align 4
  %hb = load i64, ptr @gcheap, align 8
  %hsp = getelementptr inbounds %GcSpikeHeap, ptr @gcheap, i32 0, i32 1
  %hs = load i64, ptr %hsp, align 8
  %tp = getelementptr inbounds %GcSpikeHeap, ptr @gcheap, i32 0, i32 2
  %tab = load ptr, ptr %tp, align 8
  %si2 = ptrtoint ptr %slot to i64
  %soff = sub i64 %si2, %hb
  %sinh = icmp ult i64 %soff, %hs
  br i1 %sinh, label %slook, label %snone
slook:
  %sidx = lshr i64 %soff, 15
  %sep = getelementptr inbounds i16, ptr %tab, i64 %sidx
  %osl = load i16, ptr %sep, align 2
  br label %sjoin
snone:
  br label %sjoin
sjoin:
  %os = phi i16 [ %osl, %slook ], [ 0, %snone ]
  %sm = icmp eq i16 %os, %me
  br i1 %sm, label %done, label %vchk
vchk:
  %vi2 = ptrtoint ptr %v to i64
  %voff = sub i64 %vi2, %hb
  %vinh = icmp ult i64 %voff, %hs
  br i1 %vinh, label %vlook, label %vnone
vlook:
  %vidx = lshr i64 %voff, 15
  %vep = getelementptr inbounds i16, ptr %tab, i64 %vidx
  %ovl = load i16, ptr %vep, align 2
  br label %vjoin
vnone:
  br label %vjoin
vjoin:
  %ov = phi i16 [ %ovl, %vlook ], [ 0, %vnone ]
  %ov1 = or i16 %ov, 1
  %me1 = or i16 %me, 1
  %mine = icmp eq i16 %ov1, %me1
  br i1 %mine, label %pubslow, label %done
pubslow:
  call void @_d_gc_publish_slow(ptr %slot, ptr %v)
  br label %done
`;
    else if (kind == "arena")
        ir ~= `
pub:
  %lop = getelementptr inbounds %GcSpikeTS, ptr @gcts, i32 0, i32 2
  %lon = load i8, ptr %lop, align 2
  %on = icmp ne i8 %lon, 0
  br i1 %on, label %own, label %done
own:
  %alp = getelementptr inbounds %GcSpikeTS, ptr @gcts, i32 0, i32 8
  %alo = load i64, ptr %alp, align 8
  %asp = getelementptr inbounds %GcSpikeTS, ptr @gcts, i32 0, i32 9
  %asz = load i64, ptr %asp, align 8
  %si2 = ptrtoint ptr %slot to i64
  %sd2 = sub i64 %si2, %alo
  %sina = icmp ult i64 %sd2, %asz
  br i1 %sina, label %done, label %vchk
vchk:
  %vi2 = ptrtoint ptr %v to i64
  %vd2 = sub i64 %vi2, %alo
  %vina = icmp ult i64 %vd2, %asz
  br i1 %vina, label %pubslow, label %done
pubslow:
  call void @_d_gc_publish_slow(ptr %slot, ptr %v)
  br label %done
`;
    else if (kind == "publish")
        ir ~= `
pub:
  %lop = getelementptr inbounds %GcSpikeTS, ptr @gcts, i32 0, i32 2
  %lon = load i8, ptr %lop, align 2
  %on = icmp ne i8 %lon, 0
  br i1 %on, label %own, label %done
own:
  %mep = getelementptr inbounds %GcSpikeTS, ptr @gcts, i32 0, i32 4
  %me = load i16, ptr %mep, align 4
  %hb = load i64, ptr @gcheap, align 8
  %hsp = getelementptr inbounds %GcSpikeHeap, ptr @gcheap, i32 0, i32 1
  %hs = load i64, ptr %hsp, align 8
  %tp = getelementptr inbounds %GcSpikeHeap, ptr @gcheap, i32 0, i32 2
  %tab = load ptr, ptr %tp, align 8
  %vi2 = ptrtoint ptr %v to i64
  %voff = sub i64 %vi2, %hb
  %vinh = icmp ult i64 %voff, %hs
  br i1 %vinh, label %vlook, label %vnone
vlook:
  %vidx = lshr i64 %voff, 15
  %vep = getelementptr inbounds i16, ptr %tab, i64 %vidx
  %ovl = load i16, ptr %vep, align 2
  br label %vjoin
vnone:
  br label %vjoin
vjoin:
  %ov = phi i16 [ %ovl, %vlook ], [ 0, %vnone ]
  %ov1 = or i16 %ov, 1
  %me1 = or i16 %me, 1
  %mine = icmp eq i16 %ov1, %me1
  br i1 %mine, label %mine1, label %done
mine1:
  %same = icmp eq i16 %ov, %me
  br i1 %same, label %slotchk, label %pubslow
slotchk:
  %si2 = ptrtoint ptr %slot to i64
  %soff = sub i64 %si2, %hb
  %sinh = icmp ult i64 %soff, %hs
  br i1 %sinh, label %slook, label %snone
slook:
  %sidx = lshr i64 %soff, 15
  %sep = getelementptr inbounds i16, ptr %tab, i64 %sidx
  %osl = load i16, ptr %sep, align 2
  br label %sjoin
snone:
  br label %sjoin
sjoin:
  %os = phi i16 [ %osl, %slook ], [ 0, %snone ]
  %sm = icmp eq i16 %os, %me
  br i1 %sm, label %done, label %pubslow
pubslow:
  call void @_d_gc_publish_slow(ptr %slot, ptr %v)
  br label %done
`;
    ir ~= `
done:
  store ptr %v, ptr %slot, align 8
  ret void
}
`;
    if (invariantLoads)
    {
        // The stack bounds, arena bounds and heap table are fixed for a thread's
        // lifetime, so LLVM may hoist and merge these loads across the stores.
        foreach (ld; ["%lo = load i64, ptr %slp, align 8", "%sz = load i64, ptr %szp, align 8",
                      "%alo = load i64, ptr %alp, align 8", "%asz = load i64, ptr %asp, align 8",
                      "%hb = load i64, ptr @gcheap, align 8", "%hs = load i64, ptr %hsp, align 8",
                      "%tab = load ptr, ptr %tp, align 8"])
            ir = ir.replace(ld, ld ~ ", !invariant.load !99990");
    }
    return ir;
}

int main(string[] args)
{
    getopt(args, "mode", &mode, "elide-fresh", &elideFresh, "invariant", &invariantLoads);
    if (args.length != 3)
    {
        stderr.writeln("usage: rewrite_ir [--mode=...] [--elide-fresh] in.ll out.ll");
        return 2;
    }
    immutable allowed = ["none", "satb", "satb+vis", "publish", "publish+vis",
                         "split", "split+vis", "arena", "arena+vis"];
    if (!allowed.canFind(mode))
    {
        stderr.writeln("bad --mode; one of ", allowed);
        return 2;
    }

    auto reAlloc = regex(`^\s*(%[^\s=]+) = (?:tail )?(?:call|invoke) .*@[^\s(]*(?:_d_new|_d_alloc|gc_malloc|gc_calloc|gc_qalloc)[^\s(]*\(`);
    auto reAlloca = regex(`^\s*(%[^\s=]+) = alloca `);
    auto reDerive = regex(`^\s*(%[^\s=]+) = (?:getelementptr|bitcast|addrspacecast)[^,]*, ptr (%[^\s,)]+)`);
    auto reDefine = regex(`^define `);
    auto reStore = regex(`^(\s*)store (atomic |volatile )?ptr (.*)$`);

    Stats st;
    bool[string] fresh, allocas;
    string[] lines;
    bool insertedHeader;
    string barrier = mode == "none" ? "" : barrierIr();

    foreach (line; File(args[1]).byLineCopy)
    {
        if (!insertedHeader && line.startsWith("target triple") && barrier.length)
        {
            lines ~= line;
            lines ~= barrier;
            insertedHeader = true;
            continue;
        }
        if (matchFirst(line, reDefine))
        {
            fresh = null;
            allocas = null;
        }
        else if (auto m = matchFirst(line, reAlloc))
            fresh[m[1]] = true;
        else if (auto m = matchFirst(line, reAlloca))
            allocas[m[1]] = true;
        else if (auto m = matchFirst(line, reDerive))
        {
            if (m[2] in fresh) fresh[m[1]] = true;
            if (m[2] in allocas) allocas[m[1]] = true;
        }

        if (auto m = matchFirst(line, reStore))
        {
            ++st.seen;
            string rest;
            immutable value = takeOperand(m[3], rest);
            // rest starts with ", ptr <dst>, align ..."
            if (m[2].length || mode == "none" || !rest.startsWith(", ptr "))
            {
                if (m[2].length) ++st.skippedAtomic;
                lines ~= line;
                continue;
            }
            string tail;
            immutable dst = takeOperand(rest[", ptr ".length .. $], tail);
            if (dst in allocas)
            {
                ++st.elidedAlloca;
                lines ~= line;
                continue;
            }
            if (elideFresh && dst in fresh)
            {
                ++st.elidedFresh;
                lines ~= line;
                continue;
            }
            ++st.rewritten;
            lines ~= format("%scall void @__gcspike_store(ptr %s, ptr %s)", m[1], dst, value);
            continue;
        }
        lines ~= line;
    }

    if (invariantLoads && mode != "none")
        lines ~= "!99990 = !{}";
    std.file.write(args[2], lines.join("\n") ~ "\n");
    stderr.writefln("%s: %s pointer stores, %s rewritten, %s alloca, %s fresh, %s atomic/volatile",
                    args[1], st.seen, st.rewritten, st.elidedAlloca, st.elidedFresh, st.skippedAtomic);
    return 0;
}
