#!/bin/bash
# ============================================
# Skynet Game Server — 一键部署启动脚本
# 用法:
#   ./run.sh              完整部署 + 启动
#   ./run.sh start        仅启动服务
#   ./run.sh stop         停止服务
#   ./run.sh restart      重启服务
#   ./run.sh status       查看状态
# ============================================

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKYNET_DIR="$PROJECT_DIR/3rd/skynet"
SKYNET_BIN="$SKYNET_DIR/skynet"
CONFIG="$PROJECT_DIR/server/config/config.game"
SCHEMA="$PROJECT_DIR/server/schema.sql"

MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-}"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================
# 检查运行环境
# ============================================
check_env() {
	log_info "检查运行环境..."

	if [ ! -f /etc/os-release ]; then
		log_error "仅支持 Linux"
		exit 1
	fi
	. /etc/os-release
	log_ok "系统: $ID $VERSION_ID"

	ARCH=$(uname -m)
	log_ok "架构: $ARCH"

	if ! command -v sudo &>/dev/null; then
		log_error "需要 sudo，请安装: apt install sudo"
		exit 1
	fi
}

# ============================================
# 安装系统依赖
# ============================================
install_deps() {
	log_info "安装系统依赖..."

	if command -v apt &>/dev/null; then
		sudo apt update
		sudo apt install -y build-essential git libreadline-dev \
			mariadb-server redis-server python3
	elif command -v yum &>/dev/null; then
		sudo yum groupinstall -y "Development Tools"
		sudo yum install -y git readline-devel \
			mariadb-server redis python3
	else
		log_error "不支持的包管理器（仅支持 apt/yum）"
		exit 1
	fi

	log_ok "系统依赖安装完成"
}

# ============================================
# 初始化 MySQL
# ============================================
setup_mysql() {
	log_info "配置 MySQL..."

	if command -v mysqld &>/dev/null; then
		sudo mysqld --user=mysql --datadir=/var/lib/mysql &>/dev/null &
		sleep 2
	fi
	sudo service mysql start 2>/dev/null || sudo systemctl start mysql 2>/dev/null || true

	for i in $(seq 1 30); do
		if sudo mysqladmin ping --silent 2>/dev/null; then
			break
		fi
		sleep 1
	done

	if ! sudo mysqladmin ping --silent 2>/dev/null; then
		log_error "MySQL 启动失败，请手动检查"
		exit 1
	fi
	log_ok "MySQL 已启动"

	# 先用 MYSQL_ROOT_PASS 环境变量，没有则依次尝试无密码和有密码
	local root_pass="${MYSQL_ROOT_PASS:-123456}"
	local mysql_login="sudo mysql -u root"
	# 测试无密码登录
	if ! sudo mysql -u root -e "SELECT 1;" &>/dev/null; then
		mysql_login="mysql -u root -p'$root_pass' -h 127.0.0.1"
		if ! mysql -u root -p"$root_pass" -h 127.0.0.1 -e "SELECT 1;" &>/dev/null; then
			log_error "无法登录 MySQL，请检查 root 密码"
			log_error "尝试: sudo mysql -u root -p'你的密码' < $SCHEMA"
			return 1
		fi
		log_info "使用密码登录 MySQL"
	fi

	log_info "创建数据库和表..."
	eval "$mysql_login" < "$SCHEMA"

	local tables
	tables=$(eval "$mysql_login" -e "USE game; SHOW TABLES;" 2>/dev/null)

	if echo "$tables" | grep -q "account"; then
		log_ok "数据库初始化完成（game.account / game.player）"
	else
		log_warn "建表可能未成功，请手动检查: sudo mysql -u root < $SCHEMA"
	fi

	# 配置 root 密码（与 config.game 保持一致）
	eval "$mysql_login" -e "ALTER USER IF EXISTS 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '123456';" 2>/dev/null
	eval "$mysql_login" -e "ALTER USER IF EXISTS 'root'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '123456';" 2>/dev/null
	eval "$mysql_login" -e "FLUSH PRIVILEGES;" 2>/dev/null
	# 验证密码登录
	if mysql -u root -p'123456' -h 127.0.0.1 -e "SELECT 1;" &>/dev/null; then
		log_ok "root 密码已配置"
	else
		log_warn "root 密码配置失败，请手动检查"
	fi
}

