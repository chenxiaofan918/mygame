# sproto_parser.py — .sproto 文件解析器（纯 Python，无外部依赖）
"""
从 .sproto 文本中解析协议定义，供客户端编码/解码使用。

用法:
    parser = SprotoParser()
    parser.load_dir("../../proto")
    c2s, s2c = parser.build_protocols()
"""

import os
import re

# sproto 类型常量
T_INTEGER = 0
T_BOOLEAN = 1
T_STRING = 2
T_BINARY = 3  # 二进制数据，本项目未使用

TYPE_MAP = {
    "integer": T_INTEGER,
    "boolean": T_BOOLEAN,
    "string": T_STRING,
}

# 协议块正则: proto_name tag {
PROTO_RE = re.compile(r'^(\w+)\s+(\d+)\s*\{', re.MULTILINE)
# 类型块正则: .type_name {
TYPE_RE = re.compile(r'^\.(\w+)\s*\{', re.MULTILINE)
# 字段定义: name tag : type 或 name tag : *array_type
FIELD_RE = re.compile(r'^\s*(\w+)\s+(\d+)\s*:\s*(\*?)(\w+)', re.MULTILINE)


def _parse_fields(block_text):
    """从块文本中提取字段列表"""
    fields = []
    for m in FIELD_RE.finditer(block_text):
        name = m.group(1)
        tag = int(m.group(2))
        is_array = bool(m.group(3))
        type_name = m.group(4)
        ftype = TYPE_MAP.get(type_name)
        if ftype is None:
            # 引用类型（如 *item_entry），当作 string 处理
            ftype = T_STRING
        fields.append((tag, ftype, name, is_array, type_name))
    # 按 tag 排序
    fields.sort(key=lambda x: x[0])
    return fields


def _extract_block(text, start_pos):
    """从 start_pos 开始提取匹配的花括号块 { ... }
    start_pos 应为 opening brace 之后的位置（m.end() 已在 { 之后）
    返回: (block_content, end_pos) 或 (None, start_pos)
    """
    depth = 1
    i = start_pos
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start_pos:i], i + 1
        i += 1
    return None, start_pos


class SprotoParser:
    """.sproto 文件解析器"""

    def __init__(self):
        self.protocols = {}   # name -> {tag, request, response}
        self.types = {}       # name -> fields

    def load_file(self, filepath):
        """解析单个 .sproto 文件"""
        with open(filepath, encoding="utf-8") as f:
            text = f.read()

        # 去除注释
        text = re.sub(r'#.*', '', text)

        # 提取类型定义
        for m in TYPE_RE.finditer(text):
            type_name = m.group(1)
            content, _ = _extract_block(text, m.end())
            if content:
                self.types[type_name] = _parse_fields(content)

        # 提取协议定义
        for m in PROTO_RE.finditer(text):
            proto_name = m.group(1)
            proto_tag = int(m.group(2))
            content, _ = _extract_block(text, m.end())
            if content is None:
                self.protocols[proto_name] = {"tag": proto_tag, "request": [], "response": []}
                continue

            # 检查是否有 request/response 子块
            req_match = re.search(r'\brequest\s*\{', content)
            resp_match = re.search(r'\bresponse\s*\{', content)

            if not req_match and not resp_match:
                # 没有子块（如 ping {}）
                self.protocols[proto_name] = {"tag": proto_tag, "request": [], "response": []}
            else:
                proto = {"tag": proto_tag, "request": [], "response": [],
                         "has_request": req_match is not None, "has_response": resp_match is not None}
                if req_match:
                    req_content, _ = _extract_block(content, req_match.end())
                    if req_content:
                        proto["request"] = _parse_fields(req_content)
                if resp_match:
                    resp_content, _ = _extract_block(content, resp_match.end())
                    if resp_content:
                        proto["response"] = _parse_fields(resp_content)
                self.protocols[proto_name] = proto

    def load_dir(self, dirpath):
        """解析目录下所有 .sproto 文件"""
        for fname in sorted(os.listdir(dirpath)):
            if fname.endswith(".sproto"):
                self.load_file(os.path.join(dirpath, fname))

    def build_c2s(self):
        """返回 {name: {tag, request, response}} — 所有包含 request 的协议"""
        return {n: p for n, p in self.protocols.items() if p.get("has_request") or n in ("ping",)}

    def build_s2c(self):
        """返回 {name: {tag, request, response}} — 所有只有 response 的协议（服务端推送）"""
        return {n: p for n, p in self.protocols.items() if p.get("has_response") and not p.get("has_request")}

    def build_protocols(self):
        """返回 (c2s, s2c) 两个名字典"""
        return self.build_c2s(), self.build_s2c()
