#!/usr/bin/env python3
"""
sproto 协议测试客户端（纯 Python 实现）
自动从 .sproto 文件加载协议定义，支持所有已定义协议。

用法: python sproto_client.py [host] [port]
"""

import json
import socket
import struct
import sys
import threading
import time
from pathlib import Path

from sproto_parser import SprotoParser, T_INTEGER, T_BOOLEAN, T_STRING

# ======== 加载协议定义 ========
PROTO_DIR = str(Path(__file__).resolve().parent / "../../proto")
_parser = SprotoParser()
_parser.load_dir(PROTO_DIR)
C2S_PROTO = _parser.build_c2s()
S2C_PROTO = _parser.build_s2c()

# tag -> name 映射
C2S_BY_TAG = {v["tag"]: k for k, v in C2S_PROTO.items()}
S2C_BY_TAG = {v["tag"]: k for k, v in S2C_PROTO.items()}
# s2c 协议也加入 C2S_BY_TAG（服务器推送）
for k, v in S2C_PROTO.items():
    C2S_BY_TAG[v["tag"]] = k

# 类型定义查询（供嵌套结构体解码用）
SPROTO_TYPES = _parser.types

# ======== sproto 编解码 ========

PKG_FIELDS = [
    (0, T_INTEGER, "type", False, ""),
    (1, T_INTEGER, "session", False, ""),
]


def encode_struct(fields, data):
    """
    编码 sproto 结构体。
    fields: [(tag, type, name, is_array)]
    data: {name: value}
    """
    entries = bytearray()
    data_section = bytearray()
    index = 0
    lasttag = -1

    for tag, ftype, name, is_array, type_name in fields:
        if name not in data or data[name] is None:
            continue
        value = data[name]

        # tag 跳转
        gap = tag - lasttag - 1
        if gap > 0:
            skip = (gap - 1) * 2 + 1
            entries.extend(struct.pack("<H", skip & 0xFFFF))
            index += 1

        if is_array:
            # 数组: 先写元素个数，再写每个元素
            items = list(value) if value else []
            entries.extend(struct.pack("<H", 0))
            data_section.extend(struct.pack("<I", len(items)))
            sub_type = SPROTO_TYPES.get(type_name)
            for item in items:
                if sub_type and isinstance(item, dict):
                    encoded = encode_struct(sub_type, item)
                elif isinstance(item, dict):
                    encoded = encode_struct(fields, item)
                else:
                    encoded = str(item).encode() if isinstance(item, str) else b""
                data_section.extend(struct.pack("<I", len(encoded)))
                data_section.extend(encoded)
        elif ftype == T_INTEGER:
            if isinstance(value, int) and 0 <= value < 0x7FFF:
                inline = (value + 1) * 2
                entries.extend(struct.pack("<H", inline & 0xFFFF))
            else:
                entries.extend(struct.pack("<H", 0))
                data_section.extend(struct.pack("<I", 4))
                data_section.extend(struct.pack("<I", int(value) & 0xFFFFFFFF))
        elif ftype == T_BOOLEAN:
            entries.extend(struct.pack("<H", 0))
            data_section.extend(bytes([1 if value else 0]))
        elif ftype == T_STRING:
            entries.extend(struct.pack("<H", 0))
            encoded = value.encode("utf-8") if isinstance(value, str) else value
            data_section.extend(struct.pack("<I", len(encoded)))
            data_section.extend(encoded)

        index += 1
        lasttag = tag

    header = struct.pack("<H", index)
    return bytes(header) + bytes(entries) + bytes(data_section)


