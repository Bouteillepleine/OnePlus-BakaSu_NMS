#!/usr/bin/env python3
"""Reconcile susfs4ksu's kernel-side patch with the tree being built.

usage: susfs_patch_surgery.py [--drop <file>]... <patch> <tree-root> [<file:hunk> ...]

--drop removes every hunk of that file from the patch: the tree keeps its own
version (selinuxfs.c, where the KSU side and NoMount already own the hiding).
Each <file:hunk> is a hunk `patch --dry-run` rejected. A rejected hunk is
dropped from the patch and its additions re-inserted into the tree. Two kinds
of drift are absorbed:

  * sublevel drift: susfs rebases the patch onto one GKI sublevel at a time,
    so a hunk's context may not exist on the sublevel being built. Those are
    handled by content-matched rules that know where the code belongs.
  * foreign insertions: a patch stack applied before susfs (NoMount) adds lines
    inside the same functions, which breaks the hunk's context without changing
    any line susfs anchors on. Purely additive hunks are re-applied by walking
    their context lines in order and skipping over the foreign lines.

Hunks are recognised by the content they add, never by @@ line numbers, which
every rebase renumbers. A reject with no resolution is a hard failure.
"""
import io
import re
import sys


def split_patch(text):
    out, pre, path, hunks, cur = [], [], None, [], None

    def flush():
        if path is not None:
            if cur:
                hunks.append(cur)
            out.append([pre, path, hunks])

    for line in text.split('\n'):
        if line.startswith('diff --git '):
            flush()
            pre, path, hunks, cur = [line], None, [], None
        elif line.startswith('+++ b/') and path is None:
            path = line[6:]
            pre.append(line)
        elif line.startswith('@@'):
            if cur:
                hunks.append(cur)
            cur = [line]
        elif cur is not None:
            cur.append(line)
        else:
            pre.append(line)
    flush()
    return out


def join_patch(sections):
    chunks = []
    for pre, _path, hunks in sections:
        chunks.append('\n'.join(pre))
        for h in hunks:
            chunks.append('\n'.join(h))
    return '\n'.join(chunks)


def body_lines(hunk):
    return [l for l in hunk[1:] if not l.startswith('\\')]


def added(hunk):
    return '\n'.join(l[1:] for l in body_lines(hunk) if l.startswith('+'))


def added_runs(hunk):
    runs, cur = [], []
    for l in body_lines(hunk):
        if l.startswith('+'):
            cur.append(l[1:])
        elif cur:
            runs.append('\n'.join(cur))
            cur = []
    if cur:
        runs.append('\n'.join(cur))
    return runs


def has_deletions(hunk):
    return any(l.startswith('-') and l[1:].strip() for l in body_lines(hunk))


def read(path):
    return io.open(path, encoding='utf-8').read()


def write(path, s):
    io.open(path, 'w', encoding='utf-8').write(s)


GUARD_MAP = '#ifdef CONFIG_KSU_SUSFS_SUS_MAP'
ENDIF_MAP = '#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP'

DECL_RE = re.compile(
    r'^[ \t]+(?:const\s+|volatile\s+|register\s+|static\s+|extern\s+)*'
    r'(?:struct|union|enum|unsigned|signed|char|short|int|long|float|double|bool|'
    r'void|u8|u16|u32|u64|s8|s16|s32|s64|[A-Za-z_][A-Za-z0-9_]*_t)\b')

PP_RE = re.compile(r'^[ \t]*#\s*(if|ifdef|ifndef|else|elif|endif)\b')


def body_decl_end(lines):
    """Where susfs's guard belongs: (index, indent) of the first line of a
    function body that is neither blank, nor a top-of-body declaration, nor the
    preprocessor scaffolding around one. None when the body opens with a
    statement, so the caller declines rather than guessing.

    The preprocessor part is not cosmetic. OnePlus's 5.10/5.15/6.1 show_smap()
    declares `char buf[256]` inside `#if defined(CONFIG_CONT_PTE_HUGEPAGE)`,
    so stopping at the `#if` put the guard above a declaration -- statement
    first, declaration after, on any tree that sets that config -- and took the
    `#if` line's indent, which is none, so the guard came out flush left. Walk
    through the scaffolding and take the indent from the declarations instead.
    """
    ind, seen, cont = None, False, False
    for i, l in enumerate(lines):
        if not l.strip() or PP_RE.match(l):
            continue
        if cont:
            cont = not l.rstrip().endswith(';')
            continue
        if DECL_RE.match(l):
            ind, seen = indent_of(l), True
            cont = not l.rstrip().endswith(';')
            continue
        return (i, ind if ind is not None else indent_of(l)) if seen else None
    return None


def indent_of(line):
    return re.match(r'^[ \t]*', line).group(0)


def function_span(s, name):
    m = re.search(r'^[^\n;]*\b' + re.escape(name) + r'\s*\([^;{}]*\)\s*\n\{\n', s, re.M)
    if not m:
        return None
    start = m.end()
    end = s.find('\n}\n', start)
    if end < 0:
        return None
    return start, end + 1


