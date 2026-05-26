-- protoloader: 加载 sproto 协议到全局槽位
-- c2s → slot 1,  s2c → slot 2
local skynet = require "skynet"
local sprotoloader = require "sprotoloader"
local proto = require "proto"

skynet.start(function()
	sprotoloader.save(proto.c2s, 1)
	sprotoloader.save(proto.s2c, 2)
	skynet.error("[protoloader] proto loaded (c2s=1, s2c=2)")
end)
