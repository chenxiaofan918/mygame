# 项目编码规范

> 适用范围：本项目（mygame）所有 Lua、Python、Sproto、Shell 代码。
> 目标：统一风格、降低维护成本、提升代码可读性。

---

## 1. 命名规范

### 1.1 文件命名

| 类型 | 规范 | 示例 |
|------|------|------|
| Lua 模块/服务 | `snake_case.lua` | `item_template.lua`, `agent.lua` |
| 目录 | `snake_case/` | `server/service/game/` |
| Sproto 文件 | `{module}_{direction}.sproto` | `bag_c2s.sproto`, `chat_public.sproto` |
| Python 脚本 | `snake_case.py` | `export_config.py` |
| Shell 脚本 | `snake_case.sh` | `run.sh` |
| Skynet 配置 | `config.{name}` | `config.game`, `config.path` |
| Excel 设计稿 | `snake_case.xlsx` | `item.xlsx` |
| SQL 文件 | `snake_case.sql` | `schema.sql` |

**规则**：统一使用 `snake_case`，禁止 `CamelCase`（自动生成代码除外）、`kebab-case` 或混合风格。

### 1.2 标识符命名

| 类别 | 规范 | 示例 | 反例 |
|------|------|------|------|
| 变量 | `snake_case` | `player_id`, `client_fd` | `playerId`, `clientFd` |
| 函数 | `snake_case` | `gen_item_uid()`, `load_bag()` | `genItemUid()`, `LoadBag()` |
| 常量/枚举 | `UPPER_CASE` | `const.ERROR.OK` | `const.Error.ok` |
| 模块导出表 | 单大写字母 | `M`, `CMD`, `H`, `SOCKET` | `module_table`, `command` |
| 局部变量 | 完整单词 | `player_id`, `account` | `pid`（除非上下文极清晰） |
| 布尔变量 | 肯定语义 | `is_online`, `timed_out` | `not_offline` |

### 1.3 特殊表约定

| 表名 | 用途 |
|------|------|
| `CMD` | Skynet 服务的公开 RPC 接口 |
| `M` | 库模块的导出表 |
| `H` | Agent handler 模块的协议处理函数表 |
| `SOCKET` | Watchdog 服务的 socket 事件回调表 |

---

## 2. 代码组织

### 2.1 文件结构

```
-- 1. 文件头注释
-- agent: 玩家代理服务，sproto 协议

-- 2. require 导入（标准库 → 框架 → 项目模块）
local skynet = require "skynet"

local const = require "const"

-- 3. 副作用 require
require("handlers.init")

-- 4. 模块状态变量
local client_fd
local ctx = { player_id = nil }

-- 5. 内部函数
local function gen_item_uid()
    -- ...
end

-- ======== CMD ========
local CMD = {}
function CMD.get(player_id)
    -- ...
end

-- ======== 服务启动 ========
skynet.start(function()
    -- ...
end)

return M  -- 仅库模块需要
```

### 2.2 Require 规范

- 分组排列，每组按字母排序，组间空一行
- 顺序：标准 Lua 库 → Skynet 框架 → 项目内部模块

```lua
local skynet = require "skynet"
local socket = require "skynet.socket"

local const = require "const"
local utils = require "utils"
```

### 2.3 目录约定

```
service/{feature}/
    {feature}.lua           -- 主服务（<300 行时不拆分）
    handlers/               -- 超过 300 行时拆分
        init.lua            -- handler 注册入口
        bag.lua
```

- 库模块 → `server/module/`
- 服务模块 → `server/service/`
- 自动生成配置 → `server/module/config/`

---

## 3. 格式规范

### 3.1 缩进

- **使用 Tab 缩进**，编辑器设 Tab 宽度为 **4 空格**
- 禁止混用 Tab 和空格

### 3.2 行宽

- **120 字符**上限，超过则换行缩进一个 Tab

### 3.3 空格

