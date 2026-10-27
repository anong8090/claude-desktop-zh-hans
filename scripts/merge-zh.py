#!/usr/bin/env python3
"""
把多份中文语言包合并成一份，并做 ICU 占位符校验。

场景：Claude 更新后，en-US.json 里出现新 key，你手上的 zh-Hans.json 是旧版；
或者你想把「官方包」和「社区包」取并集，让中文化覆盖率尽量高。

用法：
  ./scripts/merge-zh.py --base packs/zh-Hans.json \
                        --extra other.json \
                        --en /Applications/Claude.app/Contents/Resources/ion-dist/i18n/en-US.json \
                        --out packs/zh-Hans.merged.json

规则（逐 key）：
  1. 按 --base、--extra 的先后顺序取第一个「非空、且不等于英文原文」的译文
  2. 校验 ICU 顶层参数名集合与英文一致；不一致则视为不安全，回退英文
     （不能只比花括号：中文把 {n, plural, one{...} other{...}} 简化成 {n} 个
      是合法的，顺序和重复引用也不影响）
  3. 英文里有、所有中文包都没有的 key，按英文原样写入（保证 key 覆盖 100%，
     前端不会因为缺 key 报错）

已知的坑：
  - 只比原始花括号会把大量合法译文误判为异常
  - 参数名写错（{count} -> {mount}）会在运行时抛 ICU 解析错误，必须拦
"""

import argparse
import json
import os
import re
import sys


def top_level_args(msg):
    """取出 ICU MessageFormat 里**顶层**占位符的参数名。

    {count, plural, one{1 item} other{# items}}  ->  {'count'}
    {status, select, revoked {Reconnect} other {Connect}}  ->  {'status'}
    {a} 和 {b} 各算一个。

    必须按花括号深度扫描，不能用正则直接抓 {xxx}：
    plural / select 的分支内容也在花括号里，正则会把 {Reconnect}、{字符}
    当成参数名，于是中英两边"参数集合"必然不等，把大量合法译文误判成异常。
    """
    names, depth, i, n = [], 0, 0, len(msg)
    first_char = re.compile(r"[A-Za-z_]")
    while i < n:
        ch = msg[i]
        if ch == "{":
            if depth == 0:
                j = i + 1
                while j < n and msg[j] in " \t":
                    j += 1
                if j < n and first_char.match(msg[j]):
                    k = j
                    while k < n and (msg[k].isalnum() or msg[k] == "_"):
                        k += 1
                    names.append(msg[j:k])
                depth = 1
                i += 1
                continue
            depth += 1
        elif ch == "}":
            depth = max(0, depth - 1)
        i += 1
    return sorted(set(names))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--en", required=True, help="en-US.json 路径（基准，决定 key 集合）")
    ap.add_argument("--base", required=True, help="主语言包")
    ap.add_argument("--extra", action="append", default=[],
                    help="备用语言包，可多次指定，按顺序补缺")
    ap.add_argument("--out", required=True, help="输出路径")
    ap.add_argument("--prune-obsolete", action="store_true",
                    help="丢弃基准 en-US 里已不存在的 key（默认保留：无害，且跨版本更稳）")
    args = ap.parse_args()

    en = json.load(open(args.en, encoding="utf-8"))
    packs = []
    for p in [args.base] + args.extra:
        if not os.path.exists(p):
            print(f"[WARN] 跳过不存在的 {p}")
            continue
        d = json.load(open(p, encoding="utf-8"))
        packs.append((p, d))
        print(f"载入 {p}: {len(d)} 条")

    out = {}
    from_official = 0
    from_english = 0
    reverted = []

    for k, ev in en.items():
        picked = None
        for src, d in packs:
            v = d.get(k)
            if not isinstance(v, str) or not v.strip():
                continue
            if v == ev:                       # 值本身就是英文，等于没翻
                continue
            if top_level_args(v) != top_level_args(ev):
                reverted.append((k, src, ev, v))
                continue
            picked = v
            break
        if picked is None:
            out[k] = ev
            from_english += 1
        else:
            out[k] = picked
            from_official += 1

    obsolete = 0
    if not args.prune_obsolete:
        for src, d in packs:
            for k, v in d.items():
                if k not in en and k not in out:
                    out[k] = v
                    obsolete += 1

    total = len(en)
    translated = total - from_english
    pct = 100.0 * translated / total if total else 0.0

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    json.dump(out, open(args.out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

    print()
    print(f"en-US key 总数      : {total}")
    print(f"取到中文译文        : {from_official}")
    print(f"仍为英文原样        : {from_english}")
    print(f"占位符不安全被回退  : {len(reverted)}")
    if obsolete:
        print(f"保留的已废弃 key    : {obsolete}  （当前版本用不到，跨版本更稳）")
    print(f"输出 key 总数       : {len(out)}")
    print(f"实际中文化          : {pct:.2f}%")
    print(f"已写入              : {args.out} ({os.path.getsize(args.out)} bytes)")

    if reverted:
        print()
        print("以下 key 的译文占位符与英文不一致，已回退英文（会导致运行时缺参，不要硬上）：")
        for k, src, ev, v in reverted[:20]:
            print(f"  {k}")
            print(f"    en : {ev[:90]}")
            print(f"    zh : {v[:90]}   [{os.path.basename(src)}]")

    if pct < 99.0:
        print()
        print(f"覆盖率低于 99%：{from_english} 条没有可用中文译文")
        print("  - 属于 App 新版本新增文案 -> 需要更新语言包（重跑 extract-zh-pack.sh）")
        print("  - 或官方本身就没译（如产品名 Artifacts / Cowork）-> 正常，忽略")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
