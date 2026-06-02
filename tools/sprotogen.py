#!/usr/bin/env python3
"""
sprotogen — .sproto 协议代码生成器

基于 proto/*.sproto 生成各语言协议代码:

  --lang lua (默认)  → server/module/proto_stub.lua
  --lang cs          → client/unity/Assets/Scripts/Proto/Protocol.cs
  --lang ts          → client/cocos/assets/scripts/proto/protocol.ts

用法:
  python tools/sprotogen.py                     # Lua (默认)
  python tools/sprotogen.py --lang cs           # C# (Unity)
  python tools/sprotogen.py --lang ts           # TypeScript (Cocos Creator)
  python tools/sprotogen.py --all               # 全部语言
  python tools/sprotogen.py --lang cs --out <path>  # 指定输出路径
"""

import hashlib
import json
import os
import re
import sys
from collections import OrderedDict


# ============================================================
#  数据结构
# ============================================================

class Field:
    """sproto 字段定义"""
    def __init__(self, name: str, tag: int, type_name: str, is_array: bool):
        self.name = name
        self.tag = tag
        self.type_name = type_name      # "integer" | "string" | "boolean" | 自定义类型名
        self.is_array = is_array        # 以 * 前缀标记

    def cs_type(self) -> str:
        """映射到 C# 类型"""
        base = {"integer": "int", "string": "string", "boolean": "bool"} \
            .get(self.type_name, to_pascal(self.type_name))
        return f"List<{base}>" if self.is_array else base

    def ts_type(self) -> str:
        """映射到 TypeScript 类型"""
        base = {"integer": "number", "string": "string", "boolean": "boolean"} \
            .get(self.type_name, to_pascal(self.type_name))
        return f"{base}[]" if self.is_array else base

    def is_custom_type(self) -> bool:
        """是否是自定义类型（非基本类型）"""
        return self.type_name not in ("integer", "string", "boolean")


class TypeDef:
    """sproto 类型定义（如 .item_entry）"""
    def __init__(self, name: str, fields: list):
        self.name = name
        self.fields = fields

    @property
    def pascal_name(self) -> str:
        return to_pascal(self.name)


class Protocol:
    """sproto 协议定义（如 bag_list 30）"""
    def __init__(self, name: str, tag: int, direction: str, module: str,
                 request_fields: list, response_fields: list):
        self.name = name
        self.tag = tag
        self.direction = direction  # "c2s" | "s2c"
        self.module = module
        self.request_fields = request_fields
        self.response_fields = response_fields

    @property
    def pascal_name(self) -> str:
        return to_pascal(self.name)

    @property
    def has_request(self) -> bool:
        return bool(self.request_fields)

    @property
    def has_response(self) -> bool:
        return bool(self.response_fields)

    @property
    def upper_name(self) -> str:
        return self.name.upper()


# ============================================================
#  名称工具
# ============================================================

def to_pascal(snake: str) -> str:
    """snake_case → PascalCase"""
    return "".join(word.capitalize() for word in snake.split("_"))


def to_camel(snake: str) -> str:
    """snake_case → camelCase"""
    words = snake.split("_")
    return words[0] + "".join(w.capitalize() for w in words[1:])


# ============================================================
#  .sproto 解析器
# ============================================================

# 字段正则: name tag : [*]type
FIELD_RE = re.compile(r'^(\w+)\s+(\d+)\s*:\s*(\*?)(\w+)\s*$')


def parse_fields_from_block(lines, start, end):
    """从行列表的 [start, end) 区间解析字段列表"""
    fields = []
    for i in range(start, end):
        line = lines[i].strip()
        if not line or line.startswith("#"):
            continue
        m = FIELD_RE.match(line)
        if m:
            fields.append(Field(
                name=m.group(1),
                tag=int(m.group(2)),
                type_name=m.group(4),
                is_array=bool(m.group(3)),
            ))
    return fields


