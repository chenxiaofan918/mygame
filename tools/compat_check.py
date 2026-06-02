#!/usr/bin/env python3
"""
compat_check — .sproto 协议兼容性检查工具

检查当前 .sproto 文件与存储的基线快照之间的差异，
确保协议更改是向后兼容的。

规则（破坏性变更 → 报错）:
  1. 删除协议或类型
  2. 修改协议标签号
  3. 删除字段
  4. 修改字段标签号
  5. 修改字段类型（如 integer → string）

非破坏性变更 → 仅提醒:
  1. 新增协议（新标签号）
  2. 新增类型
  3. 新增字段（新标签号）
  4. 字段或协议改名（标签不变则兼容）

用法:
  python tools/compat_check.py                # 检查兼容性
  python tools/compat_check.py --update        # 更新基线快照（确认变更后）
  python tools/compat_check.py --init          # 初始化基线快照
"""

import json
import os
import sys

# 复用 sprotogen 的解析器
sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from sprotogen import load_all_protocols

SNAPSHOT_FILE = os.path.join(os.path.dirname(__file__), "..", "proto", ".proto_snapshot.json")
PROTO_DIR = os.path.join(os.path.dirname(__file__), "..", "proto")


# ============================================================
#  快照序列化
# ============================================================

def build_snapshot_data(all_types, all_protos) -> dict:
    """将解析后的协议数据转为可序列化的 dict（用于快照）"""
    types_data = {}
    for tname in sorted(all_types.keys()):
        t = all_types[tname]
        fields = sorted(t.fields, key=lambda f: f.tag)
        types_data[tname] = {
            "fields": [
                {"name": f.name, "tag": f.tag, "type": f.type_name, "array": f.is_array}
                for f in fields
            ]
        }

    protos_data = {}
    sorted_protos = sorted(all_protos, key=lambda p: (p.direction, p.module, p.tag))
    for p in sorted_protos:
        req = sorted(p.request_fields, key=lambda f: f.tag)
        res = sorted(p.response_fields, key=lambda f: f.tag)
        protos_data[p.name] = {
            "tag": p.tag,
            "direction": p.direction,
            "module": p.module,
            "request": [
                {"name": f.name, "tag": f.tag, "type": f.type_name, "array": f.is_array}
                for f in req
            ],
            "response": [
                {"name": f.name, "tag": f.tag, "type": f.type_name, "array": f.is_array}
                for f in res
            ],
        }

    return {"types": types_data, "protocols": protos_data}