# ============================================
# 初始化 Redis
# ============================================
setup_redis() {
	log_info "配置 Redis..."
	sudo service redis-server start 2>/dev/null || sudo systemctl start redis 2>/dev/null || true

	for i in $(seq 1 10); do
		if redis-cli ping 2>/dev/null | grep -q "PONG"; then
			break
		fi
		sleep 1
	done

	if redis-cli ping 2>/dev/null | grep -q "PONG"; then
		log_ok "Redis 已启动"
		# 开发环境关闭密码，与config.game保持一致
		redis-cli CONFIG SET requirepass "123456" 2>/dev/null || true
	else
		log_error "Redis 启动失败，请手动检查"
		exit 1
	fi
}

# ============================================
# 编译 skynet
# ============================================
build_skynet() {
	log_info "编译 skynet..."

	# 如果子模块未初始化，自动初始化
	if [ ! -f "$SKYNET_DIR/Makefile" ]; then
		log_info "初始化子模块 skynet..."
		git submodule update --init --recursive
	fi

	cd "$SKYNET_DIR"
	make linux MALLOC_STATICLIB= SKYNET_DEFINES=-DNOUSE_JEMALLOC -j$(nproc) 2>&1 | tail -5
	cd "$PROJECT_DIR"

	if [ -f "$SKYNET_BIN" ]; then
		log_ok "skynet 编译完成: $SKYNET_BIN"
	else
		log_error "编译失败，请手动执行: cd 3rd/skynet && make linux"
		exit 1
	fi
}

# ============================================
# 检查配置文件
# ============================================
check_config() {
	log_info "检查配置文件..."

	if [ ! -f "$CONFIG" ]; then
		log_error "配置文件不存在: $CONFIG"
		exit 1
	fi

	local cfg_pass
	cfg_pass=$(grep "^db_password" "$CONFIG" | grep -o '"[^"]*"' | head -1 | tr -d '"')
	if [ -z "$cfg_pass" ] && [ -n "$MYSQL_ROOT_PASS" ]; then
		log_warn "配置文件中 db_password 为空，而 MYSQL_ROOT_PASS 已设置"
		log_warn "请编辑 $CONFIG 设置 db_password"
	fi

	log_ok "配置文件就绪"
}

# ============================================
# 清理旧日志
# ============================================
clean_logs() {
	log_info "清理旧日志..."
	rm -f "$PROJECT_DIR/log/"*.log
	log_ok "日志已清理"
}

# ============================================
# 启动游戏服务器
# ============================================
start_server() {
	log_info "启动游戏服务器..."

	if [ -f "$PROJECT_DIR/skynet.pid" ]; then
		local pid
		pid=$(cat "$PROJECT_DIR/skynet.pid" 2>/dev/null)
		if kill -0 "$pid" 2>/dev/null; then
			log_warn "游戏服务器已在运行 (PID: $pid)"
			return 0
		fi
		rm -f "$PROJECT_DIR/skynet.pid"
	fi

	cd "$PROJECT_DIR"
	mkdir -p log
	local logfile="log/game-server-$(date +%Y%m%d).log"
	"$SKYNET_BIN" "$CONFIG" >> "$logfile" 2>&1 &
	local pid=$!
	echo $pid > "$PROJECT_DIR/skynet.pid"

	sleep 2
	if kill -0 $pid 2>/dev/null; then
		log_ok "游戏服务器已启动 (PID: $pid, 端口: 8888)"
		log_info "查看日志: tail -f $logfile"
	else
		log_error "启动失败，请检查日志: $logfile"
		return 1
	fi
}

