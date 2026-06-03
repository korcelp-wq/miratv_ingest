-- MiraTV EPG spine worker DB logging objects
-- Date: 2026-06-03
-- Purpose:
--   Register EPG pipeline as a DB-backed media refresh spine stage.
--
-- Worker:
--   worker_key = epg_legacy_file_pipeline
--   stage_key  = media_refresh.epg
--
-- This is append-only event logging. The latest status is derived by view.

CREATE TABLE IF NOT EXISTS xpdgxfsp_content.spine_worker_event_log (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  run_id VARCHAR(128) NOT NULL,
  worker_key VARCHAR(128) NOT NULL,
  stage_key VARCHAR(128) NOT NULL,
  environment VARCHAR(64) NULL,
  status VARCHAR(32) NOT NULL,
  event_type VARCHAR(32) NOT NULL,
  signal_key VARCHAR(128) NOT NULL,
  disposition VARCHAR(128) NULL,
  metrics_json LONGTEXT NULL,
  report_csv VARCHAR(512) NULL,
  summary_json VARCHAR(512) NULL,
  error_message TEXT NULL,
  event_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_spine_worker_event_log_worker_stage_event_at (worker_key, stage_key, event_at),
  KEY ix_spine_worker_event_log_run_id (run_id),
  KEY ix_spine_worker_event_log_signal (signal_key),
  KEY ix_spine_worker_event_log_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DROP PROCEDURE IF EXISTS xpdgxfsp_content.sp_record_spine_worker_event;

DELIMITER $$

CREATE PROCEDURE xpdgxfsp_content.sp_record_spine_worker_event(
  IN p_run_id VARCHAR(128),
  IN p_worker_key VARCHAR(128),
  IN p_stage_key VARCHAR(128),
  IN p_environment VARCHAR(64),
  IN p_status VARCHAR(32),
  IN p_event_type VARCHAR(32),
  IN p_signal_key VARCHAR(128),
  IN p_disposition VARCHAR(128),
  IN p_metrics_json LONGTEXT,
  IN p_report_csv VARCHAR(512),
  IN p_summary_json VARCHAR(512),
  IN p_error_message TEXT
)
BEGIN
  INSERT INTO xpdgxfsp_content.spine_worker_event_log (
    run_id,
    worker_key,
    stage_key,
    environment,
    status,
    event_type,
    signal_key,
    disposition,
    metrics_json,
    report_csv,
    summary_json,
    error_message
  )
  VALUES (
    p_run_id,
    p_worker_key,
    p_stage_key,
    p_environment,
    p_status,
    p_event_type,
    p_signal_key,
    p_disposition,
    p_metrics_json,
    p_report_csv,
    p_summary_json,
    p_error_message
  );
END$$

DELIMITER ;

CREATE OR REPLACE VIEW xpdgxfsp_content.v_spine_worker_latest_status AS
SELECT
  l.worker_key,
  l.stage_key,
  l.environment,
  l.run_id,
  l.status,
  l.event_type,
  l.signal_key,
  l.disposition,
  l.metrics_json,
  l.report_csv,
  l.summary_json,
  l.error_message,
  l.event_at
FROM xpdgxfsp_content.spine_worker_event_log l
INNER JOIN (
  SELECT
    worker_key,
    stage_key,
    MAX(id) AS max_id
  FROM xpdgxfsp_content.spine_worker_event_log
  GROUP BY worker_key, stage_key
) x
  ON x.max_id = l.id;

CREATE OR REPLACE VIEW xpdgxfsp_content.v_spine_worker_epg_status AS
SELECT
  worker_key,
  stage_key,
  environment,
  run_id,
  status,
  event_type,
  signal_key,
  disposition,
  metrics_json,
  report_csv,
  summary_json,
  error_message,
  event_at
FROM xpdgxfsp_content.v_spine_worker_latest_status
WHERE worker_key = 'epg_legacy_file_pipeline'
  AND stage_key = 'media_refresh.epg';
