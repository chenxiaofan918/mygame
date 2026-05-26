#!/usr/bin/env python3
"""
sproto 协议测试客户端（纯 Python 实现，无 C 扩展依赖）
用法: python sproto_client.py [host] [port]

通信协议: 2字节大端长度前缀 + sproto 二进制
"""
import json
import socket
import struct
import sys
import threading
import time

# ======== 纯 Python sproto 编解码 ========

# sproto 类型常量
T_INTEGER = 0
T_BOOLEAN = 1
T_STRING = 2

# 协议定义: (tag, type, name)
# 按 tag 顺序排列
PKG_FIELDS = [
    (0, T_INTEGER, "type"),
    (1, T_INTEGER, "session"),
]

# c2s 协议（客户端→服务器）
C2S_PROTO = {
    "login": {
        "tag": 1,
        "request": [
            (0, T_STRING, "account"),
            (1, T_STRING, "password"),
        ],
        "response": [
            (0, T_BOOLEAN, "ok"),
            (1, T_INTEGER, "player_id"),
            (2, T_STRING, "token"),
            (3, T_STRING, "nickname"),
            (4, T_INTEGER, "level"),
        ],
    },
    "register": {
        "tag": 2,
        "request": [
            (0, T_STRING, "account"),
            (1, T_STRING, "password"),
        ],
        "response": [
            (0, T_BOOLEAN, "ok"),
            (1, T_INTEGER, "player_id"),
        ],
    },
    "chat": {
        "tag": 3,
        "request": [
            (0, T_STRING, "msg"),
        ],
        "response": [
            (0, T_STRING, "msg"),
        ],
    },
    "ping": {
        "tag": 4,
        "request": [],
        "response": [],
    },
}

# s2c 协议（服务器→客户端）
S2C_PROTO = {
    "error": {
        "tag": 1,
        "response": [
            (0, T_INTEGER, "code"),
            (1, T_STRING, "msg"),
        ],
    },
    "chat_notify": {
        "tag": 10,
        "response": [
            (0, T_INTEGER, "player_id"),
            (1, T_STRING, "msg"),
        ],
    },
}

# tag -> name 映射
C2S_BY_TAG = {v["tag"]: k for k, v in C2S_PROTO.items()}
S2C_BY_TAG = {v["tag"]: k for k, v in S2C_PROTO.items()}