def parse_sproto_full(filepath: str) -> tuple:
    """
    解析一个 .sproto 文件，返回 (types_in_file, protos_in_file)。

    参数:
      filepath: 文件路径

    返回:
      types_in_file: list[TypeDef]   — 该文件中定义的类型
      protos_in_file: list[Protocol] — 该文件中定义的协议
    """
    with open(filepath, encoding="utf-8") as f:
        text = f.read()

    types = []
    protos = []

    # 按行分割，保留原始缩进
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        stripped = raw.strip()

        # 跳过空行和注释
        if not stripped or stripped.startswith("#"):
            i += 1
            continue

        # ---------- 类型定义: .type_name { ----------
        if stripped.startswith(".") and stripped.endswith("{"):
            type_name = stripped[1:-1].strip()
            i += 1
            depth = 1
            field_start = i
            while i < len(lines) and depth > 0:
                s = lines[i].strip()
                if s.endswith("{"):
                    depth += 1
                elif s == "}":
                    depth -= 1
                i += 1
            types.append(TypeDef(
                name=type_name,
                fields=parse_fields_from_block(lines, field_start, i - 1),
            ))
            continue

        # ---------- 协议定义 ----------
        # 空协议: ping 4 {}  (单行无字段)
        if re.match(r'^\w+\s+\d+\s*\{\}\s*$', stripped):
            m = re.match(r'^(\w+)\s+(\d+)', stripped)
            protos.append(Protocol(
                name=m.group(1), tag=int(m.group(2)),
                direction="", module="",
                request_fields=[], response_fields=[],
            ))
            i += 1
            continue

        # 正常协议: name tag { (可能在同一行包含 request/response)
        m = re.match(r'^(\w+)\s+(\d+)\s*\{?\s*$', stripped)
        if m:
            proto_name = m.group(1)
            proto_tag = int(m.group(2))
            i += 1
            depth = 1
            request_fields = []
            response_fields = []
            current_section = None  # "request" | "response" | None
            section_start = None

            while i < len(lines) and depth > 0:
                s = lines[i].strip()

                # 区块开始: request / request { / request {}
                if s.startswith("request"):
                    if current_section is not None and section_start is not None:
                        fields = parse_fields_from_block(lines, section_start, i)
                        (request_fields if current_section == "request" else response_fields).extend(fields)
                    current_section = "request"
                    section_start = None
                    if s.endswith("{}"):
                        current_section = None  # 空区块，无字段
                    else:
                        depth += 1  # 跟踪 { 的嵌套层级
                    i += 1
                    continue

                # 区块开始: response / response { / response {}
                if s.startswith("response"):
                    if current_section is not None and section_start is not None:
                        fields = parse_fields_from_block(lines, section_start, i)
                        (request_fields if current_section == "request" else response_fields).extend(fields)
                    current_section = "response"
                    section_start = None
                    if s.endswith("{}"):
                        current_section = None
                    else:
                        depth += 1
                    i += 1
                    continue

                # 结束当前区块或协议
                if s == "}":
                    if current_section is not None and section_start is not None:
                        fields = parse_fields_from_block(lines, section_start, i)
                        (request_fields if current_section == "request" else response_fields).extend(fields)
                    current_section = None
                    section_start = None
                    depth -= 1
                    i += 1
                    continue

                # 区块内首行字段（延迟标记起始行）
                if current_section is not None and section_start is None and s != "" and not s.startswith("#"):
                    section_start = i

                i += 1

            # 记录协议
            # 方向在外部调用时根据文件名确定
            protos.append(Protocol(
                name=proto_name,
                tag=proto_tag,
                direction="",  # 调用者设置
                module="",     # 调用者设置
                request_fields=request_fields,
                response_fields=response_fields,
            ))
            continue

        i += 1

    return types, protos


# ============================================================
#  协议加载器（组装所有文件）
# ============================================================