def insert_after_include(path, marker, anchors, block):
    s = read(path)
    if marker in s:
        return 'already present'
    for anchor in anchors:
        if s.count(anchor) == 1:
            write(path, s.replace(anchor, anchor + block, 1))
            return 'inserted after ' + anchor.strip()
    return None


def insert_exec_include(tree):
    return insert_after_include(
        tree + '/fs/exec.c', 'susfs_def.h',
        ['#include <linux/ksm.h>\n', '#include <linux/rseq.h>\n'],
        '#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif\n')


def insert_memory_include(tree):
    return insert_after_include(
        tree + '/mm/memory.c', 'susfs_def.h',
        ['#include <linux/vmalloc.h>\n', '#include <linux/mm.h>\n'],
        GUARD_MAP + '\n#include <linux/susfs_def.h>\n' + ENDIF_MAP + '\n')


def insert_show_smap_guard(tree):
    path = tree + '/fs/proc/task_mmu.c'
    s = read(path)
    span = function_span(s, 'show_smap')
    if not span:
        return None
    a, b = span
    body = s[a:b]
    if 'SUSFS_IS_INODE_SUS_MAP' in body:
        return 'already present'
    hits = list(re.finditer(r'^\tif \(!vma_(?:data_)?pages\(vma\)\)$', body, re.M))
    if len(hits) != 1:
        return None
    block = (GUARD_MAP + '\n'
             '\tif (vma->vm_file) {\n'
             '\t\tif (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n'
             '\t\t\treturn 0;\n'
             '\t}\n'
             + ENDIF_MAP + '\n\n')
    i = hits[0].start()
    write(path, s[:a] + body[:i] + block + body[i:] + s[b:])
    return 'inserted before the vma_pages() check in show_smap()'


def insert_rollup_bypass(tree):
    path = tree + '/fs/proc/task_mmu.c'
    s = read(path)
    span = function_span(s, 'show_smaps_rollup')
    if not span:
        return None
    a, b = span
    lines = s[a:b].split('\n')
    if any('bypass_orig_flow' in l for l in lines):
        return 'already present'
    heads = [i for i, l in enumerate(lines) if l in ('\tdo {', '\tfor (vma = priv->mm->mmap; vma;) {')]
    if len(heads) != 1:
        return None
    h = heads[0]
    g = next((i for i in range(h + 1, min(h + 14, len(lines)))
              if re.match(r'^\t+smap_gather_stats\(vma, &mss, 0\);$', lines[i])), None)
    if g is None:
        return None
    # Not the loop head itself: a stack applied before susfs opens this block
    # with its own declarations -- pathhide puts `extern bool
    # pathhide_match_file` and a `bool ph_hidden = ...` there -- and a guard
    # above them makes both declarations-after-statement while the goto jumps
    # over an initialiser. Enter after the leading declarations instead; when
    # the loop opens with a statement, body_decl_end() says so and h + 1 stands.
    at = body_decl_end(lines[h + 1:g])
    ins = h + 1 + (at[0] if at else 0)
    # Loop-body indent: the declarations sit at it, whereas lines[g] may be
    # nested one deeper inside a guard pathhide wrapped around the gather call.
    ind = at[1] if at else indent_of(lines[g])
    label = [GUARD_MAP, 'bypass_orig_flow:', ENDIF_MAP]
    guard = [GUARD_MAP,
             ind + 'if (vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))',
             ind + '\tgoto bypass_orig_flow;',
             ENDIF_MAP]
    # The label sits after `ins`, so inserting it first keeps that index valid.
    lines = lines[:g + 1] + label + lines[g + 1:]
    lines = lines[:ins] + guard + lines[ins:]
    write(path, s[:a] + '\n'.join(lines) + s[b:])
    return 'inserted after the declarations at the show_smaps_rollup() loop head'


def insert_top_declarations(tree, path, hunk):
    runs = added_runs(hunk)
    if not runs or has_deletions(hunk):
        return None
    for r in runs:
        for l in r.split('\n'):
            if l.strip() and not re.match(r'^(#|extern |/\*|\s*\*|//)', l):
                return None
    fpath = tree + '/' + path
    text = read(fpath)
    if all(r in text for r in runs):
        return 'already present'
    lines = text.split('\n')
    last = None
    for i, l in enumerate(lines):
        if l.startswith('#include'):
            last = i
        elif re.match(r'^[A-Za-z_]', l) and not l.startswith('extern '):
            break
    if last is None:
        return None
    block = '\n'.join(runs)
    lines = lines[:last + 1] + [block] + lines[last + 1:]
    write(fpath, '\n'.join(lines))
    return 'declarations placed after the last #include (line %d)' % (last + 1)