# ============================================
# 停止游戏服务器
# ============================================
stop_server() {
	log_info "停止游戏服务器..."

	if [ -f "$PROJECT_DIR/skynet.pid" ]; then
		local pid
		pid=$(cat "$PROJECT_DIR/skynet.pid" 2>/dev/null)
		if kill -0 "$pid" 2>/dev/null; then
			kill "$pid"
			rm -f "$PROJECT_DIR/skynet.pid"
			log_ok "游戏服务器已停止 (PID: $pid)"
		else
			rm -f "$PROJECT_DIR/skynet.pid"
			log_warn "PID 文件存在但进程已不存在"
		fi
	else
		local pid
		pid=$(ss -tlnp 2>/dev/null | grep ":8888" | grep -oP 'pid=\K\d+' || true)
		if [ -n "$pid" ]; then
			kill "$pid"
			log_ok "游戏服务器已停止 (PID: $pid)"
		else
			log_warn "没有运行中的游戏服务器"
		fi
	fi
}

# ============================================
# 查看状态
# ============================================
show_status() {
	echo ""
	echo "===== 服务状态 ====="

	if command -v mysqladmin &>/dev/null && mysqladmin ping --silent 2>/dev/null; then
		echo -e "  MySQL:     ${GREEN}运行中${NC}"
	else
		echo -e "  MySQL:     ${RED}未运行${NC}"
	fi

	if redis-cli ping 2>/dev/null | grep -q "PONG"; then
		echo -e "  Redis:     ${GREEN}运行中${NC}"
	else
		echo -e "  Redis:     ${RED}未运行${NC}"
	fi

	if [ -f "$PROJECT_DIR/skynet.pid" ]; then
		local pid
		pid=$(cat "$PROJECT_DIR/skynet.pid" 2>/dev/null)
		if kill -0 "$pid" 2>/dev/null; then
			echo -e "  游戏服:    ${GREEN}运行中 (PID: $pid)${NC}"
			echo -e "  监听端口:  8888"
		else
			echo -e "  游戏服:    ${RED}PID 文件存在但进程已死${NC}"
		fi
	else
		echo -e "  游戏服:    ${YELLOW}未启动${NC}"
	fi

	if [ -f "$SKYNET_BIN" ]; then
		echo -e "  skynet:    ${GREEN}已编译${NC}"
	else
		echo -e "  skynet:    ${RED}未编译${NC}"
	fi
	echo ""
}

# ============================================
# 一键部署（完整流程）
# ============================================
deploy() {
	echo ""
	echo "========================================"
	echo "  Skynet Game Server — 一键部署"
	echo "========================================"
	echo ""

	check_env
	install_deps
	setup_mysql
	setup_redis
	build_skynet
	check_config
	start_server

	echo ""
	echo "========================================"
	echo -e "  ${GREEN}部署完成!${NC}"
	echo ""
	echo "  服务器:   localhost:8888"
	echo "  测试:     python3 client/tools/test_auto.py"
	echo "  日志:     tail -f log/game-server.log"
	echo "  停止:     ./run.sh stop"
	echo "========================================"
	echo ""
}

# ============================================
# 主入口
# ============================================
case "${1:-deploy}" in
	deploy)
		deploy
		;;
	start)
		check_config
		# 如果 skynet 未编译则自动编译
		if [ ! -f "$SKYNET_BIN" ]; then
			log_info "skynet 二进制不存在，先执行编译..."
			build_skynet
		fi
		start_server
		;;
	stop)
		stop_server
		;;
	restart)
		stop_server
		sleep 1
		clean_logs
		start_server
		;;
	clean)
		clean_logs
		;;
	status)
		show_status
		;;
	*)
		echo "用法: $0 {deploy|start|stop|restart|status}"
		echo ""
		echo "  deploy   一键部署 + 启动（首次使用）"
		echo "  start    仅启动游戏服务器"
		echo "  stop     停止游戏服务器"
		echo "  restart  重启游戏服务器（自动清日志）"
		echo "  clean    清理日志文件"
		echo "  status   查看所有服务状态"
		exit 1
		;;
esac
