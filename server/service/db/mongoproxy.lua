-- mongoproxy: MongoDB 代理服务
-- 封装 MongoDB CRUD，其他 service 通过 skynet.call/send 调用
-- 依赖: bson.so (已编译), skynet.mongo.driver (需编译)
local skynet = require "skynet"
require "ylog"
require "skynet.manager"
local mongo_client = require "skynet.db.mongo"

local db          -- MongoDB database 对象
local mongo_conn  -- MongoDB client 对象
local connected = false

-- ======== BSON 结果清洗 ========
-- 将 BSON 特殊类型 (ObjectId, int64 等) 转为 Lua 基本类型
local function clean(doc)
	if type(doc) ~= "table" then
		return doc
	end
	local t = {}
	for k, v in pairs(doc) do
		if type(v) == "table" then
			t[k] = clean(v)
		elseif type(v) == "userdata" then
			t[k] = tostring(v)
		elseif v ~= nil then
			t[k] = v
		end
	end
	return t
end

-- ======== MongoDB 初始化 ========
local function init_mongo()
	local host = skynet.getenv("mongo_host") or "127.0.0.1"
	local port = tonumber(skynet.getenv("mongo_port") or 27017)
	local db_name = skynet.getenv("mongo_db") or "game"
	local username = skynet.getenv("mongo_username")
	local password = skynet.getenv("mongo_password")

	local ok, err = pcall(function()
		local conf = {
			host = host,
			port = port,
		}
		if username and #username > 0 then
			conf.username = username
		end
		if password and #password > 0 then
			conf.password = password
		end

		mongo_conn = mongo_client.client(conf)
		local database = mongo_conn:getDB(db_name)

		-- 验证连接
		local result = database:runCommand("ping")
		if result.ok ~= 1 then
			return nil, "mongo ping failed"
		end

		db = database
		connected = true
		skynet.error("[mongoproxy] MongoDB connected: " .. host .. ":" .. port .. "/" .. db_name)
		return database
	end)

	if not ok then
		connected = false
		skynet.error("[mongoproxy] MongoDB init failed: " .. tostring(err))
	end
end

-- ======== 心跳保活 ========
local function heartbeat()
	if connected and db then
		local ok, result = pcall(db.runCommand, db, "ping")
		if not ok or not result or result.ok ~= 1 then
			skynet.error("[mongoproxy] connection lost, reconnecting...")
			connected = false
			init_mongo()
		end
	end
	skynet.timeout(300, heartbeat)
end

-- ======== CRUD 命令 ========
local CMD = {}

-- 查询单个文档
-- mongo.find_one("players", { player_id = 1 })
function CMD.find_one(collection, query)
	if not connected then return { badresult = true, err = "mongo not connected" } end
	local col = db[collection]
	local ok, result = pcall(col.findOne, col, query or {})
	if not ok then
		return { badresult = true, err = tostring(result) }
	end
	if result then
		return clean(result)
	end
	return nil
end

-- 查询多个文档（返回数组）
-- mongo.find("players", { level = { ["$gte"] = 10 } }, { nickname = 1, level = 1 }, 100)
-- mongo.find("players", {}, { player_id = 1, nickname = 1 }, 50, { level = -1 })  -- 带排序
function CMD.find(collection, query, projection, limit, sort)
	if not connected then return { badresult = true, err = "mongo not connected" } end
	local col = db[collection]
	local cursor = col:find(query, projection)
	if limit then
		cursor:limit(limit)
	end
	if sort then
		cursor:sort(sort)
	end
	local results = {}
	local ok, err = pcall(function()
		while cursor:hasNext() do
			table.insert(results, clean(cursor:next()))
		end
		cursor:close()
	end)
	if not ok then
		return { badresult = true, err = tostring(err) }
	end
	return results
end

-- 插入单个文档（fire-and-forget）
-- mongo.insert("players", { player_id = 1, nickname = "test" })
function CMD.insert(collection, doc)
	if not connected then return { badresult = true, err = "mongo not connected" } end
	local col = db[collection]
	local ok, err = pcall(col.insert, col, doc)
	if not ok then
		return { badresult = true, err = tostring(err) }
	end
	return { ok = true }
end

-- 插入单个文档（带确认）
-- mongo.insert_safe("players", { player_id = 1 })
function CMD.insert_safe(collection, doc)
	if not connected then return { badresult = true, err = "mongo not connected" } end
	local col = db[collection]
	local pcall_ok, safe_ok = pcall(col.safe_insert, col, doc)
	if not pcall_ok then
		return { badresult = true, err = tostring(safe_ok) }
	end
	if not safe_ok then
		return { badresult = true, err = "mongo write failed" }
	end
	return { ok = true }
end