```lua
-- 运算符两侧加空格
local result = a + b * c

-- 逗号后加空格
function foo(x, y, z)

-- 表字面量内部加空格
local t = { 1, 2, 3 }

-- 函数调用括号不空格
foo(x, y)

-- 控制流关键字后空格
if condition then
for k, v in pairs(t) do
```

### 3.4 空行

- 函数定义之间空 1 行
- 主要逻辑段之间空 1 行
- 文件末尾保留空行

### 3.5 字符串

```lua
-- 优先使用双引号
local name = "player_1001"

-- 拼接使用 ..
local msg = "player: " .. player_id

-- 长字符串使用 [[ ]]
local sql = [[
    SELECT * FROM player_log WHERE player_id = ?
]]
```

---

## 4. Lua 编码模式

### 4.1 变量声明

- **始终使用 `local`**，禁止全局变量
- 模块级变量集中声明在文件顶部

### 4.2 函数定义

```lua
-- 内部函数
local function load_bag(player_id)
end

-- 导出函数
function CMD.get(player_id)
end
```

### 4.3 错误处理

```lua
-- 1. 远程调用必须用 pcall 保护
local ok, result = pcall(skynet.call, ".bag", "lua", "get", player_id)
if not ok then
    return err_response(const.ERROR.SERVICE_UNAVAILABLE, "service unavailable")
end

-- 2. 错误码使用 const.ERROR 枚举，禁止硬编码数字
err_response(const.ERROR.MISSING_PARAMS, "missing account or password")

-- 3. 服务间调用校验 result.ok
if not result.ok then
    return err_response(const.ERROR.LOGIN_FAILED, result.err or "login failed")
end

-- 4. 禁止裸 throw/error（Skynet 下会崩溃服务）
```

### 4.4 表操作

```lua
-- 键名省略引号（有效标识符时）
local item = { id = 1001, name = "剑" }

-- 不依赖遍历顺序
for k, v in pairs(t) do end

-- 数组遍历用 ipairs
for i, v in ipairs(arr) do end

-- 拷贝/合并用 utils.clone() / utils.table_merge()
```

### 4.5 条件判断

```lua
if is_online then        -- ✅ 不要 == true
if not x then            -- ✅ nil/false 统一判断
```

---

## 5. Skynet 服务模式

### 5.1 服务模板

```lua
-- {name}: {description}

local skynet = require "skynet"
local const = require "const"

local CMD = {}

-- ======== 内部函数 ========
local function internal_func()
end

-- ======== CMD ========
function CMD.some_command(arg)
end

-- ======== 服务启动 ========
skynet.start(function()
    skynet.dispatch("lua", function(_session, _source, cmd, ...)
        local f = CMD[cmd]
        if f then
            skynet.ret(skynet.pack(f(...)))
        end
    end)
    skynet.register ".service_name"
    skynet.error("[service_name] started")
end)
```

### 5.2 Agent Handler 签名

```lua
function H.handler_name(ctx, args, response, err_response)
    -- ctx:        agent 上下文（player_id 等）
    -- args:       协议请求参数
    -- response:   成功响应回调
    -- err_response: 错误响应回调
end
```

### 5.3 日志

```lua
skynet.error("[bag] service started")
skynet.error("[agent] player " .. player_id .. " loaded")
skynet.error("[agent] handler error:", err)
```

---

## 6. 注释规范

### 6.1 文件头

```lua
-- {文件名}: {用途说明}
-- {补充说明（持久化方式、架构模式等）}
```

### 6.2 函数注释

```lua
-- 获取玩家背包
-- @param player_id: number 玩家 ID
-- @return table { items, gold, capacity }
```

简单函数可省略注释，复杂逻辑必须写。使用中文注释。

### 6.3 自动生成标记

```lua
-- auto-generated by tools/sprotogen.py -- do not edit
-- auto-generated by tools/export_config.py -- do not edit
```

---

## 7. Sproto 协议规范

### 7.1 文件组织

```
proto/
  {module}_c2s.sproto      -- C → S 请求
  {module}_s2c.sproto      -- S → C 推送
  {module}_public.sproto   -- 共享类型
```