RULES = [
    ('fs/exec.c', '#include <linux/susfs_def.h>', insert_exec_include),
    ('mm/memory.c', '#include <linux/susfs_def.h>', insert_memory_include),
    ('fs/proc/task_mmu.c', 'SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\treturn 0;', insert_show_smap_guard),
    ('fs/proc/task_mmu.c', 'goto bypass_orig_flow;', insert_rollup_bypass),
    ('fs/proc/task_mmu.c', 'bypass_orig_flow:', insert_rollup_bypass),
]

WINDOW = 80


EDGE = 2


def walk_from(lines, body, start):
    out, i, pending = lines[:start], start, []
    nctx = sum(1 for l in body if not l.startswith('+') and not l.startswith('-'))
    seen = 0
    for l in body:
        if l.startswith('+'):
            pending.append(l[1:])
            continue
        if l.startswith('-'):
            if i >= len(lines) or lines[i].strip():
                return None, lines[i] if i < len(lines) else '<eof>'
            i += 1
            continue
        c = l[1:] if l.startswith(' ') else l
        seen += 1
        if pending:
            out.extend(pending)
            pending = []
        j = next((k for k in range(i, min(i + WINDOW, len(lines))) if lines[k] == c), None)
        if j is None:
            if seen <= EDGE or seen > nctx - EDGE:
                continue
            return None, c
        out.extend(lines[i:j + 1])
        i = j + 1
    out.extend(pending)
    out.extend(lines[i:])
    return out, None


def reapply_additive(tree, path, hunk):
    if has_deletions(hunk):
        return None
    fpath = tree + '/' + path
    text = read(fpath)
    lines = text.split('\n')
    runs = added_runs(hunk)
    if runs and all(r in text for r in runs):
        return 'already present'
    body = body_lines(hunk)
    ctx = [l[1:] if l.startswith(' ') else l for l in body if not l.startswith('+') and not l.startswith('-')]
    if not ctx:
        return None
    old_start = int(re.match(r'@@ -(\d+)', hunk[0]).group(1)) - 1
    cands = []
    for k, c in enumerate(ctx):
        if len(c.strip()) < 8:
            continue
        cands = sorted((i for i, l in enumerate(lines) if l == c), key=lambda i: abs(i - (old_start + k)))
        if cands:
            break
    if not cands:
        print('   context miss: %s anchor: %r' % (path, ctx[0]))
        return None
    miss = None
    for cand in cands:
        cur = cand
        for n, c in reversed(list(enumerate(ctx[:k]))):
            j = next((m for m in range(cur - 1, max(cur - WINDOW, -1), -1) if lines[m] == c), None)
            if j is None:
                if n < EDGE:
                    continue
                cur = None
                break
            cur = j
        if cur is None:
            miss = miss or ctx[0]
            continue
        out, miss_line = walk_from(lines, body, cur)
        if out is None:
            miss = miss or miss_line
            continue
        new = '\n'.join(out)
        if not all(r in new for r in runs):
            continue
        write(fpath, new)
        return 'additions re-applied in context order from line %d' % (cur + 1)
    print('   context miss: %s near line %d: %r' % (path, cands[0] + 1, miss))
    return None


def main():
    args, drop = [], set()
    it = iter(sys.argv[1:])
    for a in it:
        if a == '--drop':
            drop.add(next(it, ''))
        else:
            args.append(a)
    if len(args) < 2:
        sys.exit(__doc__)
    patch_path, tree = args[0], args[1].rstrip('/')
    wanted = set()
    for spec in args[2:]:
        f, _, n = spec.rpartition(':')
        wanted.add((f, int(n)))

    sections = split_patch(read(patch_path))
    done, failed = [], []

    for sec in sections:
        _pre, path, hunks = sec
        keep = []
        if path in drop:
            done.append('%s -> all %d hunk(s) dropped, this tree keeps its own' % (path, len(hunks)))
            sec[2] = keep
            continue
        for idx, hunk in enumerate(hunks, 1):
            if (path, idx) not in wanted:
                keep.append(hunk)
                continue
            content = added(hunk)
            seen, note = set(), None
            for p, marker, fn in RULES:
                if p == path and marker in content and fn not in seen:
                    seen.add(fn)
                    note = fn(tree)
                    if note is None:
                        break
            if note is None:
                note = reapply_additive(tree, path, hunk)
            if note is None:
                note = insert_top_declarations(tree, path, hunk)
            if note is None:
                why = 'has deletions, cannot be re-applied' if has_deletions(hunk) else 'its context was not found in the tree'
                failed.append('%s hunk #%d: %s' % (path, idx, why))
                keep.append(hunk)
                continue
            done.append('%s hunk #%d -> %s' % (path, idx, note))
        sec[2] = keep

    for line in done:
        print('   reconciled: ' + line)
    for line in failed:
        print('   UNRESOLVED: ' + line)

    if failed:
        return 1

    write(patch_path, join_patch(sections))
    return 0


if __name__ == '__main__':
    sys.exit(main())