-- 更新单个文档
-- mongo.update_one("players", { player_id = 1 }, { ["$set"] = { level = 10 } })
function CMD.update_one(collection, query, update)
	if not connected then return { badresult = true, err = "mongo not connected" } end
	local col = db[collection]
	local pcall_ok, safe_ok = pcall(col.safe_update, col, query, update, false, false)
	if not pcall_ok then
		return { badresult = true, err = tostring(safe_ok) }
	end
	if not safe_ok then
		return { badresult = true, err = "mongo write failed" }
	end
	return { ok = true }
end

-- 更新多个文档
-- mongo.update_many("players", { level = 1 }, { ["$set"] = { level = 2 } })
function CMD.update_many(collection, query, update)
	if not connected then return { badresult = true, err = "mongo not connected" } end
	local col = db[collection]
	local pcall_ok, safe_ok = pcall(col.safe_update, col, query, update, false, true)
	if not pcall_ok then
		return { badresult = true, err = tostring(safe_ok) }
	end
	if not safe_ok then
		return { badresult = true, err = "mongo write failed" }
	end
	return { ok = true }
end

-- 替换文档（upsert 模式）
-- mongo.upsert("players", { player_id = 1 }, { ["$set"] = { nickname = "new" } })
function CMD.upsert(collection, query, update)
	if not connected then return { badresult = true, err = "mongo not connected" } end
	local col = db[collection]
	local pcall_ok, safe_ok = pcall(col.safe_update, col, query, update, true, false)
	if not pcall_ok then
		return { badresult = true, err = tostring(safe_ok) }
	end
	if not safe_ok then
		return { badresult = true, err = "mongo write failed" }
	end
	return { ok = true }
end

-- 删除单个文档
-- mongo.delete_one("players", { player_id = 1 })
function CMD.delete_one(collection, query)
	if not connected then return { badresult = true, err = "mongo not connected" } end
	local col = db[collection]
	local pcall_ok, safe_ok = pcall(col.safe_delete, col, query, true)
	if not pcall_ok then
		return { badresult = true, err = tostring(safe_ok) }
	end
	if not safe_ok then
		return { badresult = true, err = "mongo delete failed" }
	end
	return { ok = true }
end

-- 删除多个文档
-- mongo.delete_many("players", { level = 0 })
function CMD.delete_many(collection, query)
	if not connected then return { badresult = true, err = "mongo not connected" } end
	local col = db[collection]
	local pcall_ok, safe_ok = pcall(col.safe_delete, col, query, false)
	if not pcall_ok then
		return { badresult = true, err = tostring(safe_ok) }
	end
	if not safe_ok then
		return { badresult = true, err = "mongo delete failed" }
	end
	return { ok = true }
end

-- 聚合查询
-- mongo.aggregate("players", { { ["$match"] = { level = { ["$gte"] = 10 } } }, { ["$count"] = "total" } })
function CMD.aggregate(collection, pipeline, options)
	if not connected then return { badresult = true, err = "mongo not connected" } end
	local col = db[collection]
	local cursor = col:aggregate(pipeline, options)
	local results = {}
	local ok, err = pcall(function()
		while cursor:hasNext() do
			table.insert(results, clean(cursor:next()))
		end
		cursor:close()
	end)
	if not ok then
		return { badresult = true, err = tostring(err) }
	end
	return results
end

-- 集合文档计数
-- mongo.count("players", { level = { ["$gte"] = 10 } })
function CMD.count(collection, query)
	if not connected then return { badresult = true, err = "mongo not connected" } end
	local col = db[collection]
	local cursor = col:find(query, {})
	local ok, result = pcall(cursor.count, cursor)
	cursor:close()
	if not ok then
		return { badresult = true, err = tostring(result) }
	end
	return result
end

-- 创建索引
-- mongo.create_index("players", { { player_id = 1 }, unique = true })
function CMD.create_index(collection, spec)
	if not connected then return { badresult = true, err = "mongo not connected" } end
	local col = db[collection]
	local ok, result = pcall(col.createIndex, col, spec)
	if not ok then
		return { badresult = true, err = tostring(result) }
	end
	return result
end

-- 删除集合
-- mongo.drop_collection("players")
function CMD.drop_collection(collection)
	if not connected then return { badresult = true, err = "mongo not connected" } end
	local col = db[collection]
	local ok, result = pcall(col.drop, col)
	if not ok then
		return { badresult = true, err = tostring(result) }
	end
	return result
end

-- ======== 服务分发 ========
skynet.start(function()
	skynet.dispatch("lua", function(_session, _source, cmd, ...)
		local prefix, subcmd = cmd:match("^([^.]+)%.(.+)$")
		if prefix == "mongo" then
			local f = CMD[subcmd]
			if f then
				skynet.ret(skynet.pack(f(...)))
			else
				skynet.error("[mongoproxy] unknown mongo cmd: " .. tostring(subcmd))
			end
		else
			skynet.error("[mongoproxy] unknown cmd: " .. tostring(cmd))
		end
	end)

	init_mongo()

	skynet.register ".mongoproxy"
	skynet.error("[mongoproxy] service started")

	-- 30 秒心跳保活
	skynet.timeout(300, heartbeat)
end)
