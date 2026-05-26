#!/usr/bin/env python3
"""
自动化集成测试 — 一键跑通完整流程
用法: python test_auto.py [host] [port]
"""

import json
import socket
import struct
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8888

PASS = 0
FAIL = 0


def recv(sock):
    header = sock.recv(2)
    length = struct.unpack(">H", header)[0]
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        data += chunk
    return json.loads(data.decode("utf-8"))


def send(sock, msg):
    data = json.dumps(msg, ensure_ascii=False).encode("utf-8")
    sock.sendall(struct.pack(">H", len(data)) + data)


def check(step, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  ✓ {step}")
    else:
        FAIL += 1
        print(f"  ✗ {step} — {detail}")


def main():
    global PASS, FAIL
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect((HOST, PORT))
    print(f"\n[连接] {HOST}:{PORT}\n")

    # 1. 接收 welcome
    msg = recv(sock)
    check("welcome 消息", msg.get("type") == "welcome", str(msg))

    # 2. 注册
    send(sock, {"type": "register", "account": "auto_test", "password": "123456"})
    msg = recv(sock)
    check("注册新账号", msg.get("type") == "register_ok" and msg.get("player_id"), str(msg))
    player_id = msg.get("player_id")

    # 3. 重复注册（应失败）
    send(sock, {"type": "register", "account": "auto_test", "password": "123456"})
    msg = recv(sock)
    check("重复注册拒绝", msg.get("type") == "error", str(msg))

    # 4. 登录
    send(sock, {"type": "login", "account": "auto_test", "password": "123456"})
    msg = recv(sock)
    check("登录成功", msg.get("type") == "login_ok" and msg.get("token"), str(msg))
    token = msg.get("token")

    # 5. 错误密码
    # 新开一个连接测试
    sock2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock2.settimeout(5)
    sock2.connect((HOST, PORT))
    recv(sock2)  # welcome
    send(sock2, {"type": "login", "account": "auto_test", "password": "wrong"})
    msg = recv(sock2)
    check("错误密码拒绝", msg.get("type") == "error", str(msg))
    sock2.close()

    # 6. 登录后发送 chat
    send(sock, {"type": "chat", "msg": "你好, skynet!"})
    msg = recv(sock)
    check("聊天消息回复", msg.get("type") == "chat_ack", str(msg))

    # 7. ping
    send(sock, {"type": "ping"})
    msg = recv(sock)
    check("pong 响应", msg.get("type") == "pong", str(msg))

    # 8. 未登录状态拒绝游戏消息
    sock3 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock3.settimeout(5)
    sock3.connect((HOST, PORT))
    recv(sock3)  # welcome
    send(sock3, {"type": "chat", "msg": "no auth"})
    msg = recv(sock3)
    check("未登录拒绝游戏消息", msg.get("type") == "error", str(msg))
    sock3.close()

    sock.close()

    # 报告
    total = PASS + FAIL
    print(f"\n────── 测试报告 ──────")
    print(f"  通过: {PASS}/{total}")
    print(f"  失败: {FAIL}/{total}")
    print(f"  {'✓ ALL PASS' if FAIL == 0 else '✗ SOME FAILED'}")
    print(f"─────────────────────\n")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