def decode_struct(fields, data):
    """解码 sproto 结构体，返回 {name: value}"""
    if not data or len(data) < 2:
        return {}

    result = {}
    pos = 0
    field_count = struct.unpack_from("<H", data, pos)[0]
    pos += 2

    entries_end = pos + field_count * 2
    entries = []
    while pos < entries_end and pos + 2 <= len(data):
        entries.append(struct.unpack_from("<H", data, pos)[0])
        pos += 2

    data_start = pos
    data_pos = data_start
    field_idx = 0
    lasttag = -1

    for entry in entries:
        if entry % 2 == 1:
            skip_val = (entry - 1) // 2 + 1
            lasttag += skip_val
            continue

        while field_idx < len(fields) and fields[field_idx][0] <= lasttag:
            field_idx += 1
        if field_idx >= len(fields):
            break

        tag, ftype, name, is_array, type_name = fields[field_idx]
        lasttag = tag
        field_idx += 1

        if entry % 2 == 0 and entry > 0:
            result[name] = (entry // 2) - 1
        else:
            if data_pos >= len(data):
                result[name] = None if ftype == T_STRING else (False if ftype == T_BOOLEAN else 0)
                continue

            if is_array:
                if data_pos + 4 > len(data):
                    result[name] = []
                    continue
                count = struct.unpack_from("<I", data, data_pos)[0]
                data_pos += 4
                items = []
                sub_type = SPROTO_TYPES.get(type_name)
                for _ in range(count):
                    if data_pos + 4 > len(data):
                        break
                    item_len = struct.unpack_from("<I", data, data_pos)[0]
                    data_pos += 4
                    if data_pos + item_len > len(data):
                        break
                    item_raw = data[data_pos:data_pos + item_len]
                    if sub_type:
                        items.append(decode_struct(sub_type, item_raw))
                    else:
                        items.append(item_raw.decode("utf-8", errors="replace"))
                    data_pos += item_len
                result[name] = items
            elif ftype == T_BOOLEAN:
                result[name] = data[data_pos] != 0
                data_pos += 1
            elif ftype == T_INTEGER:
                if data_pos + 8 > len(data):
                    result[name] = 0
                    continue
                length = struct.unpack_from("<I", data, data_pos)[0]
                data_pos += 4
                if length == 4 and data_pos + 4 <= len(data):
                    result[name] = struct.unpack_from("<I", data, data_pos)[0]
                    data_pos += 4
                else:
                    data_pos += length
            elif ftype == T_STRING:
                if data_pos + 4 > len(data):
                    result[name] = ""
                    continue
                length = struct.unpack_from("<I", data, data_pos)[0]
                data_pos += 4
                if data_pos + length <= len(data):
                    result[name] = data[data_pos:data_pos + length].decode("utf-8", errors="replace")
                    data_pos += length
                else:
                    result[name] = ""

    return result


# ======== sproto pack/unpack 压缩 ========

def sproto_pack(data):
    """sproto pack 压缩"""
    result = bytearray()
    i = 0
    ff_n = 0
    ff_des_pos = None

    while i < len(data):
        chunk = data[i:i+8]
        if len(chunk) < 8:
            chunk = chunk + b'\x00' * (8 - len(chunk))

        notzero = 0
        header = 0
        nz_bytes = bytearray()
        for j in range(8):
            if chunk[j] != 0:
                notzero += 1
                header |= 1 << j
                nz_bytes.append(chunk[j])

        if (notzero == 6 or notzero == 7) and ff_n > 0:
            notzero = 8

        if notzero == 8:
            if ff_n > 0:
                result.extend(chunk)
                ff_n += 1
            else:
                ff_des_pos = len(result)
                result.extend(b'\xff\x00')
                result.extend(chunk)
                ff_n = 1
        else:
            if ff_n > 0:
                result[ff_des_pos + 1] = ff_n - 1
                ff_n = 0
            if notzero == 0:
                result.append(0)
            else:
                result.append(header)
                result.extend(nz_bytes)

        i += 8

    if ff_n > 0:
        result[ff_des_pos + 1] = ff_n - 1

    return bytes(result)


def sproto_unpack(data):
    """sproto unpack 解压缩"""
    result = bytearray()
    pos = 0
    while pos < len(data):
        header = data[pos]
        pos += 1
        if header == 0xFF:
            if pos >= len(data):
                break
            count = data[pos] + 1
            pos += 1
            result.extend(data[pos:pos + count * 8])
            pos += count * 8
        else:
            for j in range(8):
                if header & (1 << j):
                    result.append(data[pos])
                    pos += 1
                else:
                    result.append(0)
    return bytes(result)


# ======== 网络层 ========

def recv_n(sock, n):
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            return None
        data.extend(chunk)
    return bytes(data)


def recv_packet(sock):
    header = recv_n(sock, 2)
    if not header:
        return None
    length = struct.unpack(">H", header)[0]
    packed = recv_n(sock, length)
    if packed is None:
        return None
    return sproto_unpack(packed)


def send_packet(sock, data):
    packed = sproto_pack(data)
    packet = struct.pack(">H", len(packed)) + packed
    sock.sendall(packet)


# ======== 消息层 ========

_session_id = 1
_session_lock = threading.Lock()
_pending = {}  # session -> name


def encode_request(name, args=None):
    """编码请求: 包头 + 请求体"""
    global _session_id

    proto = C2S_PROTO.get(name) or S2C_PROTO.get(name)
    if not proto:
        raise ValueError(f"未知协议: {name}")

    tag = proto["tag"]
    with _session_lock:
        session = _session_id
        _session_id += 1
        _pending[session] = name

    header = encode_struct(PKG_FIELDS, {"type": tag, "session": session})
    body = encode_struct(proto["request"], args or {})
    return header + body, session


def decode_response(data):
    """解码服务器响应 -> (name, body_dict)"""
    pkg = decode_struct(PKG_FIELDS, data)
    tag = pkg.get("type", 0) or 0
    session = pkg.get("session", 0) or 0

    header_len = len(encode_struct(PKG_FIELDS, {"type": tag, "session": session}))
    body_data = data[header_len:]

    # 先按 tag 查找（error 等独立协议优先于 session 匹配）
    name = C2S_BY_TAG.get(tag)
    if name:
        proto = C2S_PROTO.get(name) or S2C_PROTO.get(name)
        if proto and proto["response"]:
            # 清理 pending session（防止内存泄漏）
            if session != 0:
                with _session_lock:
                    _pending.pop(session, None)
            resp = decode_struct(proto["response"], body_data)
            return name, resp

    # 按 session 匹配请求（兼容无独立 response 定义的协议）
    if session != 0:
        with _session_lock:
            name = _pending.pop(session, None)
        if name and name in C2S_PROTO:
            resp = decode_struct(C2S_PROTO[name]["response"], body_data)
            return name, resp

    return "unknown", {"tag": tag, "session": session}


# ======== 交互式客户端 ========

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8888

# 不需要 body 的协议
NO_ARGS_PROTO = {"ping", "bag_list", "bag_sort"}


def recv_loop(sock):
    while True:
        try:
            raw = recv_packet(sock)
            if raw is None:
                print("\n[断开] 服务器连接已关闭")
                break
            msg_name, body = decode_response(raw)
            if msg_name:
                body_str = json.dumps(body, ensure_ascii=False)
                if msg_name == "error":
                    print(f"\n[← 错误] code={body.get('code')}, msg={body.get('msg')}")
                elif msg_name in ("chat_notify", "chat_message"):
                    print(f"\n[← 推送] {body_str}")
                else:
                    print(f"\n[← {msg_name}] {body_str}")
        except Exception as e:
            print(f"\n[异常] {e}")
            break


def print_help():
    cmds = [
        ("register <account> <pass>", "注册"),
        ("login <account> <pass>", "登录"),
        ("ping", "心跳"),
    ]
    for name in sorted(C2S_PROTO):
        if name in ("login", "register", "ping"):
            continue
        proto = C2S_PROTO[name]
        req_fields = proto["request"]
        args_hint = " ".join(f"<{f[2]}>" for f in req_fields) if req_fields else ""
        cmds.append((f"{name} {args_hint}", f"(tag {proto['tag']})"))
    cmds.append(("q", "退出"))
    print("协议列表:")
    for cmd, desc in cmds:
        print(f"  {cmd:40s} {desc}")


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect((HOST, PORT))
    print(f"[连接] {HOST}:{PORT}")
    sock.settimeout(None)
    threading.Thread(target=recv_loop, args=(sock,), daemon=True).start()
    time.sleep(0.3)

    print("\n加载协议:")
    print(f"  c2s: {len(C2S_PROTO)} protocols")
    print(f"  s2c: {len(S2C_PROTO)} protocols")
    print()
    print_help()

    while True:
        try:
            line = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not line:
            continue
        if line == "q":
            break
        if line == "help":
            print_help()
            continue

        parts = line.split()
        cmd = parts[0]

        if cmd not in C2S_PROTO:
            print(f"未知命令: {cmd}，输入 help 查看协议列表")
            continue

        if cmd in NO_ARGS_PROTO:
            data, session = encode_request(cmd)
            send_packet(sock, data)
            print(f"[→ {session}] {cmd}")
        else:
            proto = C2S_PROTO[cmd]
            req_fields = proto["request"]
            args = {}
            for i, (tag, ftype, fname, is_array, _) in enumerate(req_fields):
                if i + 1 < len(parts):
                    raw = parts[i + 1]
                    if ftype == T_INTEGER:
                        args[fname] = int(raw)
                    elif ftype == T_BOOLEAN:
                        args[fname] = raw.lower() in ("true", "1", "yes")
                    else:
                        args[fname] = raw
                else:
                    # 尝试读取更多输入作为该字段的值
                    remaining = parts[i + 1:]
                    if remaining:
                        args[fname] = " ".join(remaining)
                    break

            data, session = encode_request(cmd, args)
            send_packet(sock, data)
            print(f"[→ {session}] {cmd} {args}")

    sock.close()
    print("[退出]")


if __name__ == "__main__":
    main()
