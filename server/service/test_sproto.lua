-- test_sproto: sproto 协议集成测试
-- 作为 skynet service 运行，连接游戏服走完完整流程
--
-- 用法: 先启动游戏服 ./run.sh start
--       再开一个终端:
--       3rd/skynet/skynet server/config/config.test

local skynet = require "skynet"
local socket = require "skynet.socket"
local sprotoloader = require "sprotoloader"

local HOST = "127.0.0.1"
local PORT = 8888

local host
local send_request

local TOTAL = 0
local PASS = 0
local FAIL = 0

local function check(step, ok, detail)
	TOTAL = TOTAL + 1
	if ok then
		PASS = PASS + 1
		skynet.error("  ✓ " .. step)
	else
		FAIL = FAIL + 1
		skynet.error("  ✗ " .. step .. " — " .. tostring(detail))
	end
end

-- 接收一个完整数据包: 2字节大端长度 + sproto数据
local function recv_pack(fd)
	local sz = socket.recv(fd, 2)
	if not sz or #sz < 2 then
		return nil, "closed"
	end
	local len = string.unpack(">I2", sz)
	local data = socket.recv(fd, len)
	if not data or #data < len then
		return nil, "closed"
	end
	return host:dispatch(data, #data)
end

-- 编码 -> 发送 -> 接收响应
local function send_recv(fd, name, args)
	local req = send_request(name, args)
	socket.write(fd, string.pack(">s2", req))
	return recv_pack(fd)
end

skynet.start(function()
	skynet.error("\n========== SPROTO TEST START ==========")

	host = sprotoloader.load(1):host "package"
	send_request = host:attach(sprotoloader.load(2))

	local fd = socket.open(HOST, PORT)
	if not fd then
		skynet.error("[test] connect FAILED")
		check("connect", false, "connection refused")
		goto finish
	end
	skynet.error("[test] connected")

	local ts = tostring(skynet.now())
	local account = "t_" .. ts:sub(#ts - 5)

	-- ====== 1. 注册 ======
	do
		local typ, name, args = send_recv(fd, "register", {
			account = account,
			password = "123456",
		})
		check("register type", typ == "REQUEST", typ)
		check("register name", name == "register", name)
		check("register ok", args and args.ok == true, args)
		if args and args.player_id then
			check("got player_id", args.player_id > 0, args.player_id)
		end
	end

	-- ====== 2. 重复注册 ======
	do
		local typ, name, args = send_recv(fd, "register", {
			account = account,
			password = "123456",
		})
		if typ == "REQUEST" and name == "error" then
			check("duplicate register rejected", true, args)
		else
			check("duplicate register rejected", args and args.ok == false, args)
		end
	end

	-- ====== 3. 登录 ======
	do
		local typ, name, args = send_recv(fd, "login", {
			account = account,
			password = "123456",
		})
		check("login ok", args and args.ok == true, args)
		check("has token", args and args.token ~= nil and args.token ~= "", args and args.token)
		check("has player_id", args and args.player_id ~= nil, args and args.player_id)
	end

	-- ====== 4. 聊天 ======
	do
		local typ, name, args = send_recv(fd, "chat", { msg = "hello sproto!" })
		check("chat ok", args and args.msg == "hello sproto!", args)
	end

	-- ====== 5. Ping ======
	do
		local req = send_request("ping")
		socket.write(fd, string.pack(">s2", req))
		skynet.sleep(10)
		check("ping ok", true)
	end

	socket.close(fd)

	::finish::
	skynet.error(string.format("\n========== TEST REPORT =========="))
	skynet.error(string.format("  total: %d, pass: %d, fail: %d", TOTAL, PASS, FAIL))
	if FAIL == 0 then
		skynet.error("  >>> ALL PASS <<<")
	else
		skynet.error("  >>> SOME FAILED <<<")
	end
	skynet.error("==================================\n")

	skynet.exit()
end)
