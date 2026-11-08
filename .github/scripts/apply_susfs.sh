#!/usr/bin/env bash
set -euo pipefail

for v in KERNEL_PLATFORM_FOLDER COMMON_KERNEL_FOLDER SUSFS_FOLDER KSU_FOLDER ARTIFACTS_FOLDER OP_MODEL OP_OS_VERSION ANDROID_VER KERNEL_VER GITHUB_ENV; do
  [ -n "${!v:-}" ] || { echo "::error::apply_susfs: $v is not set"; exit 1; }
done

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SURGERY="$SCRIPTS_DIR/susfs_patch_surgery.py"
[ -f "$SURGERY" ] || { echo "::error::apply_susfs: $SURGERY is missing"; exit 1; }

SUSFS_BRANCH="${SUSFS_KERNEL_BRANCH:-gki-${ANDROID_VER}-${KERNEL_VER}}"
SUSFS_PATCH_SRC="$SUSFS_FOLDER/kernel_patches/50_add_susfs_in_${SUSFS_BRANCH}.patch"
if [ ! -f "$SUSFS_PATCH_SRC" ]; then
  echo "::error::apply_susfs: no kernel patch for $SUSFS_BRANCH in $SUSFS_FOLDER/kernel_patches"
  find "$SUSFS_FOLDER/kernel_patches" -maxdepth 1 -name '50_add_susfs_in_*.patch' | sort
  exit 1
fi

cd "$COMMON_KERNEL_FOLDER"

cp "$SUSFS_FOLDER/kernel_patches/fs/"* fs/
cp "$SUSFS_FOLDER/kernel_patches/include/linux/"* include/linux/

SUSVER="$(grep '#define SUSFS_VERSION' include/linux/susfs.h | awk -F'"' '{print $2}')"
[ -n "$SUSVER" ] || { echo "::error::apply_susfs: could not read SUSFS_VERSION from include/linux/susfs.h"; exit 1; }
# v2.4.0 added: 50_add_susfs_in_gki-<kmi>.patch is byte-identical to the v2.3.0
# one on all five KMIs, so the reject record in apply_susfs_kernel.sh still fits.
# The label moved, the kernel side did not.
case "$SUSVER" in
  v2.3.0|v2.4.0) ;;
  *) echo "::error::apply_susfs: SUSFS $SUSVER has not been checked against this builder (v2.3.0 and v2.4.0 only); pin susfs_ref to a known commit or update the scripts"; exit 1 ;;
esac
echo "SUSVER=$SUSVER" >> "$GITHUB_ENV"
echo "$SUSVER" >> "${ARTIFACTS_FOLDER}/${OP_MODEL}_${OP_OS_VERSION}.txt"
echo "SUSFS $SUSVER from $SUSFS_BRANCH"

if ! grep -rqs 'config KSU_SUSFS' "$KSU_FOLDER/kernel/Kconfig"; then
  echo "::error::apply_susfs: $KSU_FOLDER/kernel/Kconfig has no KSU_SUSFS option; this BakaSU ref does not carry the KSU side of SUSFS"
  exit 1
fi
if grep -qs '^\$(error Please wait susfs update' "$KSU_FOLDER/kernel/tools/susfs_compat.mk"; then
  echo "::error::apply_susfs: this BakaSU ref refuses SUSFS builds (susfs_compat.mk still carries \$(error Please wait susfs update)); pick a ref that has caught up or build with susfs_ref empty"
  exit 1
fi

replace_text() {
  python3 -I -c 'import sys; p,o,n=sys.argv[1:4]; d=open(p,encoding="utf-8",errors="ignore").read(); open(p,"w",encoding="utf-8").write(d.replace(o,n))' "$1" "$2" "$3"
}

if [ "$ANDROID_VER" = android15 ] && [ "$KERNEL_VER" = 6.6 ]; then
  grep -qxF '#include <trace/hooks/fs.h>' fs/namespace.c || sed -i '/#include <trace\/hooks\/blk.h>/a #include <trace/hooks/fs.h>' fs/namespace.c
fi

fake_patched=0
if [ "$ANDROID_VER" = android15 ] && [ "$KERNEL_VER" = 6.6 ]; then
  if ! grep -qxF $'\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;' fs/proc/task_mmu.c; then
    sed -i -e '/int ret = 0, copied = 0;/a \\tunsigned int nr_subpages \= __PAGE_SIZE \/ PAGE_SIZE;' \
           -e '/int ret = 0, copied = 0;/a \\tpagemap_entry_t \*res = NULL;' fs/proc/task_mmu.c
    fake_patched=1
  fi
  grep -qxF '#include <linux/dma-buf.h>' fs/proc/base.c || sed -i '/#include <linux\/cpufreq_times.h>/a #include <linux\/dma-buf.h>' fs/proc/base.c
