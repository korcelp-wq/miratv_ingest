-- =====================================================
-- MiraTV Perception Views (OPS Focus)
-- Database: xpdgxfsp_ops
-- Consumer: LLM perspective formation only
-- =====================================================
-- 
-- These views materialize foci for LLM perception.
-- They do NOT represent intent, publish, or log.
-- They are pure perception derived from stored procedure outputs.
-- 
-- Stored procedures remain authoritative and unchanged.
-- Duplication between procedures and views is intentional.
-- =====================================================

USE xpdgxfsp_ops;

-- =====================================================
-- View: vw_focus_ops
-- Focus: Operational capacity and job execution health
-- Derived from: report_ops_capacity() output + job_runs table
-- Consumer: MC / LLM perspective only
-- =====================================================
CREATE OR REPLACE VIEW vw_focus_ops AS
SELECT
  'ops' AS focus_name,
  'xpdgxfsp_ops' AS source_component,
  NOW() AS record_time,
  COUNT(*) AS total_runs,
  SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) AS active_runs,
  SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed_runs,
  SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) AS success_runs,
  (1 - (SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0))) AS capacity_score,
  MAX(created_at) AS latest_run_time,
  MIN(created_at) AS earliest_run_time
FROM job_runs
WHERE created_at >= DATE_SUB(NOW(), INTERVAL 24 HOUR);

-- =====================================================
-- View: vw_focus_system
-- Focus: System-level job activity over time
-- Derived from: job_runs table
-- Consumer: MC / LLM perspective only
-- Purpose: Enable LLM to reason about system health trends
-- =====================================================
CREATE OR REPLACE VIEW vw_focus_system AS
SELECT
  'system' AS focus_name,
  'xpdgxfsp_ops' AS source_component,
  created_at AS record_time,
  job_key,
  environment,
  status,
  started_at,
  finished_at,
  TIMESTAMPDIFF(SECOND, started_at, COALESCE(finished_at, NOW())) AS duration_sec,
  exit_code,
  summary
FROM job_runs
ORDER BY created_at DESC
LIMIT 1000;

-- =====================================================
-- END OF OPS FOCUS VIEWS
-- =====================================================
