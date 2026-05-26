-- Signal and Heartbeat Schema Contract (2026-05-26)
-- Purpose: Persist implementation-level evidence for logging, heartbeat, and signal gates.

CREATE TABLE IF NOT EXISTS ops_signal_events (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  signal_name VARCHAR(128) NOT NULL,
  p0_item VARCHAR(16) NOT NULL,
  run_id VARCHAR(128) NOT NULL,
  component VARCHAR(128) NOT NULL,
  worker_name VARCHAR(128) NOT NULL,
  environment VARCHAR(32) NOT NULL DEFAULT 'prod',
  status VARCHAR(32) NOT NULL,
  signal_value VARCHAR(255) NULL,
  value_num DECIMAL(18,6) NULL,
  allowed_values VARCHAR(255) NULL,
  source_table_or_endpoint VARCHAR(255) NULL,
  mac_user_id VARCHAR(128) NULL,
  screen_type VARCHAR(64) NULL,
  error_code VARCHAR(64) NULL,
  error_message TEXT NULL,
  severity VARCHAR(32) NOT NULL DEFAULT 'info',
  dashboard_panel VARCHAR(128) NULL,
  widget_key VARCHAR(128) NULL,
  owner VARCHAR(128) NULL,
  kill_switch_name VARCHAR(128) NULL,
  emitted_at DATETIME NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_signal_name_emitted_at (signal_name, emitted_at),
  KEY idx_component_emitted_at (component, emitted_at),
  KEY idx_run_id (run_id)
);

CREATE TABLE IF NOT EXISTS ops_worker_heartbeats (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  worker_name VARCHAR(128) NOT NULL,
  component VARCHAR(128) NOT NULL,
  run_id VARCHAR(128) NOT NULL,
  environment VARCHAR(32) NOT NULL DEFAULT 'prod',
  heartbeat_status VARCHAR(32) NOT NULL,
  heartbeat_interval_seconds INT NOT NULL,
  stale_after_seconds INT NOT NULL,
  last_heartbeat_at DATETIME NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_worker_run (worker_name, run_id),
  KEY idx_worker_last_heartbeat (worker_name, last_heartbeat_at),
  KEY idx_component_last_heartbeat (component, last_heartbeat_at)
);

CREATE TABLE IF NOT EXISTS ops_automation_contract_status (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  component VARCHAR(128) NOT NULL,
  owner VARCHAR(128) NOT NULL,
  logging_enabled TINYINT(1) NOT NULL DEFAULT 0,
  heartbeat_enabled TINYINT(1) NOT NULL DEFAULT 0,
  signal_emitted TINYINT(1) NOT NULL DEFAULT 0,
  dashboard_mapped TINYINT(1) NOT NULL DEFAULT 0,
  kill_switch_defined TINYINT(1) NOT NULL DEFAULT 0,
  contract_status VARCHAR(32) NOT NULL DEFAULT 'blocked',
  notes TEXT NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_component (component)
);

-- Reference query: gate compliance rollup
-- A unit is compliant only when all five flags are 1.
-- SELECT component,
--        CASE WHEN logging_enabled=1
--               AND heartbeat_enabled=1
--               AND signal_emitted=1
--               AND dashboard_mapped=1
--               AND kill_switch_defined=1
--             THEN 'compliant' ELSE 'blocked' END AS gate_status
-- FROM ops_automation_contract_status;