def load_all_protocols(proto_dir: str) -> tuple:
    """
    加载 proto_dir 下所有 .sproto 文件，返回:
      all_types: OrderedDict[name → TypeDef]
      all_protos: list[Protocol] (已填充 direction 和 module)
      modules: OrderedDict[module → {c2s, s2c}]
      c2s_map: OrderedDict[name → tag]
      s2c_map: OrderedDict[name → tag]
    """
    all_types = OrderedDict()   # name → TypeDef
    all_protos = []
    modules = OrderedDict()
    c2s_map = OrderedDict()
    s2c_map = OrderedDict()

    for fname in sorted(os.listdir(proto_dir)):
        if not fname.endswith(".sproto"):
            continue

        # 方向
        if "_c2s.sproto" in fname:
            direction = "c2s"
        elif "_s2c.sproto" in fname:
            direction = "s2c"
        else:
            direction = "public"

        # 模块名
        mod = fname.replace("_c2s.sproto", "").replace("_s2c.sproto", "").replace("_public.sproto", "").replace(".sproto", "")

        fpath = os.path.join(proto_dir, fname)
        types, protos = parse_sproto_full(fpath)

        # 收集类型
        for t in types:
            if t.name not in all_types:
                all_types[t.name] = t

        # 收集协议
        if direction in ("c2s", "s2c"):
            modules.setdefault(mod, {"c2s": [], "s2c": []})
            for p in protos:
                p.direction = direction
                p.module = mod
                all_protos.append(p)
                target_map = c2s_map if direction == "c2s" else s2c_map
                target_map[p.name] = p.tag
                modules[mod][direction].append((p.name, p.tag))

    return all_types, all_protos, modules, c2s_map, s2c_map


# ============================================================
#  协议指纹（版本哈希）
# ============================================================

def compute_proto_hash(all_types: dict, all_protos: list) -> str:
    """
    从所有类型和协议定义生成确定的 SHA-256 指纹。
    相同的协议定义 → 相同的哈希值，可用于运行时版本校验。
    """
    data = OrderedDict()
    data["types"] = OrderedDict()
    data["protocols"] = OrderedDict()

    for tname in sorted(all_types.keys()):
        t = all_types[tname]
        fields = sorted(t.fields, key=lambda f: f.tag)
        data["types"][tname] = [
            OrderedDict([("name", f.name), ("tag", f.tag), ("type", f.type_name), ("array", f.is_array)])
            for f in fields
        ]

    sorted_protos = sorted(all_protos, key=lambda p: (p.direction, p.module, p.tag))
    for p in sorted_protos:
        req = sorted(p.request_fields, key=lambda f: f.tag)
        res = sorted(p.response_fields, key=lambda f: f.tag)
        data["protocols"][p.name] = OrderedDict([
            ("tag", p.tag),
            ("direction", p.direction),
            ("module", p.module),
            ("request", [OrderedDict([("name", f.name), ("tag", f.tag), ("type", f.type_name), ("array", f.is_array)]) for f in req]),
            ("response", [OrderedDict([("name", f.name), ("tag", f.tag), ("type", f.type_name), ("array", f.is_array)]) for f in res]),
        ])

    canonical = json.dumps(data, separators=(",", ":"), ensure_ascii=True, sort_keys=True)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


# ============================================================
#  代码生成器 — Lua
# ============================================================

