-- ylog: 给 skynet.error 增加时间戳前缀
-- 用法: require "ylog" 后 skynet.error 自动带时间戳
local skynet = require "skynet"

local _error = skynet.error
skynet.error = function(...)
	_error(string.format("[%s] %s", os.date("%H:%M:%S"), table.concat({...}, " ")))
end
