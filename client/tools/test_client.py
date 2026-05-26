#!/usr/bin/env python3
"""
游戏服务器测试客户端
用法: python test_client.py [host] [port]

通信协议: 2字节大端长度前缀 + JSON数据体
"""

import json
import socket
import struct
import sys
import threading
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8888


def recv_packet(sock):
    """读取一个完整数据包 (2字节长度前缀 + JSON)"""
    header = sock.recv(2)
    if not header or len(header) < 2:
        return None
    length = struct.unpack(">H", header)[0]
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            return None
        data += chunk
    return json.loads(data.decode("utf-8"))


def send_packet(sock, msg):
    """发送一个 JSON 数据包"""
    data = json.dumps(msg, ensure_ascii=False).encode("utf-8")
    packet = struct.pack(">H", len(data)) + data
    sock.sendall(packet)


def recv_loop(sock):
    """后台接收线程: 持续打印服务端推送的消息"""
    while True:
        try:
            msg = recv_packet(sock)
            if msg is None:
                print("[断开] 服务器连接已关闭")
                break
            print(f"[← 收] {json.dumps(msg, ensure_ascii=False)}")
        except Exception as e:
            print(f"[异常] {e}")
            break


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(10)
    sock.connect((HOST, PORT))
    print(f"[连接] {HOST}:{PORT}")

    # 启动接收线程
    threading.Thread(target=recv_loop, args=(sock,), daemon=True).start()

    # 等待 welcome 消息
    time.sleep(0.2)

    # 交互式命令
    cmds = {
        "1": ("register", {"account": "test", "password": "123456"}),
        "2": ("login", {"account": "test", "password": "123456"}),
        "3": ("chat", {"msg": "hello world"}),
        "4": ("ping", {}),
    }

    print("""
    ═════════ 测试菜单 ═════════
    [1] 注册  test/123456
    [2] 登录  test/123456
    [3] 发送聊天消息
    [4] Ping
    [q] 退出
    ════════════════════════════
    """)

    while True:
        try:
            cmd = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            break

        if cmd == "q":
            break
        elif cmd in cmds:
            msg_type, args = cmds[cmd]
            payload = {"type": msg_type, **args}
            send_packet(sock, payload)
            print(f"[→ 发] {json.dumps(payload, ensure_ascii=False)}")
        else:
            # 直接发送原始 JSON
            send_packet(sock, {"type": cmd})

    sock.close()
    print("[退出]")


if __name__ == "__main__":
    main()