def gen_lua(modules, c2s_map, s2c_map, output_path, proto_hash=""):
    """生成 proto_stub.lua"""
    lines = []
    lines.append("-- auto-generated by tools/sprotogen.py -- do not edit")
    lines.append("")
    lines.append("local M = {}")
    lines.append("")
    if proto_hash:
        lines.append(f'M._PROTO_HASH = "{proto_hash}"')
        lines.append("")

    # c2s 常量
    c2s_protos_by_module = OrderedDict()
    for mod, dirs in modules.items():
        for name, tag in dirs.get("c2s", []):
            c2s_protos_by_module.setdefault(mod, []).append((name, tag))

    if c2s_protos_by_module:
        lines.append("-- ======== c2s Protocol Tags ========")
        for mod, protos in c2s_protos_by_module.items():
            if protos:
                lines.append("-- " + mod)
                for name, tag in protos:
                    lines.append(f"M.{name.upper()} = {tag}")
                lines.append("")

    # s2c 常量
    s2c_protos_by_module = OrderedDict()
    for mod, dirs in modules.items():
        for name, tag in dirs.get("s2c", []):
            s2c_protos_by_module.setdefault(mod, []).append((name, tag))

    if s2c_protos_by_module:
        lines.append("-- ======== s2c Protocol Tags ========")
        for mod, protos in s2c_protos_by_module.items():
            if protos:
                lines.append("-- " + mod)
                for name, tag in protos:
                    lines.append(f"M.{name.upper()} = {tag}")
                lines.append("")

    # name → tag 映射
    lines.append("-- ======== Name ↔ Tag Mapping ========")
    lines.append("local name_to_tag = {}")
    for mod, dirs in modules.items():
        for direction in ("c2s", "s2c"):
            for name, tag in dirs.get(direction, []):
                lines.append(f"name_to_tag[\"{name}\"] = {tag}")
    lines.append("M._name_to_tag = name_to_tag")
    lines.append("")

    # 处理器注册
    lines.append("-- ======== Handler Registry ========")
    lines.append("local handlers = {}")
    lines.append("")
    lines.append("function M.register(name, fn)")
    lines.append('    assert(type(name) == "string" and type(fn) == "function",')
    lines.append('        "proto.register: expected (string, function)")')
    lines.append("    handlers[name] = fn")
    lines.append("end")
    lines.append("")
    lines.append("function M.register_module(module_name, handler_table)")
    lines.append('    assert(type(handler_table) == "table",')
    lines.append('        "proto.register_module: expected table of handlers")')
    lines.append("    for name, fn in pairs(handler_table) do")
    lines.append('        assert(type(fn) == "function",')
    lines.append('            string.format("proto.register_module: handler \'%s\' must be a function", name))')
    lines.append("        handlers[name] = fn")
    lines.append("    end")
    lines.append("end")
    lines.append("")
    lines.append("function M.dispatch(name, ctx, ...)")
    lines.append("    local fn = handlers[name]")
    lines.append("    if fn then")
    lines.append("        return fn(ctx, ...)")
    lines.append("    end")
    lines.append('    return nil, "unknown protocol: " .. tostring(name)')
    lines.append("end")
    lines.append("")
    lines.append("function M.has_handler(name)")
    lines.append("    return handlers[name] ~= nil")
    lines.append("end")
    lines.append("")
    lines.append("return M")
    lines.append("")

    write_output(output_path, "\n".join(lines))
    print(f"[sprotogen] generated {output_path}")


# ============================================================
#  代码生成器 — C# (Unity)
# ============================================================