def encode_struct(fields, data):
    """
    sproto 结构体编码

    Header: 2字节 field_count (LE) + N*2 字节 per-field entries (LE uint16)
    Data: 每字段数据依次排列

    per-field entry:
    - 偶数 > 0: 小整数内联, 值 = (entry/2) - 1
    - 奇数: tag 跳转标记
    - 0: 数据在 data section

    整数 ≥ 32767 时存到 data section: 4字节长度 + 4字节值 (LE)
    字符串: 4字节长度 + UTF-8 数据
    布尔: 1字节 (0/1)
    """
    entries = bytearray()
    data_section = bytearray()
    index = 0
    lasttag = -1

    for tag, ftype, name in fields:
        if name not in data:
            continue

        value = data[name]
        if value is None:
            continue

        # tag 跳转
        gap = tag - lasttag - 1
        if gap > 0:
            skip = (gap - 1) * 2 + 1
            entries.extend(struct.pack("<H", skip & 0xFFFF))
            index += 1

        if ftype == T_INTEGER:
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
    """
    sproto 结构体解码
    返回: {name: value}
    """
    if not data or len(data) < 2:
        return {}

    result = {}
    pos = 0

    field_count = struct.unpack_from("<H", data, pos)[0]
    pos += 2

    # 读取 per-field entries
    entries_end = pos + field_count * 2
    entries = []
    while pos < entries_end and pos + 2 <= len(data):
        entries.append(struct.unpack_from("<H", data, pos)[0])
        pos += 2

    # data section 从此开始
    data_start = pos

    # 根据 entries 和 fields 解码
    data_pos = data_start
    field_idx = 0
    lasttag = -1

    for entry in entries:
        # 判断是否为 tag 跳转
        if entry % 2 == 1:
            # 奇数: tag 跳转
            skip_val = (entry - 1) // 2 + 1
            lasttag += skip_val
            continue

        # 找下一个 field
        while field_idx < len(fields) and fields[field_idx][0] <= lasttag:
            field_idx += 1
        if field_idx >= len(fields):
            break

        tag, ftype, name = fields[field_idx]
        lasttag = tag
        field_idx += 1

        if entry % 2 == 0 and entry > 0:
            # 偶数 > 0: 内联小整数
            result[name] = (entry // 2) - 1
        else:
            # entry == 0: 从 data section 读取
            if data_pos >= len(data):
                result[name] = None if ftype == T_STRING else (False if ftype == T_BOOLEAN else 0)
                continue

            if ftype == T_BOOLEAN:
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


def encode_proto_package(type_tag, session):
    """编码协议包头"""
    return encode_struct(PKG_FIELDS, {"type": type_tag, "session": session})


def decode_proto_package(data):
    """解码协议包头"""
    return decode_struct(PKG_FIELDS, data)


# ======== sproto pack/unpack 压缩 ========

def sproto_pack(data):
    """sproto pack 压缩: 8字节分组, 零值压缩"""
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
    """读取一帧: 2字节大端长度 + packed sproto数据"""
    header = recv_n(sock, 2)
    if not header:
        return None
    length = struct.unpack(">H", header)[0]
    packed = recv_n(sock, length)
    if packed is None:
        return None
    return sproto_unpack(packed)


def send_packet(sock, data):
    """发送一帧: 先 pack 压缩, 再加 2字节大端长度前缀"""
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

    proto = C2S_PROTO.get(name)
    if not proto:
        raise ValueError(f"未知协议: {name}")

    tag = proto["tag"]

    with _session_lock:
        session = _session_id
        _session_id += 1
        _pending[session] = name

    header = encode_proto_package(tag, session)
    body = encode_struct(proto["request"], args or {})
    return header + body, session


def decode_response(data):
    """解码服务器响应 -> (name, body_dict)"""
    pkg = decode_proto_package(data)
    tag = pkg.get("type", 0)
    session = pkg.get("session", 0)

    # 计算包头长度
    header_len = len(encode_proto_package(tag, session))
    body_data = data[header_len:]

    if session != 0:
        # 请求响应
        with _session_lock:
            name = _pending.pop(session, None)
        if name and name in C2S_PROTO:
            resp = decode_struct(C2S_PROTO[name]["response"], body_data)
            return name, resp
        # fallback: 按 tag 查找
        name = C2S_BY_TAG.get(tag)
        if name:
            resp = decode_struct(C2S_PROTO[name]["response"], body_data)
            return name, resp
        return "unknown", {"tag": tag, "session": session}
    else:
        # 服务器推送
        name = S2C_BY_TAG.get(tag)
        if name:
            resp = decode_struct(S2C_PROTO[name]["response"], body_data)
            return name, resp
        return "unknown_push", {"tag": tag}


# ======== 交互式客户端 ========

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8888


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
                elif msg_name == "chat_notify":
                    print(f"\n[← 聊天推送] {body_str}")
                else:
                    print(f"\n[← {msg_name}] {body_str}")
        except Exception as e:
            print(f"\n[异常] {e}")
            break


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect((HOST, PORT))
    print(f"[连接] {HOST}:{PORT}")

    sock.settimeout(None)
    threading.Thread(target=recv_loop, args=(sock,), daemon=True).start()
    time.sleep(0.3)

    print("""
    ═════════ sproto 测试客户端 ═════════
    register <account> <password>  注册
    login <account> <password>     登录
    chat <msg>                     发送聊天
    ping                           心跳
    q                              退出
    ═════════════════════════════════════
    """)

    while True:
        try:
            line = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            break

        if not line:
            continue
        if line == "q":
            break

        parts = line.split()
        cmd = parts[0]

        if cmd == "register":
            if len(parts) < 3:
                print("用法: register <account> <password>")
                continue
            data, session = encode_request("register", {
                "account": parts[1], "password": parts[2]
            })
            send_packet(sock, data)
            print(f"[→ {session}] register")

        elif cmd == "login":
            if len(parts) < 3:
                print("用法: login <account> <password>")
                continue
            data, session = encode_request("login", {
                "account": parts[1], "password": parts[2]
            })
            send_packet(sock, data)
            print(f"[→ {session}] login")

        elif cmd == "chat":
            if len(parts) < 2:
                print("用法: chat <msg>")
                continue
            data, session = encode_request("chat", {"msg": parts[1]})
            send_packet(sock, data)
            print(f"[→ {session}] chat")

        elif cmd == "ping":
            data, session = encode_request("ping")
            send_packet(sock, data)
            print(f"[→ {session}] ping")

        else:
            print(f"未知命令: {cmd}")

    sock.close()
    print("[退出]")


if __name__ == "__main__":
    main()
