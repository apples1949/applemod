#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""还原上一步"禁用 readyup"的改动：取消我加的注释（只还原我加的那些）。
保护：若某行的注释形式在 HEAD 里本来就存在，则不动。"""
import os
import re
import subprocess

REPO = r"C:\Users\apples1949\Documents\applemod"
ROOT = os.path.join(REPO, "cfg")
MARK = " // 已禁用：readyup 暂不加载（下一步测试用），删掉行首 // 即可恢复"
LOAD_RE = re.compile(r"^//(sm plugins load\s+optional/another/readyup-applemod\.smx.*)$")
CVAR_RE = re.compile(r"^//((?:confogl_addcvar\s+)?(?:l4d_ready_\w+|l4d2_dlock_\w+).*)$")


def head_lines(relpath):
    try:
        out = subprocess.run(["git", "show", f"HEAD:{relpath}"], cwd=REPO,
                             capture_output=True, check=True).stdout.decode("utf-8", "replace")
        return [l.rstrip("\r\n") for l in out.splitlines()]
    except subprocess.CalledProcessError:
        return []


total = {}
for dirpath, _dirs, files in os.walk(ROOT):
    for fn in sorted(files):
        if not fn.endswith(".cfg"):
            continue
        path = os.path.join(dirpath, fn)
        rel = os.path.relpath(path, REPO).replace("\\", "/")
        head = set(h.strip() for h in head_lines(rel))

        with open(path, "r", encoding="utf-8", newline="") as f:
            lines = f.readlines()

        out, hits = [], 0
        for line in lines:
            body = line.rstrip("\r\n")
            eol = "\r\n" if line.endswith("\r\n") else "\n"
            new = None
            m = LOAD_RE.match(body)
            if m:
                new = m.group(1).replace(MARK, "").rstrip()
            else:
                m2 = CVAR_RE.match(body)
                if m2:
                    candidate = m2.group(1)
                    # 若 HEAD 里原本就是注释形式，说明不是我加的 → 不动
                    if ("//" + candidate) not in head and ("// " + candidate) not in head:
                        new = candidate
            if new is not None and new != body:
                body = new
                hits += 1
            out.append(body + eol)

        if hits:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.writelines(out)
            total[os.path.relpath(path, ROOT)] = hits

print("=== 还原统计（文件: 取消注释行数） ===")
for k in sorted(total):
    print(f"  {total[k]:>3}  {k}")
print(f"合计还原 {sum(total.values())} 行，涉及 {len(total)} 个文件")