def gen_csharp(all_types, all_protos, modules, output_path, proto_hash=""):
    """生成 Protocol.cs"""
    lines = []
    lines.append("// auto-generated by tools/sprotogen.py -- do not edit")
    lines.append("namespace Game.Protocol")
    lines.append("{")

    # ---------- 协议指纹 ----------
    if proto_hash:
        lines.append("    /// <summary>")
        lines.append("    /// 协议指纹 SHA-256（用于运行时版本校验）")
        lines.append("    /// </summary>")
        lines.append(f'    public const string ProtoHash = "{proto_hash}";')
        lines.append("")

    # ---------- 协议常量 ----------
    lines.append("    /// <summary>")
    lines.append("    /// 协议标签常量")
    lines.append("    /// </summary>")
    lines.append("    public static class ProtoTag")
    lines.append("    {")

    by_module = OrderedDict()
    for mod, dirs in modules.items():
        by_module.setdefault(mod, OrderedDict())
        for direction in ("c2s", "s2c"):
            for name, tag in dirs.get(direction, []):
                by_module[mod][name.upper()] = tag

    for mod, tags in by_module.items():
        if tags:
            lines.append(f"        // {mod}")
            for name, tag in tags.items():
                lines.append(f"        public const int {name} = {tag};")
            lines.append("")

    lines.append("    }")
    lines.append("")

    # ---------- 类型定义 ----------
    if all_types:
        lines.append("    // ======== 共享类型 ========")
        for t in all_types.values():
            if not t.fields:
                continue
            lines.append("")
            lines.append("    [System.Serializable]")
            lines.append(f"    public class {t.pascal_name}")
            lines.append("    {")
            for f in t.fields:
                summary = _cs_field_summary(f)
                if summary:
                    lines.append(f"        /// <summary>{summary}</summary>")
                lines.append(f"        public {f.cs_type()} {f.name};")
            lines.append("    }")

    # ---------- 请求/响应类型 ----------
    c2s_protos = [p for p in all_protos if p.direction == "c2s"]
    s2c_protos = [p for p in all_protos if p.direction == "s2c"]

    if c2s_protos:
        lines.append("")
        lines.append("    // ======== C2S 请求/响应类型 ========")
        for p in c2s_protos:
            _gen_cs_proto_class(lines, p)

    if s2c_protos:
        lines.append("")
        lines.append("    // ======== S2C 推送类型 ========")
        for p in s2c_protos:
            _gen_cs_proto_class(lines, p)

    lines.append("}")
    lines.append("")

    write_output(output_path, "\n".join(lines))
    print(f"[sprotogen] generated {output_path}")


def _cs_field_summary(f: Field) -> str:
    """生成 C# 字段注释"""
    arr = "[]" if f.is_array else ""
    return f"tag={f.tag}, type={f.type_name}{arr}"


def _gen_cs_proto_class(lines, p: Protocol):
    """生成单个协议的 C# 请求/响应类"""
    if not p.has_request and not p.has_response:
        return

    lines.append("")
    lines.append(f"    /// <summary>tag={p.tag}, direction={p.direction}</summary>")
    pclass = p.pascal_name

    if p.has_request:
        lines.append(f"    [System.Serializable]")
        lines.append(f"    public class {pclass}Request")
        lines.append("    {")
        for f in p.request_fields:
            lines.append(f"        /// <summary>{_cs_field_summary(f)}</summary>")
            lines.append(f"        public {f.cs_type()} {f.name};")
        lines.append("    }")
        lines.append("")

    if p.has_response:
        lines.append(f"    [System.Serializable]")
        lines.append(f"    public class {pclass}Response")
        lines.append("    {")
        for f in p.response_fields:
            lines.append(f"        /// <summary>{_cs_field_summary(f)}</summary>")
            lines.append(f"        public {f.cs_type()} {f.name};")
        lines.append("    }")


# ============================================================
#  代码生成器 — TypeScript (Cocos Creator)
# ============================================================

