-- ============================================
-- Game Database Schema
-- ============================================
-- 注意：游戏业务数据已迁移至 MongoDB
-- MySQL 仅用于玩家操作日志存储（运营后台分析用）

CREATE DATABASE IF NOT EXISTS `game` DEFAULT CHARACTER SET utf8mb4;
USE `game`;

-- --------------------------------------------
-- 玩家操作日志表（按月分区）
-- --------------------------------------------
CREATE TABLE IF NOT EXISTS `player_action_log` (
	`id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
	`player_id`  BIGINT UNSIGNED NOT NULL COMMENT '玩家ID',
	`action`     VARCHAR(32)     NOT NULL COMMENT '操作类型: login/logout/chat/enter_scene/move/use_item/buy',
	`params`     JSON            NOT NULL COMMENT '操作参数，结构随 action 变化',
	`ip`         VARCHAR(45)     NOT NULL DEFAULT '' COMMENT '客户端IP',
	`device`     VARCHAR(128)    NOT NULL DEFAULT '' COMMENT '设备标识',
	`created_at` DATETIME(3)     NOT NULL COMMENT '精确到毫秒',
	PRIMARY KEY (`id`, `created_at`),
	INDEX `idx_player_time` (`player_id`, `created_at`),
	INDEX `idx_action_time` (`action`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
PARTITION BY RANGE (TO_DAYS(`created_at`)) (
	PARTITION p202605 VALUES LESS THAN (TO_DAYS('2026-06-01')),
	PARTITION p202606 VALUES LESS THAN (TO_DAYS('2026-07-01')),
	PARTITION p202607 VALUES LESS THAN (TO_DAYS('2026-08-01')),
	PARTITION p_future VALUES LESS THAN MAXVALUE
);