fi
if { [ "$ANDROID_VER" = android12 ] && [ "$KERNEL_VER" = 5.10 ]; } || { [ "$ANDROID_VER" = android13 ] && [ "$KERNEL_VER" = 5.15 ]; }; then
  grep -qxF $'\tif (!vma_pages(vma))' fs/proc/task_mmu.c || fake_patched=1
fi
if [ "$ANDROID_VER" = android14 ] && [ "$KERNEL_VER" = 6.1 ]; then
  grep -qxF $'\tif (!vma_pages(vma))' fs/proc/task_mmu.c || fake_patched=1
  grep -qxF '#include <linux/dma-buf.h>' fs/proc/base.c || sed -i '/#include <linux\/cpufreq_times.h>/a #include <linux\/dma-buf.h>' fs/proc/base.c
fi

SUSFS_PATCH="$(mktemp "${RUNNER_TEMP:-/tmp}/50_add_susfs.XXXXXX.patch")"
cp "$SUSFS_PATCH_SRC" "$SUSFS_PATCH"

drops=(--drop security/selinux/selinuxfs.c)
if grep -q 'my_setprocattr' "$SUSFS_PATCH" && ! grep -rqs 'int my_setprocattr(' "$KSU_FOLDER/kernel"; then
  if grep -rqs 'KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE' "$KSU_FOLDER/kernel"; then
    drops+=(--drop security/selinux/hooks.c)
    echo "the KSU tree owns selinux_hide; dropping the SUSFS hooks.c hunks"
  else
    echo "::error::apply_susfs: SUSFS calls my_setprocattr() but the KSU tree neither exports it nor implements selinux_hide itself"
    exit 1
  fi
fi

rejects="$(patch -p1 -F0 --forward --dry-run < "$SUSFS_PATCH" 2>&1 | awk '/^checking file/{f=$3} /Hunk #[0-9]+ FAILED/{n=$2; gsub("#","",n); print f":"n}')" || true
if [ -n "$rejects" ]; then
  echo "SUSFS kernel patch rejects on ${ANDROID_VER}-${KERNEL_VER} ($(grep -m1 '^SUBLEVEL' Makefile | tr -d ' ')):"
  printf '%s\n' "$rejects" | sed 's/^/   rejected: /'
fi
python3 -I "$SURGERY" "${drops[@]}" "$SUSFS_PATCH" . $rejects

fix_exec_include() {
  grep -q '#include <linux/susfs_def.h>' fs/exec.c && return 0
  for anchor in '#include <linux/ksm.h>' '#include <linux/rseq.h>'; do
    if grep -qxF "$anchor" fs/exec.c; then
      sed -i "/$(printf '%s' "$anchor" | sed 's/[\/&]/\\&/g')/a #ifdef CONFIG_KSU_SUSFS\n#include <linux\/susfs_def.h>\n#endif" fs/exec.c
      return 0
    fi
  done
  return 1
}
fix_memory_include() {
  grep -q '#include <linux/susfs_def.h>' mm/memory.c && return 0
  for anchor in '#include <linux/vmalloc.h>' '#include <linux/mm.h>'; do
    if grep -qxF "$anchor" mm/memory.c; then
      sed -i "/$(printf '%s' "$anchor" | sed 's/[\/&]/\\&/g')/a #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n#include <linux\/susfs_def.h>\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP" mm/memory.c
      return 0
    fi
  done
  return 1
}

if ! patch -p1 -F0 --forward < "$SUSFS_PATCH"; then
  if [ -f fs/exec.c.rej ] && grep -q 'susfs_def.h' fs/exec.c.rej && [ "$(grep -c '^@@' fs/exec.c.rej)" = 1 ] && fix_exec_include; then
    rm -f fs/exec.c.rej
  fi
  if [ -f mm/memory.c.rej ] && grep -q 'CONFIG_KSU_SUSFS_SUS_MAP' mm/memory.c.rej && [ "$(grep -c '^@@' mm/memory.c.rej)" = 1 ] && fix_memory_include; then
    rm -f mm/memory.c.rej
  fi
  if [ -n "$(find . -name '*.rej' -print -quit)" ]; then
    echo "::error::apply_susfs: SUSFS $SUSVER does not fit this ${ANDROID_VER}-${KERNEL_VER} tree"
    find . -name '*.rej' -exec echo "=== {} ===" \; -exec cat {} \;
    exit 1
  fi
fi
rm -f "$SUSFS_PATCH"

if [ "$fake_patched" = 1 ]; then
  if [ "$ANDROID_VER" = android15 ] && [ "$KERNEL_VER" = 6.6 ]; then
    sed -i -e '/unsigned int nr_subpages \= __PAGE_SIZE \/ PAGE_SIZE;/d' -e '/pagemap_entry_t \*res = NULL;/d' fs/proc/task_mmu.c
  else
    sed -i 's/goto show_pad;/return 0;/' fs/proc/task_mmu.c
  fi