def gen_typescript(all_types, all_protos, modules, output_path, proto_hash=""):
    """生成 protocol.ts"""
    lines = []
    lines.append("// auto-generated by tools/sprotogen.py -- do not edit")
    lines.append("")

    # ---------- 协议指纹 ----------
    if proto_hash:
        lines.append(f'export const PROTO_HASH = "{proto_hash}";')
        lines.append("")

    # ---------- 协议常量 ----------
    lines.append("// ======== Protocol Tag Constants ========")
    lines.append("export const enum ProtoTag {")

    by_module = OrderedDict()
    for mod, dirs in modules.items():
        by_module.setdefault(mod, OrderedDict())
        for direction in ("c2s", "s2c"):
            for name, tag in dirs.get(direction, []):
                by_module[mod][name.upper()] = tag

    for mod, tags in by_module.items():
        if tags:
            lines.append(f"    // {mod}")
            for name, tag in tags.items():
                lines.append(f"    {name} = {tag},")
            lines.append("")

    lines.append("}")
    lines.append("")

    # ---------- 类型定义 ----------
    if all_types:
        lines.append("// ======== Shared Types ========")
        for t in all_types.values():
            if not t.fields:
                continue
            lines.append("")
            lines.append(f"export interface {t.pascal_name}")
            lines.append("{")
            for f in t.fields:
                lines.append(f"    {f.name}: {f.ts_type()};")
            lines.append("}")
        lines.append("")

    # ---------- 请求/响应接口 ----------
    c2s_protos = [p for p in all_protos if p.direction == "c2s"]
    s2c_protos = [p for p in all_protos if p.direction == "s2c"]

    if c2s_protos:
        lines.append("// ======== C2S Request/Response ========")
        for p in c2s_protos:
            _gen_ts_interfaces(lines, p)

    if s2c_protos:
        lines.append("")
        lines.append("// ======== S2C Push ========")
        for p in s2c_protos:
            _gen_ts_interfaces(lines, p)

    write_output(output_path, "\n".join(lines))
    print(f"[sprotogen] generated {output_path}")


def _gen_ts_interfaces(lines, p: Protocol):
    """生成单个协议的 TS 接口"""
    if not p.has_request and not p.has_response:
        return

    lines.append("")
    lines.append(f"// {p.name} (tag={p.tag}, {p.direction})")

    if p.has_request:
        lines.append(f"export interface {p.pascal_name}Request")
        lines.append("{")
        for f in p.request_fields:
            lines.append(f"    {f.name}: {f.ts_type()};")
        lines.append("}")
        lines.append("")

    if p.has_response:
        lines.append(f"export interface {p.pascal_name}Response")
        lines.append("{")
        for f in p.response_fields:
            lines.append(f"    {f.name}: {f.ts_type()};")
        lines.append("}")


# ============================================================
#  代码生成器 — Markdown 文档
# ============================================================

def gen_doc(all_types, all_protos, modules, output_path, proto_hash=""):
    """生成 docs/protocol.md"""
    lines = []
    lines.append("# 通讯协议文档")
    lines.append("")
    lines.append(f"> 自动生成 by `tools/sprotogen.py`  |  SHA-256: `{proto_hash[:16]}...`")
    lines.append("")
    lines.append("## 目录")
    lines.append("")

    for mod in modules:
        lines.append(f"- [{mod}](#{mod})")
    lines.append("")

    if all_types:
        lines.append("---")
        lines.append("## 共享类型")
        lines.append("")
        for t in all_types.values():
            if not t.fields:
                continue
            lines.append(f"### `{t.name}`")
            lines.append("")
            lines.append("| 字段 | Tag | 类型 | 数组 |")
            lines.append("|------|-----|------|------|")
            for f in t.fields:
                arr = "是" if f.is_array else ""
                lines.append(f"| {f.name} | {f.tag} | `{f.type_name}` | {arr} |")
            lines.append("")

    for mod in modules:
        mod_c2s = [p for p in all_protos if p.module == mod and p.direction == "c2s"]
        mod_s2c = [p for p in all_protos if p.module == mod and p.direction == "s2c"]
        if not mod_c2s and not mod_s2c:
            continue
        lines.append("---")
        lines.append(f"## {mod}")
        lines.append("")
        if mod_c2s:
            lines.append("### C2S（客户端请求）")
            lines.append("")
            for p in mod_c2s:
                _gen_doc_proto(lines, p)
        if mod_s2c:
            lines.append("### S2C（服务端推送）")
            lines.append("")
            for p in mod_s2c:
                _gen_doc_proto(lines, p)

    lines.append("")
    write_output(output_path, "\n".join(lines))
    print(f"[sprotogen] generated {output_path}")


