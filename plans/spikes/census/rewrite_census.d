/**
 * Escape-census instrumentation (RFC Phase 0.4): add observation hooks to LLVM IR emitted by LDC.
 *
 *     ldc2 -O3 -release -c -output-ll -singleobj -i=std -of=x.ll prog.d
 *     rewrite_census x.ll xc.ll
 *     clang -O2 -c xc.ll -o xc.o
 *     ldc2 xc.o census_rt.o -of=prog          (census_rt.o carries the census GC and the hooks)
 *
 * Unlike the barrier spike (rewrite_ir.d), nothing here changes behaviour. Before every
 * pointer store that is not to an alloca, and after every pointer-containing memcpy/memmove,
 * the rewritten code calls the census runtime with the destination, the stored value and a
 * "site" string (the mangled name of the enclosing function). Before every call into a
 * druntime allocation entry point it records the same site in a thread-local, so the census GC
 * can attribute each allocation to the function that asked for it.
 *
 * Limitations (see the report in the RFC):
 *   - only code compiled into this module is observed. With `-i=std` that covers Phobos, and
 *     templates instantiated from druntime; precompiled druntime code is not observed;
 *   - integer stores of pointer-sized values, aggregate stores and vector stores are not seen;
 *   - copies by libc `memcpy` calls (as opposed to the LLVM intrinsic) are not seen.
 */
module rewrite_census;

import std.algorithm;
import std.array;
import std.conv : to;
import std.file;
import std.regex;
import std.stdio;
import std.string;

struct Stats
{
    size_t stores, hooked, alloca, nullStores, copies, copiesHooked, allocCalls, functions;
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

string lastToken(string s)
{
    s = s.strip;
    immutable p = s.lastIndexOf(' ');
    return p < 0 ? s : s[p + 1 .. $];
}

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: rewrite_census in.ll out.ll");
        return 2;
    }
    auto reAlloc = regex(`@(?:_d_new|_d_alloc|_d_array|_d_arr|_d_assoc|_aaG|_aaR|_d_dup|gc_malloc|gc_calloc|gc_qalloc|gc_realloc)[A-Za-z0-9_]*`);
    auto reCallLine = regex(`^\s*(?:%[^\s=]+ = )?(?:tail |musttail |notail )?(?:call|invoke) `);
    auto reAlloca = regex(`^\s*(%[^\s=]+) = alloca `);
    auto reDerive = regex(`^\s*(%[^\s=]+) = (?:getelementptr|bitcast|addrspacecast)[^,]*, ptr (%[^\s,)]+)`);
    auto reDefine = regex(`^define .*@("[^"]+"|[A-Za-z0-9_.$]+)\(`);
    auto reStore = regex(`^(\s*)store (atomic |volatile )?ptr (.*)$`);
    auto reCopy = regex(`^\s*(?:tail )?call void @llvm\.mem(?:cpy|move)\.p0\.p0\.i64\((.*)\)`);

    Stats st;
    bool[string] allocas;
    string[] lines;
    string[] sites;
    size_t[string] siteIndex;
    string curSite;
    bool insertedHeader;

    size_t siteFor(string name)
    {
        if (auto p = name in siteIndex) return *p;
        immutable i = sites.length;
        sites ~= name;
        siteIndex[name] = i;
        return i;
    }
    string sitePtr() { return "@__census_site_" ~ siteFor(curSite).to!string; }
    // Allocation sites are "kind:function" so the report can group by the druntime entry point.
    string sitePtrFor(string kind) { return "@__census_site_" ~ siteFor(kind ~ ":" ~ curSite).to!string; }
    string kindOf(string callee)
    {
        foreach (k; [["newclass", "newclass"], ["allocclass", "newclass"], ["newitem", "newitem"], ["newarray", "newarray"],
                     ["arrayappend", "append"], ["arraycat", "cat"], ["arraysetlength", "setlength"],
                     ["dup", "dup"], ["allocmemory", "allocmemory"], ["gc_", "gc"], ["_aa", "aa"],
                     ["_d_assoc", "aa"], ["_d_arr", "array"]])
            if (callee.canFind(k[0])) return k[1];
        return "other";
    }

    foreach (line; File(args[1]).byLineCopy)
    {
        if (!insertedHeader && line.startsWith("target triple"))
        {
            lines ~= line;
            lines ~= "declare void @_d_census_store(ptr, ptr, ptr)";
            lines ~= "declare void @_d_census_copy(ptr, i64, ptr)";
            lines ~= "@_census_alloc_site = external thread_local global ptr";
            insertedHeader = true;
            continue;
        }
        if (auto m = matchFirst(line, reDefine))
        {
            allocas = null;
            string n = m[1];
            if (n.startsWith('"')) n = n[1 .. $ - 1];
            curSite = n;
            ++st.functions;
        }
        else if (auto m = matchFirst(line, reAlloca))
            allocas[m[1]] = true;
        else if (auto m = matchFirst(line, reDerive))
        {
            if (m[2] in allocas) allocas[m[1]] = true;
        }

        if (curSite.length)
        {
            if (auto m = matchFirst(line, reStore))
            {
                ++st.stores;
                string rest;
                immutable value = takeOperand(m[3], rest);
                if (rest.startsWith(", ptr "))
                {
                    string tail;
                    immutable dst = takeOperand(rest[", ptr ".length .. $], tail);
                    if (value == "null")
                        ++st.nullStores;
                    else if (dst in allocas)
                        ++st.alloca;
                    else
                    {
                        ++st.hooked;
                        lines ~= format("%scall void @_d_census_store(ptr %s, ptr %s, ptr %s)", m[1], dst, value, sitePtr());
                    }
                }
                lines ~= line;
                continue;
            }
            if (auto m = matchFirst(line, reCallLine))
            {
                if (auto a = matchFirst(line, reAlloc))
                {
                    ++st.allocCalls;
                    lines ~= format("  store ptr %s, ptr @_census_alloc_site, align 8", sitePtrFor(kindOf(a[0])));
                }
                else if (auto c = matchFirst(line, reCopy))
                {
                    ++st.copies;
                    string rest;
                    immutable dstOp = takeOperand(c[1], rest);
                    string rest2;
                    immutable srcOp = takeOperand(rest[1 .. $], rest2);
                    string rest3;
                    immutable szOp = takeOperand(rest2[1 .. $], rest3);
                    immutable dst = lastToken(dstOp);
                    if (!(dst in allocas) && dst.length && (dst[0] == '%' || dst[0] == '@'))
                    {
                        ++st.copiesHooked;
                        lines ~= line;
                        lines ~= format("  call void @_d_census_copy(ptr %s, i64 %s, ptr %s)", dst, lastToken(szOp), sitePtr());
                        continue;
                    }
                }
            }
        }
        lines ~= line;
    }

    foreach (i, s; sites)
        lines ~= format(`@__census_site_%s = private unnamed_addr constant [%s x i8] c"%s\00"`, i, s.length + 1, s.replace(`\`, `\5C`).replace(`"`, `\22`));

    std.file.write(args[2], lines.join("\n") ~ "\n");
    stderr.writefln("%s: %s functions, %s pointer stores (%s hooked, %s to allocas, %s null), %s memcpy/memmove (%s hooked), %s allocation calls tagged",
        args[1], st.functions, st.stores, st.hooked, st.alloca, st.nullStores, st.copies, st.copiesHooked, st.allocCalls);
    return 0;
}