fi

tm=fs/proc/task_mmu.c
before="$(md5sum "$tm" | cut -d' ' -f1)"
sed -i -E 's@^([[:blank:]]{3,})end = VMA_PAD_START\(vma\);[[:blank:]]*$@\1end = vma->vm_end;@' "$tm"
sed -i -E '/^[[:blank:]]{3,}__fold_filemap_fixup_entry\(/d' "$tm"
[ "$before" = "$(md5sum "$tm" | cut -d' ' -f1)" ] || echo "neutralised susfs OPEN_REDIRECT VMA_PAD_START/__fold refs in $tm"

if grep -q 'set_nameidata(nd, old_dfd, fake_filename, NULL)' fs/namei.c; then
  nd_decl="$(awk '/void[ \t]+set_nameidata[ \t]*\(/ {f=1} f {printf "%s ", $0; if (/\)/) exit}' fs/namei.c)"
  if [ "$(printf '%s' "$nd_decl" | tr -cd ',' | wc -c)" -eq 2 ]; then
    sed -i 's/set_nameidata(nd, old_dfd, fake_filename, NULL)/set_nameidata(nd, old_dfd, fake_filename)/g' fs/namei.c
    echo "dropped the root argument from susfs set_nameidata() calls (3-arg tree)"
  fi
fi

OLD='for (; mnt->mnt_id >= DEFAULT_KSU_MNT_ID; mnt = mnt->mnt_parent) { }'
NEW='for (; mnt->mnt_id >= DEFAULT_KSU_MNT_ID && mnt->mnt_parent && mnt != mnt->mnt_parent; mnt = mnt->mnt_parent) { }'
for f in fs/statfs.c fs/proc/fd.c; do
  [ -f "$f" ] && grep -qF "$OLD" "$f" && replace_text "$f" "$OLD" "$NEW" && echo "bounded the sus_mount parent walk in $f"
done
OLD='error = statfs_by_dentry(mnt->mnt.mnt_root, buf);'
NEW='if (likely(susfs_is_current_proc_umounted_app())) { error = statfs_by_dentry(mnt->mnt.mnt_root, buf); } else { error = statfs_by_dentry(path->dentry, buf); }'
if grep -qF "$OLD" fs/statfs.c; then
  replace_text fs/statfs.c "$OLD" "$NEW"
  echo "statfs: spoof the root dentry only for umounted apps"
fi

if grep -qE 'getname_flags\(const char __user \*, int\);' include/linux/fs.h && grep -qF 'fname = getname_flags(filename, lookup_flags, NULL);' fs/open.c; then
  replace_text fs/open.c 'fname = getname_flags(filename, lookup_flags, NULL);' 'fname = getname_flags(filename, lookup_flags);'
  replace_text fs/open.c 'ksu_handle_faccessat(&dfd, &fname, &mode, NULL);' 'if (!IS_ERR(fname)) ksu_handle_faccessat(&dfd, &fname, &mode, NULL);'
  echo "fixed the getname_flags() arity in fs/open.c"
fi

if grep -qF 'susfs_open_redirect_spoof_vfs_statfs' fs/statfs.c && ! grep -qE '^[a-zA-Z_].*susfs_open_redirect_spoof_vfs_statfs[[:space:]]*[(].*\{[[:space:]]*$' fs/susfs.c; then
  cat >> fs/susfs.c <<'EOF'

#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
int susfs_open_redirect_spoof_vfs_statfs(struct inode *inode, struct kstatfs *buf) {
    struct st_susfs_open_redirect_hlist *entry = NULL;
    int srcu_idx = srcu_read_lock(&susfs_srcu_open_redirect);

    hash_for_each_possible_rcu(OPEN_REDIRECT_HLIST, entry, node, inode->i_ino) {
        if (entry->reversed_lookup_only &&
            entry->target_dev == inode->i_sb->s_dev) {
            SUSFS_LOGI("spoof kstatfs for redirected path: %s\n", entry->info.target_pathname);
            memcpy(buf, &entry->spoofed_kstatfs, sizeof(struct kstatfs));
            srcu_read_unlock(&susfs_srcu_open_redirect, srcu_idx);
            return 0;
        }
    }
    srcu_read_unlock(&susfs_srcu_open_redirect, srcu_idx);
    return -EINVAL;
}
#endif
EOF
  echo "restored susfs_open_redirect_spoof_vfs_statfs() in fs/susfs.c"
fi

