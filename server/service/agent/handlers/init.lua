-- handlers/init.lua — 注册所有模块的协议处理器
local proto = require "proto_stub"

proto.register_module("bag", require "handlers.bag")
proto.register_module("chat", require "handlers.chat")
proto.register_module("rank", require "handlers.rank")

return proto
