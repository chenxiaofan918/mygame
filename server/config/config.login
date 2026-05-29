include "config.path"

-- 基础配置
thread = 4
logger = nil
logpath = "./log"
harbor = 0
start = "main.login"
bootstrap = "snlua bootstrap"
-- daemon = "./skynet.pid"

-- 登录服配置
name = "login-server"
port = 8887
max_client = 512
debug_port = 8001

-- 数据库配置
db_host = "127.0.0.1"
db_port = 3306
db_name = "game"
db_user = "root"
db_password = "123456"

-- Redis配置
redis_host = "127.0.0.1"
redis_port = 6379
redis_password = "123456"

-- 本地覆盖（由 run.sh 生成，不提交到 Git）
include "config.local"