if grep -q '#ifndef KSU_NO_PREINIT' fs/exec.c && ! grep -q '^#define KSU_NO_PREINIT$' fs/exec.c; then
  if grep -rqs 'ksu_setup_preinit_file' "$KSU_FOLDER/kernel"; then
    echo "KSU tree provides preinit; leaving the SUSFS preinit hooks enabled"
  else
    sed -i '0,/^#ifdef CONFIG_KSU_SUSFS$/s//#ifndef KSU_NO_PREINIT\n#define KSU_NO_PREINIT\n#endif\n&/' fs/exec.c
    grep -q '^#define KSU_NO_PREINIT$' fs/exec.c || { echo "::error::apply_susfs: could not define KSU_NO_PREINIT in fs/exec.c"; exit 1; }
    echo "defined KSU_NO_PREINIT; this KSU tree has no preinit"
  fi
fi

if grep -q 'my_setprocattr' security/selinux/hooks.c && ! grep -rqs 'int my_setprocattr(' "$KSU_FOLDER/kernel"; then
  echo "::error::apply_susfs: security/selinux/hooks.c still calls my_setprocattr() without a KSU definition"
  exit 1
fi
if grep -qE 'ksu_selinux_hide_enabled|fake_status|initialize_fake_status|fake_status_initialize_key|my_sel_open_handle_status' security/selinux/selinuxfs.c; then
  echo "::error::apply_susfs: SUSFS selinuxfs hunks reached security/selinux/selinuxfs.c"
  exit 1
fi

DEFCONFIG=arch/arm64/configs/gki_defconfig
sed -i '/^CONFIG_KSU_SUSFS/d' "$DEFCONFIG"
cat >> "$DEFCONFIG" <<'EOF'
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=n
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
EOF

# SUSFS gained PRIORITY_UID_FILTER on 2026-11-01, upstream default y: it hides
# user-defined uids from getpriority/setpriority/ioprio_get/ioprio_set for every
# process with uid >= 10000. NoMount already closes that oracle (uidconceal, plus
# the fgetpriority LKM), so a second filter on the same four syscalls is duplicate
# coverage and is pinned off rather than left to its default.
#
# Conditional because the check below rejects a symbol this fork does not define,
# and BakaSU has not synced the option yet. A no-op until it does.
if grep -qE '^[[:space:]]*config[[:space:]]+KSU_SUSFS_PRIORITY_UID_FILTER([[:space:]]|$)' \
    "$KSU_FOLDER/kernel/Kconfig"; then
  echo "CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER=n" >> "$DEFCONFIG"
  echo "SUSFS: PRIORITY_UID_FILTER pinned off (NoMount owns getpriority/ioprio)"
fi

missing=0
while IFS= read -r line; do
  sym="${line%%=*}"; sym="${sym#CONFIG_}"
  grep -qE "^[[:space:]]*config[[:space:]]+${sym}([[:space:]]|\$)" "$KSU_FOLDER/kernel/Kconfig" && continue
  echo "::error::apply_susfs: $DEFCONFIG sets CONFIG_${sym} but $KSU_FOLDER/kernel/Kconfig defines no such option"
  missing=$((missing + 1))
done < <(grep -E '^CONFIG_KSU_SUSFS' "$DEFCONFIG")
[ "$missing" -eq 0 ] || exit 1

# The other direction, which is the one that bites quietly: an option this SUSFS
# version DEFINES but the block above never writes takes its own Kconfig default,
# and nothing says so. That is exactly how KSU_SUSFS_PRIORITY_UID_FILTER (default
# y) would have shipped enabled -- the check above only ever looked at what we
# write, never at what exists. Ported from OnePlus-KsuNext_NMS, where the
# equivalent gate is what caught it.
undecided="$(comm -13 \
  <(grep -E '^CONFIG_KSU_SUSFS' "$DEFCONFIG" | sed 's/^CONFIG_//; s/=.*//' | sort -u) \
  <(grep -oE '^[[:space:]]*config[[:space:]]+KSU_SUSFS[A-Z_]*' "$KSU_FOLDER/kernel/Kconfig" \
      | awk '{print $2}' | sort -u))"
if [ -n "$undecided" ]; then
  echo "::error::apply_susfs: SUSFS $SUSVER defines options this builder never writes, so they would take their Kconfig default:"
  echo "$undecided" | sed 's/^/     /'
  echo "::error::Add each one to the SUSFS defconfig block in this script with an explicit y or n."
  exit 1
fi

for sym in SUSFS_IS_INODE_SUS_MAP susfs_is_current_proc_umounted_app; do
  grep -rqs "$sym" fs include/linux || { echo "::error::apply_susfs: $sym never reached the tree"; exit 1; }
done
grep -q 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || { echo "::error::apply_susfs: fs/Makefile does not build susfs.o"; exit 1; }

echo "SUSFS $SUSVER applied to ${ANDROID_VER}-${KERNEL_VER} ($OP_MODEL)"