def _gen_doc_proto(lines, p: Protocol):
    """生成单个协议的文档段落"""
    lines.append(f"#### `{p.name}` (tag={p.tag})")
    lines.append("")
    if p.has_request:
        lines.append("**请求:**")
        lines.append("")
        lines.append("| 字段 | Tag | 类型 | 数组 |")
        lines.append("|------|-----|------|------|")
        for f in p.request_fields:
            arr = "是" if f.is_array else ""
            lines.append(f"| {f.name} | {f.tag} | `{f.type_name}` | {arr} |")
        lines.append("")
    if p.has_response:
        lines.append("**响应:**")
        lines.append("")
        lines.append("| 字段 | Tag | 类型 | 数组 |")
        lines.append("|------|-----|------|------|")
        for f in p.response_fields:
            arr = "是" if f.is_array else ""
            lines.append(f"| {f.name} | {f.tag} | `{f.type_name}` | {arr} |")
        lines.append("")


# ============================================================
#  输出工具
# ============================================================

def write_output(path: str, content: str):
    """确保目录存在并写入文件"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


# ============================================================
#  主入口
# ============================================================

def main():
    PROTO_DIR = os.path.join(os.path.dirname(__file__), "..", "proto")

    # 默认输出路径
    OUTPUTS = {
        "lua": os.path.join(os.path.dirname(__file__), "..", "server", "module", "proto_stub.lua"),
        "cs":  os.path.join(os.path.dirname(__file__), "..", "client", "unity", "Assets", "Scripts", "Proto", "Protocol.cs"),
        "ts":  os.path.join(os.path.dirname(__file__), "..", "client", "cocos", "assets", "scripts", "proto", "protocol.ts"),
        "doc": os.path.join(os.path.dirname(__file__), "..", "docs", "protocol.md"),
    }

    # 解析命令行参数
    target_langs = set()
    output_overrides = {}
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--lang":
            i += 1
            target_langs.add(args[i])
        elif args[i] == "--out":
            i += 1
            output_overrides["current"] = args[i]
        elif args[i] == "--all":
            target_langs = {"lua", "cs", "ts", "doc"}
        elif args[i].startswith("--out:"):
            key = args[i][6:]
            i += 1
            output_overrides[key] = args[i]
        else:
            print(f"Unknown option: {args[i]}")
            sys.exit(1)
        i += 1

    if not target_langs:
        target_langs = {"lua"}

    # 加载所有协议
    all_types, all_protos, modules, c2s_map, s2c_map = load_all_protocols(PROTO_DIR)

    if not all_protos and not all_types:
        print(f"[sprotogen] WARNING: no protocols found in {PROTO_DIR}")
        sys.exit(1)

    # 输出统计
    c2c = len([p for p in all_protos if p.direction == "c2s"])
    s2c = len([p for p in all_protos if p.direction == "s2c"])
    print(f"[sprotogen] parsed {len(all_types)} types, {c2c} c2s + {s2c} s2c = {len(all_protos)} protocols")

    # 计算协议指纹
    proto_hash = compute_proto_hash(all_types, all_protos)
    print(f"[sprotogen] proto hash: {proto_hash[:16]}...")

    # 生成代码
    for lang in target_langs:
        out_path = output_overrides.get(lang, output_overrides.get("current", OUTPUTS.get(lang)))
        if not out_path:
            print(f"[sprotogen] ERROR: unknown output path for --lang {lang}")
            sys.exit(1)

        if lang == "lua":
            gen_lua(modules, c2s_map, s2c_map, out_path, proto_hash)
        elif lang == "cs":
            gen_csharp(all_types, all_protos, modules, out_path, proto_hash)
        elif lang == "ts":
            gen_typescript(all_types, all_protos, modules, out_path, proto_hash)
        elif lang == "doc":
            gen_doc(all_types, all_protos, modules, out_path, proto_hash)
        else:
            print(f"[sprotogen] ERROR: unsupported language: {lang}")
            sys.exit(1)

    print("[sprotogen] all done")


if __name__ == "__main__":
    main()