def save_snapshot(data: dict, path: str):
    """写入快照文件"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def load_snapshot(path: str) -> dict:
    """读取快照文件，不存在则返回空 dict"""
    if not os.path.isfile(path):
        return {}
    with open(path, encoding="utf-8") as f:
        return json.load(f)


# ============================================================
#  兼容性检查
# ============================================================

def check_compat(baseline: dict, current: dict) -> tuple:
    """
    比较 baseline 和 current，返回 (errors, warnings)。
    errors:   破坏性变更列表（必须修复）
    warnings: 非破坏性变更列表（仅提醒）
    """
    errors = []
    warnings = []

    base_types = baseline.get("types", {})
    cur_types = current.get("types", {})
    base_protos = baseline.get("protocols", {})
    cur_protos = current.get("protocols", {})

    # ---- 检查类型 ----
    for tname, tdata in base_types.items():
        if tname not in cur_types:
            errors.append(f"[BREAKING] 类型 '{tname}' 已被删除")
            continue

        cur_fields = {f["tag"]: f for f in cur_types[tname]["fields"]}
        base_fields = {f["tag"]: f for f in tdata["fields"]}

        for tag in sorted(base_fields.keys()):
            bf = base_fields[tag]
            if tag not in cur_fields:
                errors.append(
                    f"[BREAKING] 类型 '{tname}' 字段 '{bf['name']}' (tag={tag}) 已被删除"
                )
                continue

            cf = cur_fields[tag]
            if cf["type"] != bf["type"]:
                errors.append(
                    f"[BREAKING] 类型 '{tname}' 字段 '{bf['name']}' (tag={tag}) "
                    f"类型变更: {bf['type']} → {cf['type']}"
                )
            if cf["array"] != bf["array"]:
                errors.append(
                    f"[BREAKING] 类型 '{tname}' 字段 '{bf['name']}' (tag={tag}) "
                    f"数组标记变更: {bf['array']} → {cf['array']}"
                )

    # 新增类型（警告）
    for tname in cur_types:
        if tname not in base_types:
            # 检查是否为 .package 等系统类型
            if tname != "package":
                warnings.append(f"[NEW]     新增类型 '{tname}'")

    # ---- 检查协议 ----
    for pname, pdata in base_protos.items():
        if pname not in cur_protos:
            errors.append(f"[BREAKING] 协议 '{pname}' 已被删除")
            continue

        cp = cur_protos[pname]

        if cp["tag"] != pdata["tag"]:
            errors.append(
                f"[BREAKING] 协议 '{pname}' 标签号变更: {pdata['tag']} → {cp['tag']}"
            )
        if cp["direction"] != pdata["direction"]:
            errors.append(
                f"[BREAKING] 协议 '{pname}' 方向变更: {pdata['direction']} → {cp['direction']}"
            )

        # 检查 request 字段
        _check_fields(errors, warnings, pname, "request", pdata.get("request", []), cp.get("request", []))
        # 检查 response 字段
        _check_fields(errors, warnings, pname, "response", pdata.get("response", []), cp.get("response", []))

    # 新增协议（警告）
    for pname in cur_protos:
        if pname not in base_protos:
            warnings.append(f"[NEW]     新增协议 '{pname}' (tag={cur_protos[pname]['tag']})")

    return errors, warnings


def _check_fields(errors, warnings, pname: str, section: str, base_fields: list, cur_fields: list):
    """检查协议 request/response 中的字段兼容性"""
    base_by_tag = {f["tag"]: f for f in base_fields}
    cur_by_tag = {f["tag"]: f for f in cur_fields}

    for tag in sorted(base_by_tag.keys()):
        bf = base_by_tag[tag]
        if tag not in cur_by_tag:
            errors.append(
                f"[BREAKING] 协议 '{pname}/{section}' 字段 '{bf['name']}' (tag={tag}) 已被删除"
            )
            continue

        cf = cur_by_tag[tag]
        if cf["type"] != bf["type"]:
            errors.append(
                f"[BREAKING] 协议 '{pname}/{section}' 字段 '{bf['name']}' (tag={tag}) "
                f"类型变更: {bf['type']} → {cf['type']}"
            )
        if cf["array"] != bf["array"]:
            errors.append(
                f"[BREAKING] 协议 '{pname}/{section}' 字段 '{bf['name']}' (tag={tag}) "
                f"数组标记变更: {bf['array']} → {cf['array']}"
            )

    # 新增字段（警告）
    for tag in sorted(cur_by_tag.keys()):
        if tag not in base_by_tag:
            warnings.append(
                f"[NEW]     协议 '{pname}/{section}' 新增字段 "
                f"'{cur_by_tag[tag]['name']}' (tag={tag})"
            )


# ============================================================
#  主入口
# ============================================================

def main():
    args = sys.argv[1:]
    do_update = "--update" in args
    do_init = "--init" in args

    # 加载当前协议
    all_types, all_protos, modules, _, _ = load_all_protocols(PROTO_DIR)
    current = build_snapshot_data(all_types, all_protos)
    snapshot_path = os.path.abspath(SNAPSHOT_FILE)

    # --init: 初始化快照
    if do_init:
        save_snapshot(current, snapshot_path)
        print(f"[compat_check] 快照已初始化: {snapshot_path}")
        return

    # --update: 更新快照
    if do_update:
        save_snapshot(current, snapshot_path)
        print(f"[compat_check] 快照已更新: {snapshot_path}")
        return

    # 检查兼容性
    baseline = load_snapshot(snapshot_path)

    if not baseline:
        print(f"[compat_check] 未找到基线快照，请先运行:")
        print(f"  python tools/compat_check.py --init")
        sys.exit(1)

    errors, warnings = check_compat(baseline, current)

    print(f"[compat_check] 兼容性检查结果:")
    print(f"  类型: {len(baseline.get('types', {}))} → {len(current.get('types', {}))}")
    print(f"  协议: {len(baseline.get('protocols', {}))} → {len(current.get('protocols', {}))}")
    print()

    if warnings:
        print(f"--- 非破坏性变更 ({len(warnings)} 项) ---")
        for w in warnings:
            print(f"  {w}")
        print()

    if errors:
        print(f"--- 破坏性变更 ({len(errors)} 项) ---")
        for e in errors:
            print(f"  {e}")
        print()
        print("[compat_check] FAILED: 存在破坏性变更，请修复后再提交")
        sys.exit(1)
    else:
        print("[compat_check] OK: 兼容性检查通过")
        if warnings:
            print("  (非破坏性变更已在提醒中列出)")


if __name__ == "__main__":
    main()