### 7.2 协议编号分配

| 范围 | 模块 |
|------|------|
| 1 - 29 | 通用 |
| 30 - 59 | Bag/物品 |
| 60 - 89 | 聊天 |
| 90 - 119 | 排行榜 |
| 120 - 179 | 场景 |
| 180+ | 后续模块 |

### 7.3 响应格式

```sproto
.some_response {
    ok 0 : boolean
    errcode 1 : integer
    errmsg 2 : string
    -- ...业务字段
}
```

---

## 8. 数据库访问规范

### 8.1 分层架构

```
Agent Handler ──→ Game Service ──→ DB Proxy
                    ↑                  ↑
              skynet.call()      skynet.call()
```

- `agent/handlers/` **不直接** 调用 DB Proxy
- `service/game/` 是业务逻辑层
- `service/db/` 是数据访问层，只做 CRUD

### 8.2 DB Proxy 返回格式

```lua
-- 成功
return { ok = true, data = result }

-- 失败
return { badresult = true, err = "description" }
```

---

## 9. 工具链

### 9.1 配置文件

| 文件 | 作用 |
|------|------|
| `.editorconfig` | 统一编辑器缩进、行尾、编码 |
| `.stylua.toml` | StyLua 格式化规则 |
| `.luacheckrc` | luacheck Lint 规则 |

### 9.2 安装

```bash
# 安装 Lua（任选一种）
winget install DEVCOM.Lua             # Windows
sudo apt install lua5.1               # Linux

# 安装 LuaRocks
# 从 https://luarocks.org/ 下载安装包

# 安装 luacheck
luarocks install luacheck
```

### 9.3 检查

```bash
luacheck server/                # 全项目扫描
luacheck server/service/agent/  # 指定目录
luacheck server/module/const.lua # 指定文件

# 配合 StyLua 格式化检查
stylua --check server/          # 格式检查
stylua server/                  # 自动格式化
```

### 9.4 luacheck 常用配置说明

当前项目的 `.luacheckrc` 核心规则：

```lua
-- 忽略项
ignore = {
    "212",  -- 未使用的参数（Skynet _session/_source 等回调参数）
    "431",  -- 未使用的影子变量定义
}

-- 白名单全局变量
globals = {
    "skynet",   -- Skynet 框架全局
}

-- 行宽限制
max_line_length = 120
```

> 完整警告代码列表：`luacheck --codes`

---

## 10. 提交检查清单

- [ ] 无全局变量泄露（均使用 `local`）
- [ ] 无未使用的变量或 `require`
- [ ] 文件/变量/函数命名 `snake_case`，常量 `UPPER_CASE`
- [ ] 使用 Tab 缩进
- [ ] 远程调用有 `pcall` 保护
- [ ] 错误码使用 `const.ERROR` 枚举
- [ ] 日志格式 `[service_name] message`
- [ ] 模块导出 `local M = {}` + `return M`
- [ ] 服务遵循 CMD + skynet.start 模板
- [ ] 文件末尾有空行
- [ ] 自动生成文件有 "do not edit" 标记
- [ ] 新代码遵循本规范，旧代码逐步迁移

---

## 附录：推荐写法与不推荐写法对比

```lua
-- ✅ 推荐
local player_id = args.player_id
if not player_id then
    return err_response(const.ERROR.MISSING_PARAMS, "missing player_id")
end
local ok, result = pcall(skynet.call, ".player", "lua", "get", player_id)
if not ok then
    return err_response(const.ERROR.SERVICE_UNAVAILABLE, "service error")
end
skynet.error("[bag] player " .. player_id .. " loaded")

-- ❌ 不推荐
local pid = args.player_id          -- 缩写不清晰
if pid == nil then                  -- 风格不一致
    return err_response(2, "no id") -- 硬编码错误码
end
local ret = skynet.call(".player", "lua", "get", pid)  -- 无 pcall
skynet.error(string.format("[bag] player %d loaded", pid))
```
