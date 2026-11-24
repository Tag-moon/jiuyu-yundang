-- 九曲云档 · 华为云 RDS for MySQL 初始化脚本
-- 在 RDS 控制台创建数据库 jiuyu_yundang 后执行本文件。

CREATE TABLE IF NOT EXISTS heritage_site (
  id VARCHAR(64) NOT NULL COMMENT '遗址标识',
  name VARCHAR(128) NOT NULL,
  city VARCHAR(64) NOT NULL,
  era VARCHAR(32) NOT NULL,
  type VARCHAR(64) NOT NULL,
  type_desc VARCHAR(64) DEFAULT '',
  dynasty VARCHAR(128) DEFAULT '',
  summary VARCHAR(512) DEFAULT '',
  image VARCHAR(128) DEFAULT '',
  detail_json JSON NOT NULL COMMENT '完整档案 JSON，API 按需解析',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_city (city),
  KEY idx_era (era),
  KEY idx_type (type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS chat_message (
  id BIGINT NOT NULL AUTO_INCREMENT,
  user_id VARCHAR(128) NOT NULL DEFAULT 'anonymous',
  question TEXT NOT NULL,
  answer TEXT NOT NULL,
  sources JSON DEFAULT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_user_created (user_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS user_sync_state (
  user_id VARCHAR(128) NOT NULL,
  payload JSON NOT NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 初始档案数据由 scripts/import-heritages.js 生成，执行：
-- mysql -h <RDS_HOST> -u <RDS_USER> -p jiuyu_yundang < scripts/seed.sql
