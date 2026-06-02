#!/usr/bin/env lua
-- compile_sproto: 预编译 .sproto 协议文本为 .spb 二进制文件
--
-- 用法:
--   lua tools/compile_sproto.lua [proto_dir] [out_dir]
--
-- 默认值:
--   proto_dir = ./proto/
--   out_dir   = ./proto/
--
-- 输出:
--   <out_dir>/c2s.spb  客户端→服务端协议
--   <out_dir>/s2c.spb  服务端→客户端推送协议
--
-- 在构建流水线中, 此脚本后应跟随:
--   python tools/sprotogen.py

-- 路径设置: 与 config.path 保持一致
local ROOT = "./"
package.path = ROOT .. "server/main/?.lua;"
	.. ROOT .. "server/module/?.lua;"
	.. ROOT .. "server/lib/lualib/?.lua;"
	.. package.path
package.cpath = ROOT .. "server/lib/luaclib/?.so;"
	.. package.cpath

local ok, sprotoparser = pcall(require, "sprotoparser")
if not ok then
	io.stderr:write([[
[compile_sproto] ERROR: 无法加载 sprotoparser（依赖 lpeg）
  lpeg.so 与当前 Lua 解释器版本不匹配。

解决方案:
  1) 指定正确版本的 Lua:  make proto LUA=lua5.4
  2) 安装系统 lpeg 包:
       apt install lua-lpeg       # Debian/Ubuntu
       yum install lua-lpeg       # CentOS/RHEL
  3) 或用 luarocks 安装: luarocks install lpeg

  当前 Lua 版本: ]] .. _VERSION .. [[
  搜索路径: ]] .. package.cpath .. [[

]])
	os.exit(1)
end

local proto_dir = arg[1] or "./proto/"
local out_dir   = arg[2] or "./proto/"

-- 确保输出目录存在
local function ensure_dir(dir)
	os.execute("mkdir -p " .. dir:gsub("\\", "/"))
end

local function read_text(name)
	local f = io.open(proto_dir .. name, "r")
	if not f then
		io.stderr:write("[compile_sproto] WARNING: " .. proto_dir .. name .. " not found, skipping\n")
		return ""
	end
	local content = f:read("*a")
	f:close()
	return content
end

-- 协议模块列表（与 proto.lua 保持一致）
local modules = { "common", "login", "bag", "chat", "rank" }

----------------------------
-- 组装 c2s / s2c 文本
----------------------------
local c2s_parts = {}
local s2c_parts = {}

for _, mod in ipairs(modules) do
	local public = read_text(mod .. "_public.sproto")
	if #public > 0 then
		table.insert(c2s_parts, public)
		table.insert(s2c_parts, public)
	end

	local c2s = read_text(mod .. "_c2s.sproto")
	if #c2s > 0 then
		table.insert(c2s_parts, c2s)
	end

	local s2c = read_text(mod .. "_s2c.sproto")
	if #s2c > 0 then
		table.insert(s2c_parts, s2c)
	end
end

local c2s_text = table.concat(c2s_parts, "\n")
local s2c_text = table.concat(s2c_parts, "\n")

if #c2s_text == 0 and #s2c_text == 0 then
	io.stderr:write("[compile_sproto] ERROR: no .sproto files found in " .. proto_dir .. "\n")
	os.exit(1)
end

----------------------------
-- 解析 → 二进制 → 写文件
----------------------------
ensure_dir(out_dir)

local function write_spb(filename, text)
	if #text == 0 then
		io.stderr:write("[compile_sproto] WARNING: " .. filename .. " is empty, skipping\n")
		return
	end
	local binary = sprotoparser.parse(text)
	local f = io.open(out_dir .. filename, "wb")
	assert(f, "cannot write " .. out_dir .. filename)
	f:write(binary)
	f:close()
	print("[compile_sproto] generated " .. out_dir .. filename
		.. " (" .. #binary .. " bytes)")
end

write_spb("c2s.spb", c2s_text)
write_spb("s2c.spb", s2c_text)

print("[compile_sproto] done")
