-- phpMyAdmin SQL Dump
-- version 5.2.2
-- https://www.phpmyadmin.net/
--
-- Host: localhost:3306
-- Generation Time: Mar 16, 2026 at 11:35 AM
-- Server version: 10.6.24-MariaDB-cll-lve
-- PHP Version: 8.3.26

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `xpdgxfsp_cortex`
--

DELIMITER $$
--
-- Procedures
--
CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `report_cortex_constraints` ()   BEGIN
  SELECT
    COUNT(*)                          AS active_policies,
    SUM(enabled = 1)                  AS enabled_rules,
    NOW()                              AS as_of
  FROM gov_policy_rules
  WHERE enabled = 1;
END$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_discover_available_procedures` (IN `p_requesting_component` VARCHAR(255))  READS SQL DATA BEGIN
    SELECT 
        sp_name,
        source_db,
        purpose,
        return_fields,
        parameters,
        access_level
    FROM sp_cross_db_catalog
    ORDER BY sp_name;
END$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_get_all_component_contexts` ()   SELECT * FROM cm_system_context_snapshots ORDER BY component_name$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_get_component_context` (IN `p_component` VARCHAR(255))   SELECT * FROM cm_system_context_snapshots WHERE component_name = p_component ORDER BY snapshot_date DESC LIMIT 1$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_get_context_access_log` ()   SELECT * FROM ai_context_access_log ORDER BY accessed_at DESC LIMIT 100$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_get_context_access_patterns` ()  READS SQL DATA BEGIN
    SELECT 
        accessing_component,
        accessed_component,
        COUNT(*) as access_count,
        MAX(accessed_at) as last_accessed,
        MIN(accessed_at) as first_accessed,
        AVG(record_count) as avg_records_accessed,
        JSON_ARRAYAGG(DISTINCT query_type) as query_types
    FROM ai_context_access_log
    GROUP BY accessing_component, accessed_component
    ORDER BY access_count DESC;
END$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_get_full_context_report` (IN `p_component_name` VARCHAR(255))  READS SQL DATA BEGIN
    SELECT 
        report_id,
        component_name,
        report_status,
        report_content,
        published_at,
        published_by,
        report_version
    FROM published_context_reports
    WHERE component_name = p_component_name AND report_status = 'published'
    ORDER BY published_at DESC LIMIT 1;
END$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_get_publication_history` (IN `p_component_name` VARCHAR(255))  READS SQL DATA BEGIN
    SELECT 
        report_id,
        report_version,
        report_status,
        published_at,
        published_by,
        created_at,
        updated_at
    FROM published_context_reports
    WHERE component_name = p_component_name
    ORDER BY report_version DESC, published_at DESC;
END$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_get_publication_status` ()  READS SQL DATA BEGIN
    SELECT 
        COALESCE(component_name, 'UNKNOWN') as component_name,
        report_status,
        COUNT(*) as report_count,
        MAX(published_at) as last_published,
        MAX(report_version) as latest_version
    FROM published_context_reports
    GROUP BY component_name, report_status
    ORDER BY component_name, report_status;
END$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_get_published_context_reports` ()  READS SQL DATA BEGIN
    SELECT 
        report_id,
        component_name,
        report_status,
        published_at,
        published_by,
        report_version,
        CHAR_LENGTH(report_content) as content_bytes
    FROM published_context_reports
    WHERE report_status = 'published'
    ORDER BY published_at DESC;
END$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_publish_context_report` (IN `p_component_name` VARCHAR(255), IN `p_published_by` VARCHAR(100))  MODIFIES SQL DATA BEGIN
    DECLARE v_report_content LONGTEXT;
    DECLARE v_confidence VARCHAR(100);
    DECLARE v_snapshot_date DATE;
    
    SELECT confidence_level, snapshot_date INTO v_confidence, v_snapshot_date
    FROM cm_system_context_snapshots
    WHERE component_name = p_component_name
    ORDER BY snapshot_date DESC LIMIT 1;
    
    SET v_report_content = CONCAT(
        '# CONTEXT REPORT: ', p_component_name, '\n\n',
        '**Status**: Published\n',
        '**Date**: ', CURDATE(), '\n',
        '**Version**: 1\n',
        '**Authority**: ', p_published_by, '\n\n',
        '## Context Summary\n',
        'Component: ', p_component_name, '\n',
        'Snapshot Date: ', v_snapshot_date, '\n',
        'Confidence Level: ', v_confidence, '\n\n',
        '## Latest Context\n',
        '(Content follows from cm_system_context_snapshots)\n\n',
        '## Access Patterns\n',
        '(Tracked in ai_context_access_log)\n\n',
        '---\n',
        'Generated: ', NOW(), ' | Published By: ', p_published_by
    );
    
    INSERT INTO published_context_reports 
    (component_name, report_type, report_status, report_content, report_version, published_at, published_by)
    VALUES (p_component_name, 'context_summary', 'published', v_report_content, 1, NOW(), p_published_by);
END$$

DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `ai_component_learning_log`
--

CREATE TABLE `ai_component_learning_log` (
  `learning_id` bigint(20) NOT NULL,
  `component_name` varchar(255) DEFAULT NULL,
  `learning_phase` varchar(100) DEFAULT NULL,
  `milestone` text DEFAULT NULL,
  `confidence` decimal(5,2) DEFAULT NULL,
  `learned_at` datetime DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `ai_component_registry`
--

CREATE TABLE `ai_component_registry` (
  `component_id` bigint(20) NOT NULL,
  `component_name` varchar(255) DEFAULT NULL,
  `component_type` varchar(100) DEFAULT NULL,
  `status` varchar(50) DEFAULT 'learning',
  `home_database` varchar(100) DEFAULT NULL,
  `description` text DEFAULT NULL,
  `created_at` datetime DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

--
-- Dumping data for table `ai_component_registry`
--

INSERT INTO `ai_component_registry` (`component_id`, `component_name`, `component_type`, `status`, `home_database`, `description`, `created_at`) VALUES
(1, 'LLM', 'reasoning', 'learning', 'callosum_matrix', 'Language model - explanation, synthesis, coordination', '2026-01-29 16:12:25'),
(2, 'NeuroNet', 'pattern_detection', 'learning', 'lake_vector', 'Pattern detection - anomalies, signals, scoring', '2026-01-29 16:12:29'),
(3, 'ML', 'forecasting', 'learning', 'ops', 'Machine learning - capacity, performance, optimization', '2026-01-29 16:12:34'),
(4, 'GenAI', 'insight_generation', 'learning', 'i_m_g_vector_context', 'Generative AI - proposals, classifications, candidate rules', '2026-01-29 16:12:38'),
(5, 'VectorDB Agent', 'knowledge_navigation', 'learning', 'lake_knowledge', 'Vector search - semantic similarity, knowledge discovery', '2026-01-29 16:12:43'),
(6, 'LocalAI', 'embedded_reasoning', 'learning', 'cortex', 'Local on-device reasoning - edge inference', '2026-01-29 16:12:48');

-- --------------------------------------------------------

--
-- Table structure for table `ai_context_access_log`
--

CREATE TABLE `ai_context_access_log` (
  `access_id` bigint(20) UNSIGNED NOT NULL,
  `accessing_component` varchar(255) NOT NULL,
  `accessed_component` varchar(255) NOT NULL,
  `accessed_at` datetime(6) DEFAULT current_timestamp(6),
  `accessed_from_db` varchar(100) NOT NULL,
  `query_type` varchar(50) DEFAULT NULL,
  `record_count` int(11) DEFAULT NULL,
  `flags` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`flags`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `ai_memory_index`
--

CREATE TABLE `ai_memory_index` (
  `id` int(11) NOT NULL,
  `source_db` varchar(64) NOT NULL,
  `source_table` varchar(64) NOT NULL,
  `record_id` int(11) NOT NULL,
  `domain` varchar(64) NOT NULL,
  `topic` varchar(128) DEFAULT NULL,
  `unit_type` varchar(64) NOT NULL,
  `summary` text NOT NULL,
  `content_ref` text NOT NULL,
  `confidence` float DEFAULT 0.75,
  `priority_weight` float DEFAULT 1,
  `active` tinyint(1) DEFAULT 1,
  `created_at` datetime DEFAULT current_timestamp(),
  `updated_at` datetime DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `audit_log`
--

CREATE TABLE `audit_log` (
  `audit_id` bigint(20) NOT NULL,
  `actor_type` varchar(32) DEFAULT NULL,
  `actor_id` varchar(128) DEFAULT NULL,
  `action` varchar(128) DEFAULT NULL,
  `target` varchar(128) DEFAULT NULL,
  `payload_json` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`payload_json`)),
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `cm_system_context_snapshots`
--

CREATE TABLE `cm_system_context_snapshots` (
  `snapshot_id` bigint(20) UNSIGNED NOT NULL,
  `component_name` varchar(255) NOT NULL,
  `snapshot_date` date NOT NULL,
  `confidence_level` varchar(50) DEFAULT NULL,
  `context_snapshot` longtext NOT NULL,
  `created_at` datetime(6) DEFAULT current_timestamp(6)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `cm_system_context_snapshots`
--

INSERT INTO `cm_system_context_snapshots` (`snapshot_id`, `component_name`, `snapshot_date`, `confidence_level`, `context_snapshot`, `created_at`) VALUES
(1, 'Grinder / Ingest Pipeline', '2026-01-29', 'High on state, Low on downstream', '<!--\r\nCOPILOT INSTRUCTIONS (READ CAREFULLY):\r\n\r\nYou are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.\r\n\r\nDO:\r\n- Describe intent, pressure, goals, blind spots\r\n- Use plain language\r\n- Leave unknowns explicit\r\n\r\nDO NOT:\r\n- Propose solutions\r\n- Invent metrics\r\n- Write code\r\n- Make decisions\r\n- Use theory language\r\n\r\nThis file is a SITUATIONAL SNAPSHOT, not a design doc.\r\n\r\nComponent: Grinder / Ingest Pipeline\r\n-->\r\n\r\n# Contextual Summary — Grinder / Ingest Pipeline\r\n\r\n## Component Role\r\n\r\nLocal batch processor on `C:miratv_ingest`. Reads raw IPTV provider data (JSON/XML). Normalizes into structured JSON. Queues for database ingest. Produces processed files and quarantine logs for failures.\r\n\r\n## Current Intent\r\n\r\nExtract structured data from unreliable provider feeds without inventing missing fields. Preserve partial truth explicitly. Flag ambiguities and failures for human review. Enable downstream database ingest with confidence.\r\n\r\n## Operating Mode\r\n\r\nBatch-oriented workers (C:miratv_ingestworkers). Read raw/ folder. Parse JSON/XML. Extract fields into normalized payloads. Quarantine failures into dedicated directories. Write processed/ outputs. Mark checkpoint files for orchestrator tracking.\r\n\r\n## Frequency & Cadence\r\n\r\nTriggered by PowerShell orchestration (spine scheduler). Currently manual or scheduled nightly. No real-time processing. Single provider at a time or sequential batch runs.\r\n\r\n## Pressures Detected\r\n\r\nProvider data inconsistent (missing fields, renamed keys). Parser failures block entire batches. No graceful degradation for partial data. Manual quarantine review creates bottleneck. Unknown which failures are recoverable vs. genuine data issues.\r\n\r\n## Active Constraints\r\n\r\nLocal filesystem only (no direct DB writes). Must preserve all raw data for audit. Parser logic coupled to specific provider format. Quarantined files accumulate without automated cleanup or re-processing. No real-time feedback from database ingest layer.\r\n\r\n## Short-Horizon Goals (Now → Soon)\r\n\r\nParse more provider formats without code changes. Reduce quarantine pile. Surface grinder failures to governance system. Enable AI-assisted recovery of quarantined records. Track parse success rate per provider.\r\n\r\n## Long-Horizon Goals\r\n\r\nZero manual quarantine intervention. Self-healing grinder that learns provider patterns. AI suggests format fixes. Streaming (not batch) processing. Real-time feedback loop from database → grinder.\r\n\r\n## Blind Spots\r\n\r\nUnclear which quarantined files are fixable vs. permanently malformed. No visibility into downstream ingest failures (grinder succeeded, DB write failed). Unknown provider field semantics (is this field optional or missing due to provider error?). No cross-provider pattern recognition.\r\n\r\n## Friction Points\r\n\r\nGrinder workers run independently; no coordination with other workers. Quarantined files require manual inspection. No integration with governance rules (what should grinder reject vs. accept?). Errors don\'t trigger escalation; they just accumulate in logs.\r\n\r\n## Metrics Currently Used\r\n\r\nFile count (raw, processed, quarantine). Parse success/failure count. Job duration.\r\n\r\n## Metrics Missing\r\n\r\nPer-field extraction confidence. Provider consistency score. Quarantine resolution rate. Downstream ingest success vs. grinder output quality. Time-to-fix for quarantined records.\r\n\r\n## Suggested Stored Procedures (Do Not Exist Yet)\r\n\r\n- `sp_grinder_register_job()` - log start/end of grinder run\r\n- `sp_grinder_log_failure()` - insert quarantine event with provider, file, error reason\r\n- `sp_grinder_get_recoverable_failures()` - query quarantine for retryable patterns\r\n- `sp_grinder_confidence_score()` - return extraction confidence per field per provider\r\n\r\n## Desired Context From Other Components\r\n\r\nGovernance: Which fields are mandatory vs. optional? Ops: What downstream DB failures occurred from grinder output? Lake: Historical provider format patterns (has this field appeared before?). Inhibitor: Rules about what constitutes acceptable partial data.\r\n\r\n## Confidence Level\r\n\r\nHigh on current state (observable filesystem, checkpoint files). Medium on downstream effects (unknown how DB layer sees grinder failures). Low on provider semantics (unclear if missing fields are errors or valid nulls).\r\n\r\n## Notes\r\n\r\nGrinder is effectively a filter and normalizer, not an enforcer. It passes data downstream; database layer decides accept/reject. This separation is intentional but creates blind spot: grinder doesn\'t know if its output is usable.\r\n\r\n', '2026-01-29 15:39:52.925004'),
(2, 'Ops / Orchestration', '2026-01-29', 'High on state, Medium on worker state', '<!--\r\nCOPILOT INSTRUCTIONS (READ CAREFULLY):\r\n\r\nYou are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.\r\n\r\nDO:\r\n- Describe intent, pressure, goals, blind spots\r\n- Use plain language\r\n- Leave unknowns explicit\r\n\r\nDO NOT:\r\n- Propose solutions\r\n- Invent metrics\r\n- Write code\r\n- Make decisions\r\n- Use theory language\r\n\r\nThis file is a SITUATIONAL SNAPSHOT, not a design doc.\r\n\r\nComponent: Ops / Orchestration\r\n-->\r\n\r\n# Contextual Summary — Ops / Orchestration\r\n\r\n## Component Role\r\n\r\nMaster scheduler (spine). Coordinates grinder workers. Triggers ingest sequences via PowerShell. Manages job state via `xpdgxfsp_ops` database. Tracks job_runs, job_definitions, checkpoints, failures, locks.\r\n\r\n## Current Intent\r\n\r\nOrchestrate reliable, repeatable, auditable batch pipelines. Prevent job collisions (locks). Track what ran, when, why. Enable human visibility into pipeline health. Provide state recovery on failure.\r\n\r\n## Operating Mode\r\n\r\nPowerShell-driven scheduling (manual triggers or Windows Task Scheduler). Reads job definitions from DB. Manages locks (acquisition, release). Executes workers sequentially or in parallel. Logs events to job_events table. Marks checkpoints for recovery.\r\n\r\n## Frequency & Cadence\r\n\r\nScheduled nightly or on-demand. Single orchestration run per trigger. Sequential or parallel worker execution within one run. Waits for all workers to complete before marking job_runs complete.\r\n\r\n## Pressures Detected\r\n\r\nJob failures don\'t stop pipeline; jobs just error and continue. No escalation path (critical failures don\'t alert). Lock timeouts are manual (no auto-recovery). Checkpoint logic informal (unclear when to retry). Job state can diverge from actual worker state (ghost jobs).\r\n\r\n## Active Constraints\r\n\r\nSingle-threaded orchestration (one spine run at a time, enforced by DB lock). No distributed orchestration. All state in ops DB (no external job queues). Workers execute on same machine as orchestrator. No cross-system coordination.\r\n\r\n## Short-Horizon Goals (Now → Soon)\r\n\r\nClear visibility into job success/failure. Automated alerts for critical failures. Reliable checkpoint restart (resume from failure point). Distinguish retriable vs. permanent failures.\r\n\r\n## Long-Horizon Goals\r\n\r\nDistributed orchestration (multiple spines). Cross-system job dependencies. Real-time worker health monitoring. Automatic escalation for governance violations.\r\n\r\n## Blind Spots\r\n\r\nWorker state vs. job_runs state (did worker truly complete?). Unknown which failures are transient (network, temp file lock) vs. data (provider format changed). No feedback loop from database ingest (did downstream processes succeed?). Unclear job scheduling priority (which job should run first if queue backs up?).\r\n\r\n## Friction Points\r\n\r\nManual lock management. No built-in retry logic (devs must handle). Workers must handle their own checkpointing (inconsistent). Spine doesn\'t know if downstream (DB ingest) succeeded. Job definitions live in DB but logic lives in scripts (two sources of truth).\r\n\r\n## Metrics Currently Used\r\n\r\nJob duration. Job status (success/fail). Failure count per job.\r\n\r\n## Metrics Missing\r\n\r\nWorker-level state (did worker finish, or did it hang?). Lock wait time. Retry count. Time-to-escalation for failures. Success rate of resumed jobs (recovery viability).\r\n\r\n## Suggested Stored Procedures (Do Not Exist Yet)\r\n\r\n- `sp_job_mark_retriable()` - mark failed job as safe to retry\r\n- `sp_job_mark_permanent_failure()` - mark failed job as irrecoverable\r\n- `sp_job_escalate_to_governance()` - route critical failure to IGM\r\n- `sp_job_get_recovery_state()` - return checkpoint data to resume from\r\n\r\n## Desired Context From Other Components\r\n\r\nGrinder: Which output files are valid? Database: Which grinder output was successfully ingested? Governance: Are job failures violations or expected? Human Operator: Do you want to retry this job or escalate?\r\n\r\n## Confidence Level\r\n\r\nHigh on current state (job_runs table is observable, locks are explicit). Medium on worker state (unclear if worker completed or hung). Low on downstream effects (can\'t see if DB ingest succeeded).\r\n\r\n## Notes\r\n\r\nOrchestration is effectively a state tracker and task sequencer, not an enforcer. It coordinates but doesn\'t validate. This separation is intentional but creates blind spot: spine doesn\'t know if its tasks actually succeeded.\r\n\r\n', '2026-01-29 15:39:57.862359'),
(3, 'Database (Authority)', '2026-01-29', 'High on state, Low on lineage', '<!--\r\nCOPILOT INSTRUCTIONS (READ CAREFULLY):\r\n\r\nYou are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.\r\n\r\nDO:\r\n- Describe intent, pressure, goals, blind spots\r\n- Use plain language\r\n- Leave unknowns explicit\r\n\r\nDO NOT:\r\n- Propose solutions\r\n- Invent metrics\r\n- Write code\r\n- Make decisions\r\n- Use theory language\r\n\r\nThis file is a SITUATIONAL SNAPSHOT, not a design doc.\r\n\r\nComponent: Database (Authority) - xpdgxfsp_* (8 databases)\r\n-->\r\n\r\n# Contextual Summary — Database (Authority)\r\n\r\n## Component Role\r\n\r\nMySQL server hosting 8 databases: lake_knowledge, lake_vector, content, cortex, callosum_matrix, ops, inhibitor_govenor_matrix, i_m_g_vector_context, ip. Enforces constraints. Preserves provenance. Audits all writes. Source of truth for all operational, architectural, governance data.\r\n\r\n## Current Intent\r\n\r\nBe the single authoritative record for system state. Enforce integrity through constraints and keys. Never accept invalid writes. Make truth auditable and traceable. Reject rather than corrupt.\r\n\r\n## Operating Mode\r\n\r\nTransactional writes (explicit INSERT/UPDATE/DELETE). Stored procedures handle complex logic. Views for read-only presentation. Triggers for audit logging (where implemented). No direct ORM access; all writes parameterized.\r\n\r\n## Frequency & Cadence\r\n\r\nContinuous operational writes (series ingest, EPG updates, job state). Nightly batch ingests (grinder → ingest workers → DB). Real-time reads (UI queries, API calls). Periodic archival/cleanup (manual or scripted).\r\n\r\n## Pressures Detected\r\n\r\nSchemas growing without consistent versioning. Different DBs have different table structures (no unified schema). Foreign key constraints sometimes unenforced. Audit trail incomplete (not all tables have created_at/updated_by). Raw API responses stored directly (no normalization layer).\r\n\r\n## Active Constraints\r\n\r\nShared hosting (resources limited). No schema versioning. No cross-database transactions. Limited trigger support (performance concern). Credential exposure in legacy scripts (being phased out with CVI).\r\n\r\n## Short-Horizon Goals (Now → Soon)\r\n\r\nUnified schema pattern across all 8 DBs. Complete audit trail (who wrote, when, why). Enforce foreign keys on content references. Twin write enforcement (inhibitor_govenor_matrix ↔ i_m_g_vector_context).\r\n\r\n## Long-Horizon Goals\r\n\r\nSchema versioning and zero-downtime migrations. Cross-database consistency (replication or eventual consistency pattern). Query-time access control (row-level security). Decentralized autonomy (federation).\r\n\r\n## Blind Spots\r\n\r\nUnknown which applications write to which tables. No query logging (can\'t see what\'s being read). Unknown data lineage (where did this record originate?). No enforcement of \"no direct writes\" policy (legacy apps may bypass control layer).\r\n\r\n## Friction Points\r\n\r\nSchema changes require manual coordination. No automated testing of constraint enforcement. Audit trail requires manual trigger creation. Twin-write logic not automated (relies on application layer). Grinder output stored as JSON (requires post-ingest parsing).\r\n\r\n## Metrics Currently Used\r\n\r\nDatabase size. Table row counts. Query latency (app-level, not DB-level).\r\n\r\n## Metrics Missing\r\n\r\nWrite volume per table. Constraint violation attempts. Audit trail completeness (% of writes captured). Data staleness (how old is the oldest record). Foreign key violations (attempted but prevented).\r\n\r\n## Suggested Stored Procedures (Do Not Exist Yet)\r\n\r\n- `sp_audit_write()` - universal audit logging (actor, table, operation, before/after)\r\n- `sp_verify_twins()` - check consistency between inhibitor_govenor_matrix and i_m_g_vector_context\r\n- `sp_get_data_lineage()` - trace record origin (source table, timestamp, actor)\r\n- `sp_enforce_schema_version()` - validate incoming writes against canonical schema\r\n\r\n## Desired Context From Other Components\r\n\r\nGrinder: Which grinder outputs failed to ingest (and why)? Governance: Which tables require twinning? Ops: Which job writes succeeded vs. failed? CVI: What are the allowed write patterns?\r\n\r\n## Confidence Level\r\n\r\nHigh on current state (schema is queryable, constraints are explicit). Medium on write source (who writes what?). Low on data lineage (how did this record get here?).\r\n\r\n## Notes\r\n\r\nDatabase is purely defensive: it enforces what\'s allowed, doesn\'t determine what should happen. This is correct design but creates blind spot: DB rejects bad writes but can\'t advise what\'s good. That judgment lives in application layers.\r\n', '2026-01-29 15:40:02.605345'),
(4, 'Governance / IGM', '2026-01-29', 'High on structure, Low on adoption', '<!--\r\nCOPILOT INSTRUCTIONS (READ CAREFULLY):\r\n\r\nYou are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.\r\n\r\nDO:\r\n- Describe intent, pressure, goals, blind spots\r\n- Use plain language\r\n- Leave unknowns explicit\r\n\r\nDO NOT:\r\n- Propose solutions\r\n- Invent metrics\r\n- Write code\r\n- Make decisions\r\n- Use theory language\r\n\r\nThis file is a SITUATIONAL SNAPSHOT, not a design doc.\r\n\r\nComponent: Governance / IGM (Inhibitor Governor Matrix + i_m_g_vector_context)\r\n-->\r\n\r\n# Contextual Summary — Governance / IGM\r\n\r\n## Component Role\r\n\r\nEnforce architectural rules (canon). Hold candidate rules pending human review. Track governance decisions and attestations. Two databases in twin formation (inhibitor_govenor_matrix, i_m_g_vector_context). Canon rules are enforceable; provisional rules inform but don\'t block.\r\n\r\n## Current Intent\r\n\r\nEmbed governance into system execution, not as external checklist. Make rules observable and auditable. Distinguish between canon (hard constraints) and provisional (guidance). Enable humans to promote rules to canon as confidence grows.\r\n\r\n## Operating Mode\r\n\r\nStored procedures read rules before allowing operations. Attestation spools record rule evaluation in real time. Candidate rules staged for human review. Canon rules enforced at ingest/write time. Overrides logged and escalated.\r\n\r\n## Frequency & Cadence\r\n\r\nRule evaluation on every write (real-time). Human review of candidate rules (ad-hoc, weekly?). Rule promotion to canon (formal, rare). Attestation spools written continuously; aggregated periodically.\r\n\r\n## Pressures Detected\r\n\r\nCandidate rules accumulating without formal review process. Human reviewers unclear (who can promote to canon?). No feedback loop from enforcement (blocked operations not visible to rule authors). Provisional rules remain provisional indefinitely. Rule conflicts undetected (two rules contradict but both active).\r\n\r\n## Active Constraints\r\n\r\nNo rule versioning (old rules can\'t be deprecated easily). Twin constraint (inhibitor_govenor_matrix ↔ i_m_g_vector_context must stay synchronized). No rule composition (can\'t say \"rule A applies IF rule B is active\"). Attestations are append-only (can\'t revise historical judgments).\r\n\r\n## Short-Horizon Goals (Now → Soon)\r\n\r\nPromote TOGAF 6 principles to canon. Establish rule review board and promotion criteria. Route all component writes through governance checks. Make attestation spools queryable.\r\n\r\n## Long-Horizon Goals\r\n\r\nAutomatic rule inference (ML suggests new rules based on pattern violations). Rule evolution (deprecate, versioned rules). Cross-rule dependency tracking. Human-AI collaboration on rule confidence (AI proposes, humans decide).\r\n\r\n## Blind Spots\r\n\r\nUnknown which operations should trigger rule checks. Unclear if existing operations violate rules (audit trail doesn\'t exist yet). No way to test rule changes before deployment. Unknown rule impact (what operations would be blocked by this rule if activated?).\r\n\r\n## Friction Points\r\n\r\nRule review process not formalized. No tool to simulate rule activation. Attestation spools verbose; hard to extract signal. Twin-write enforcement relies on application layer (not DB-enforced). Candidate rules don\'t show which operations they\'d affect.\r\n\r\n## Metrics Currently Used\r\n\r\nRule count (canon vs. provisional). Attestation count (per rule, per status).\r\n\r\n## Metrics Missing\r\n\r\nRule violation frequency (how often are blocked operations attempted?). Rule promotion latency (time from candidate to canon). Override frequency (how often are rules bypassed?). Attestation completion rate (% of operations with attestation vs. silently succeeding).\r\n\r\n## Suggested Stored Procedures (Do Not Exist Yet)\r\n\r\n- `sp_evaluate_rule_set()` - check if operation violates any canon rules\r\n- `sp_simulate_rule_activation()` - show what operations would be blocked if rule activated\r\n- `sp_promote_rule_to_canon()` - promote candidate rule (requires human approval)\r\n- `sp_find_rule_conflicts()` - detect contradictory active rules\r\n\r\n## Desired Context From Other Components\r\n\r\nAll: Which of my writes need rule checks? Database: Have rule checks detected constraint violations before? Grinder: Are there rules about acceptable provider data? Ops: Should failed jobs trigger governance escalation?\r\n\r\n## Confidence Level\r\n\r\nHigh on current state (candidate rules visible in DB, canonical principles known). Medium on application (which operations are actually checking rules?). Low on impact (what happens if we enforce all candidate rules?).\r\n\r\n## Notes\r\n\r\nGovernance is currently advisory (candidate rules) to enforcement-ready (canon rules). This transition is the critical unknown: which rules should be canon, and who decides? Human authority is essential but not yet formalized.\r\n', '2026-01-29 15:40:07.277384'),
(5, 'CVI / AI Interface', '2026-01-29', 'High on design, Low on deployment', '<!--\r\nCOPILOT INSTRUCTIONS (READ CAREFULLY):\r\n\r\nYou are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.\r\n\r\nDO:\r\n- Describe intent, pressure, goals, blind spots\r\n- Use plain language\r\n- Leave unknowns explicit\r\n\r\nDO NOT:\r\n- Propose solutions\r\n- Invent metrics\r\n- Write code\r\n- Make decisions\r\n- Use theory language\r\n\r\nThis file is a SITUATIONAL SNAPSHOT, not a design doc.\r\n\r\nComponent: CVI / AI Interface (Callosum Vector Integration)\r\n-->\r\n\r\n# Contextual Summary — CVI / AI Interface\r\n\r\n## Component Role\r\n\r\nMediate communication between AI components and databases. Provide request/response carousel for structured, audited conversations. Gateway (cvi_gateway.php) exposes whitelisted stored procedures over HTTP. Workers (PowerShell) post queries; processors execute; responses returned to workers.\r\n\r\n## Current Intent\r\n\r\nEnable AI to read system state and propose actions without direct write access. Keep all AI communication parameterized and logged. Separate AI authentication from database access (token vs. credentials). Build audit trail of AI reasoning.\r\n\r\n## Operating Mode\r\n\r\nAI posts structured request JSON via gateway. Gateway validates token, looks up procedure whitelist, executes stored procedure. Results returned as JSON. AI reads response, optionally posts follow-up. All requests logged in cvi_carousel table.\r\n\r\n## Frequency & Cadence\r\n\r\nOpportunistic (on-demand). AI queries when analyzing system state. Processor executes immediately or queues for batch. Response available within seconds to minutes (not real-time). Spools written continuously; aggregated into lake_vector periodically.\r\n\r\n## Pressures Detected\r\n\r\nCVI not yet deployed (only schema + PHP skeleton exist). AI components not registered (no cm_components entries). Request/response carousel not populated (no traffic). Gateway token hardcoded (should be environment variable). Whitelisted procedures not defined (gateway has empty allowed_procs).\r\n\r\n## Active Constraints\r\n\r\nHTTP-only (no WebSocket, no streaming). Token-based auth (shared secret, no per-AI identity). Blocking (AI waits for response; no async pattern). Limited to whitelisted procs (extensible but manual). Response size limited (HTTP payload limits).\r\n\r\n## Short-Horizon Goals (Now → Soon)\r\n\r\nDeploy gateway to production. Register AI components (me, NeuroNet, future ML models). Define initial whitelist of safe procedures. Test request/response flow end-to-end.\r\n\r\n## Long-Horizon Goals\r\n\r\nPer-AI authentication (not shared token). Async request/response (queues, subscriptions). Streaming responses (for large datasets). Rate limiting and quota tracking per AI. Signed requests (HMAC verification).\r\n\r\n## Blind Spots\r\n\r\nUnknown which stored procedures should be whitelisted (safety vs. utility tradeoff). No clarity on AI → AI communication (can AIs talk to each other via CVI?). Unknown how many concurrent requests CVI can handle. No error handling strategy (what if SP timeout?).\r\n\r\n## Friction Points\r\n\r\nToken in code (should be in .env). Gateway validation weak (no signature check, no rate limit). Whitelist requires manual updates (no dynamic registration). No circuit breaker (failed SP doesn\'t gracefully degrade). Request/response schema not validated.\r\n\r\n## Metrics Currently Used\r\n\r\nNone yet (not deployed).\r\n\r\n## Metrics Missing\r\n\r\nRequest volume per AI component. Request latency (AI → gateway → SP → response). Error rate (failed requests, timeouts). Token usage (unusual patterns?). Whitelist hit rate (which procedures used most?).\r\n\r\n## Suggested Stored Procedures (Do Not Exist Yet)\r\n\r\n- `sp_cvi_register_component()` - register new AI entity with token\r\n- `sp_cvi_get_whitelist()` - return allowed procedures for requesting component\r\n- `sp_cvi_log_request()` - audit log for CVI traffic\r\n- `sp_cvi_get_component_quota()` - check request quota for AI\r\n\r\n## Desired Context From Other Components\r\n\r\nAll: Can I trust CVI to be the comms channel? Governance: Should AI requests be checked against rules? Ops: How do we monitor CVI health? Database: Which SPs are safe to expose to AI?\r\n\r\n## Confidence Level\r\n\r\nHigh on architecture (CVI design is solid, schema exists). Low on deployment (not in production yet). Low on adoption (no AI components using it). Low on safety (whitelisting not finalized).\r\n\r\n## Notes\r\n\r\nCVI is the intended channel for AI ↔ system communication but is still a blueprint. It requires activation (deployment + registration) before it becomes a living part of the system. Current state: ready to deploy, waiting for go-ahead.\r\n', '2026-01-29 15:40:12.146499'),
(6, 'Android Client', '2026-01-29', 'High on architecture, Medium on edge cases', '<!--\r\nCOPILOT INSTRUCTIONS (READ CAREFULLY):\r\n\r\nYou are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.\r\n\r\nDO:\r\n- Describe intent, pressure, goals, blind spots\r\n- Use plain language\r\n- Leave unknowns explicit\r\n\r\nDO NOT:\r\n- Propose solutions\r\n- Invent metrics\r\n- Write code\r\n- Make decisions\r\n- Use theory language\r\n\r\nThis file is a SITUATIONAL SNAPSHOT, not a design doc.\r\n\r\nComponent: Android Client (MiraTV app, Phases 1-8)\r\n-->\r\n\r\n# Contextual Summary — Android Client\r\n\r\n## Component Role\r\n\r\nLive TV, VOD, and series streaming app for Android. Activation via MAC address. Session management (username/password). Xtream API client (Retrofit). ExoPlayer HLS playback. RecyclerView shelves. Parental PIN (scaffolded). Adult mode toggle. Favorites (local, not synced).\r\n\r\n## Current Intent\r\n\r\nProvide smooth IPTV experience on TVs (Leanback-compatible). Auto-activate via device identity (MAC). Support Live, VOD, Series browse/search. Stream HLS without credentials stored on device. Respect parental controls.\r\n\r\n## Operating Mode\r\n\r\nSplashActivity → ActivationActivity (MAC validation) → HomeActivity (category shelves) → (ChannelsActivity | VodCategoriesActivity | SeriesCategoriesActivity) → PlayerActivity (ExoPlayer). Session persists via SessionManager. UI driven by Retrofit repos. Coroutine-based async.\r\n\r\n## Frequency & Cadence\r\n\r\nLaunch on-demand (user). Activation once per device. Category fetches on HomeActivity load (cached). Stream URLs fetched on player start (fresh). EPG (future) would be periodic fetch.\r\n\r\n## Pressures Detected\r\n\r\nActivation endpoint hard-coded (`api.miratv.club`). Credentials stored in SessionManager plaintext (should be EncryptedSharedPreferences). RecyclerView/Leanback mixed (not consistent). By-concepts endpoint sometimes returns 0 series (null-handling edge case). Adult PIN dialog not wired. Series categories endpoint returns 14 categories but drill-down unclear.\r\n\r\n## Active Constraints\r\n\r\nAPI 26+ (legacy support limits modern Android features). ExoPlayer 2.19.1 (older version, specific dependency). No local DB (SharedPreferences only). Single-repo pattern (all API calls through repos). No VPN SDK yet (planned Phase 10). No background sync.\r\n\r\n## Short-Horizon Goals (Now → Soon)\r\n\r\nVerify series categories drill-down working (by_concepts returning data). Wire parental PIN dialog. Test adult mode toggle. Verify favorites persistence. Build against all endpoints (series, VOD, live). Test on real TV hardware (Leanback).\r\n\r\n## Long-Horizon Goals\r\n\r\nEncrypt credentials (EncryptedSharedPreferences). Cloud favorites sync. Pluggable VPN provider. EPG overlay. Recording/DVR. Recommendation engine. Offline playback.\r\n\r\n## Blind Spots\r\n\r\nUnknown if all users can see live channels (depends on m3u_link, provider state). Unknown if series drill-down works reliably (inconsistent null fields). Unknown playback issues on various TV hardware (tested only on emulator?). Unknown if parental PIN works when enabled. Unknown user retention rate. Unknown which features matter most.\r\n\r\n## Friction Points\r\n\r\nHard-coded endpoints (not configurable). Credentials not encrypted (security issue). No error recovery (failed API call doesn\'t retry). No offline fallback. RecyclerView jank on large category lists. Player doesn\'t show EPG. Category refresh is manual (no background refresh).\r\n\r\n## Metrics Currently Used\r\n\r\nApp install count (from store). Crash reports (Firebase?). Usage (?) - unknown.\r\n\r\n## Metrics Missing\r\n\r\nSession success rate (% of activation attempts succeed). Stream playback success rate (% of playback attempts play vs. 404). Category load latency. Feature adoption (% using favorites, adult mode, PIN). Drop-off rate (activation → browse → stream).\r\n\r\n## Suggested Stored Procedures (Do Not Exist Yet)\r\n\r\nNone required on app. (DB-side could track app telemetry, but not app responsibility.)\r\n\r\n## Desired Context From Other Components\r\n\r\nXtream API: Which endpoints are stable? Activation: Device binding working? Series categories: Why are some drill-downs returning 0? EPG (future): What data format? VPN (future): Which providers supported?\r\n\r\n## Confidence Level\r\n\r\nHigh on architecture (three-layer pattern is solid, Retrofit repos work). High on core flow (splash → activation → home → player). Medium on edge cases (adult mode, PIN, edge cases). Low on real-world hardware (Leanback/TV testing). Low on user behavior (no analytics yet).\r\n\r\n## Notes\r\n\r\nApp is a competent thin client but blind to backend issues. It succeeds or fails on stream URLs but has no way to diagnose why. This separation is intentional (UI doesn\'t need to know why DB rejected data) but means users get generic errors.\r\n', '2026-01-29 15:40:16.829230'),
(7, 'Human Operator', '2026-01-29', 'High on intent, Low on process', '<!--\r\nCOPILOT INSTRUCTIONS (READ CAREFULLY):\r\n\r\nYou are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.\r\n\r\nDO:\r\n- Describe intent, pressure, goals, blind spots\r\n- Use plain language\r\n- Leave unknowns explicit\r\n\r\nDO NOT:\r\n- Propose solutions\r\n- Invent metrics\r\n- Write code\r\n- Make decisions\r\n- Use theory language\r\n\r\nThis file is a SITUATIONAL SNAPSHOT, not a design doc.\r\n\r\nComponent: Human Operator (You, Architecture Authority)\r\n-->\r\n\r\n# Contextual Summary — Human Operator\r\n\r\n## Component Role\r\n\r\nDecision maker. Rule promoter. Architect. Escalation point for system conflicts. Authority on what is canon vs. provisional. Decides which AI proposals become policy. Owns MiraTV vision and governance. Approves major changes.\r\n\r\n## Current Intent\r\n\r\nMaintain system coherence and truth. Evolve architecture based on evidence (not theory). Decide which technical constraints become non-negotiable rules. Separate signal (important insight) from noise (AI chatter). Keep humans in charge of consequential decisions.\r\n\r\n## Operating Mode\r\n\r\nReads context summaries and architectural docs. Queries databases via trigger script. Reviews AI proposals. Makes binary decisions (canon/provisional/reject). Signs off on major changes. Escalates to board if needed. Sets quarterly priorities.\r\n\r\n## Frequency & Cadence\r\n\r\nDaily or ad-hoc (responding to system signals). Weekly planning (what should system focus on next?). Monthly architectural review (are current principles holding?). Quarterly strategy (bigger bets, direction changes).\r\n\r\n## Pressures Detected\r\n\r\nToo much data (databases, logs, docs, spools). Hard to see patterns (need aggregation). AI sometimes proposes contradictory things (need filtering). Team decisions unclear (who decides what?). Governance rules still provisional (need promotion process). System growing without clear ownership handoff strategy.\r\n\r\n## Active Constraints\r\n\r\nTime (can\'t read everything). Knowledge (some technical details unclear). Availability (can\'t always be present for urgent decisions). Authority scope (some decisions require board/team consensus). Legacy debt (some constraints are inherited, not chosen).\r\n\r\n## Short-Horizon Goals (Now → Soon)\r\n\r\nPromote 6 TOGAF principles to canon rules. Clarify rule review board (who + criteria). Establish escalation path (when does AI surface something to you?). Make system state queryable (one dashboard, not scattered DBs). Decide on CVI deployment (when to activate?).\r\n\r\n## Long-Horizon Goals\r\n\r\nAutomate routine decisions (let AI propose + apply low-stakes rules). Evolve governance from advisory to enforceable. Build human-AI collaborative loop (humans decide, AI executes and learns). Maintain architectural coherence as system scales.\r\n\r\n## Blind Spots\r\n\r\nUnknown which system problems are AI-observable vs. human-only (taste, business judgment). Unknown which team members understand governance model. Unknown user feedback (what do TV watchers actually want?). Unknown where technical debt is hiding. Unknown which decisions were mistakes (no post-mortems yet).\r\n\r\n## Friction Points\r\n\r\nContext scattered across many files (need aggregation). Rule promotion process informal (should be documented). No formal authority structure (who breaks ties?). AI sometimes makes suggestions outside its scope (need boundaries). Emergency decisions vs. deliberate decisions (different speeds).\r\n\r\n## Metrics Currently Used\r\n\r\nSystem uptime. Data accuracy (spot-checks). Rule enforcement (canon rules active?).\r\n\r\n## Metrics Missing\r\n\r\nDecision latency (time from proposal to approval). Decision reversal rate (how often do rules get deprecated?). Team alignment (do people understand the rules?). Business impact (are users happy?). Operator burden (how much of your time is this taking?).\r\n\r\n## Suggested Stored Procedures (Do Not Exist Yet)\r\n\r\n- `sp_get_escalated_items()` - show critical decisions waiting for human approval\r\n- `sp_operator_promote_rule()` - record human decision (rule → canon)\r\n- `sp_operator_override()` - record human override of system decision (with rationale)\r\n- `sp_operator_log_decision()` - audit trail for all human decisions\r\n\r\n## Desired Context From Other Components\r\n\r\nAll: When should I escalate to you? AI (me): What are your decision criteria? Governance: Which rules need your approval? Team: Who do I ask when unsure? System: Are we meeting architectural goals?\r\n\r\n## Confidence Level\r\n\r\nHigh on intent (system should serve your judgment, not replace it). Low on process (no formal decision-making workflow). Low on team alignment (unclear if everyone understands vision). Low on success metrics (hard to measure).\r\n\r\n## Notes\r\n\r\nYou are the coherence keeper. Without your judgment, system becomes a collection of reactive automations. With it, system becomes a governed platform. This role is irreplaceable but can be scaled with better tools (dashboards, automation, escalation routing).\r\n', '2026-01-29 15:40:21.500461');

-- --------------------------------------------------------

--
-- Table structure for table `cortex_procedure_execution`
--

CREATE TABLE `cortex_procedure_execution` (
  `procedure_id` bigint(20) NOT NULL,
  `invocation_type` enum('manual','scheduled','event','chained','ai_requested') NOT NULL,
  `invoked_by` varchar(128) DEFAULT NULL,
  `expected_frequency` enum('adhoc','hourly','daily','burst','continuous') DEFAULT NULL,
  `required_inputs` text DEFAULT NULL,
  `preconditions` text DEFAULT NULL,
  `required_state` text DEFAULT NULL,
  `primary_outputs` text DEFAULT NULL,
  `side_effects` text DEFAULT NULL,
  `invalidates` text DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `cortex_procedure_failure`
--

CREATE TABLE `cortex_procedure_failure` (
  `procedure_id` bigint(20) NOT NULL,
  `failure_modes` text DEFAULT NULL,
  `retry_policy` enum('never','safe','conditional') NOT NULL,
  `blast_radius` enum('local','domain','system') NOT NULL,
  `last_error` text DEFAULT NULL,
  `last_error_at` timestamp NULL DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `cortex_procedure_governance`
--

CREATE TABLE `cortex_procedure_governance` (
  `procedure_id` bigint(20) NOT NULL,
  `authority_level` enum('hard','default','advisory') NOT NULL,
  `governed` tinyint(1) DEFAULT 1,
  `blocked` tinyint(1) DEFAULT 0,
  `requires_approval` tinyint(1) DEFAULT 0,
  `mutability` enum('immutable','versioned','experimental') NOT NULL,
  `governing_rules` text DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `cortex_procedure_registry`
--

CREATE TABLE `cortex_procedure_registry` (
  `procedure_id` bigint(20) NOT NULL,
  `procedure_name` varchar(255) NOT NULL,
  `procedure_type` enum('stored_proc','view','pipeline','script','batch','api') NOT NULL,
  `domain` varchar(64) NOT NULL,
  `source_system` varchar(128) NOT NULL,
  `source_path` varchar(512) NOT NULL,
  `description` text NOT NULL,
  `why_it_exists` text NOT NULL,
  `active` tinyint(1) DEFAULT 1,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `cortex_procedure_relations`
--

CREATE TABLE `cortex_procedure_relations` (
  `relation_id` bigint(20) NOT NULL,
  `procedure_id` bigint(20) NOT NULL,
  `related_type` enum('file','table','service','config','vector') NOT NULL,
  `related_identifier` varchar(512) NOT NULL,
  `relation_reason` varchar(255) DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `cortex_procedure_state`
--

CREATE TABLE `cortex_procedure_state` (
  `procedure_id` bigint(20) NOT NULL,
  `version` varchar(64) DEFAULT NULL,
  `supersedes_id` bigint(20) DEFAULT NULL,
  `confidence_score` decimal(3,2) DEFAULT 1.00,
  `success_rate` decimal(5,2) DEFAULT NULL,
  `last_success_at` timestamp NULL DEFAULT NULL,
  `last_verified_at` timestamp NULL DEFAULT NULL,
  `mirror_version` varchar(64) DEFAULT NULL,
  `mirror_status` enum('fresh','stale','rebuilding','invalid') NOT NULL DEFAULT 'fresh',
  `canonized_at` timestamp NULL DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `ctrl_ai_modes`
--

CREATE TABLE `ctrl_ai_modes` (
  `mode_id` bigint(20) NOT NULL,
  `mode` varchar(32) NOT NULL,
  `reason` varchar(255) DEFAULT NULL,
  `set_by` varchar(64) DEFAULT NULL,
  `set_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

--
-- Dumping data for table `ctrl_ai_modes`
--

INSERT INTO `ctrl_ai_modes` (`mode_id`, `mode`, `reason`, `set_by`, `set_at`) VALUES
(1, 'NORMAL', 'Initial cortex bring-up', 'system', '2026-01-09 08:26:00');

-- --------------------------------------------------------

--
-- Table structure for table `facts_events`
--

CREATE TABLE `facts_events` (
  `event_id` bigint(20) NOT NULL,
  `event_type` varchar(64) NOT NULL,
  `entity_type` varchar(32) NOT NULL,
  `entity_id` varchar(128) NOT NULL,
  `state` varchar(64) DEFAULT NULL,
  `prev_state` varchar(64) DEFAULT NULL,
  `source` varchar(64) DEFAULT NULL,
  `payload_json` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`payload_json`)),
  `occurred_at` datetime NOT NULL,
  `ingested_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `facts_telemetry`
--

CREATE TABLE `facts_telemetry` (
  `telemetry_id` bigint(20) NOT NULL,
  `device_id` varchar(128) NOT NULL,
  `metric` varchar(64) NOT NULL,
  `value` double NOT NULL,
  `unit` varchar(16) DEFAULT NULL,
  `context` varchar(64) DEFAULT NULL,
  `captured_at` datetime NOT NULL,
  `source` varchar(64) DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `gov_policies`
--

CREATE TABLE `gov_policies` (
  `policy_id` bigint(20) NOT NULL,
  `name` varchar(128) NOT NULL,
  `domain` varchar(64) DEFAULT NULL,
  `status` varchar(32) DEFAULT NULL,
  `owner_role` varchar(64) DEFAULT NULL,
  `effective_from` datetime DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

--
-- Dumping data for table `gov_policies`
--

INSERT INTO `gov_policies` (`policy_id`, `name`, `domain`, `status`, `owner_role`, `effective_from`) VALUES
(1, 'ai_read_only_v1', 'global', 'approved', 'ARCHITECT', '2026-01-09 08:26:30'),
(2, 'user_comm_policy_v1', 'user_communication', 'approved', 'MASTER_CONTROL', '2026-01-09 19:28:27');

-- --------------------------------------------------------

--
-- Table structure for table `gov_policy_rules`
--

CREATE TABLE `gov_policy_rules` (
  `rule_id` bigint(20) NOT NULL,
  `policy_id` bigint(20) NOT NULL,
  `rule_key` varchar(128) NOT NULL,
  `condition_json` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`condition_json`)),
  `action` varchar(32) NOT NULL,
  `severity` varchar(16) DEFAULT NULL,
  `active` tinyint(1) DEFAULT 1,
  `version` varchar(32) DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

--
-- Dumping data for table `gov_policy_rules`
--

INSERT INTO `gov_policy_rules` (`rule_id`, `policy_id`, `rule_key`, `condition_json`, `action`, `severity`, `active`, `version`) VALUES
(1, 100, 'NO_NEURAL_NET_TO_USER', '{\"source_actor\": \"NEURAL_NET\", \"target_actor\": \"USER\"}', 'DENY', 'BLOCK', 1, 'v1'),
(2, 100, 'GEN_REQUIRES_MC_AUTH', '{\"source_actor\": \"GENERATIVE\", \"requires_authorization\": true}', 'ALLOW', 'BLOCK', 1, 'v1'),
(3, 100, 'NO_UNRESOLVED_USER_RESPONSE', '{\"require_resolution\": true}', 'ALLOW', 'BLOCK', 1, 'v1'),
(4, 100, 'NO_UNRESOLVED_USER_RESPONSE', '{\"require_resolution\": true}', 'ALLOW', 'BLOCK', 1, 'v1'),
(5, 100, 'USER_COMM_SCOPE_BOUND', '{\"enforce_scope\": true}', 'ALLOW', 'BLOCK', 1, 'v1'),
(6, 100, 'NO_IMPERATIVE_LANGUAGE', '{\"forbid_forms\": [\"IMPERATIVE\"], \"unless_section_flag\": \"imperative_allowed\"}', 'ALLOW', 'BLOCK', 1, 'v1'),
(7, 100, 'CONFIDENCE_EVIDENCE_MATCH', '{\"require_evidence\": true, \"confidence_threshold\": 0.75}', 'ALLOW', 'BLOCK', 1, 'v1'),
(8, 100, 'USER_COMM_TERMINAL_STATE_REQUIRED', '{\"require_terminal_state\": [\"RESOLVED\", \"ESCALATED\", \"AWAITING_USER_ACTION\"]}', 'ALLOW', 'BLOCK', 1, 'v1');

-- --------------------------------------------------------

--
-- Table structure for table `ingest_files`
--

CREATE TABLE `ingest_files` (
  `file_id` bigint(20) NOT NULL,
  `path` varchar(512) NOT NULL,
  `hash` char(64) NOT NULL,
  `source` varchar(64) DEFAULT NULL,
  `mime_type` varchar(64) DEFAULT NULL,
  `size_bytes` bigint(20) DEFAULT NULL,
  `status` varchar(32) NOT NULL,
  `received_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

--
-- Dumping data for table `ingest_files`
--

INSERT INTO `ingest_files` (`file_id`, `path`, `hash`, `source`, `mime_type`, `size_bytes`, `status`, `received_at`) VALUES
(1, '/test/path/file.json', 'TEST_HASH_001', 'manual_test', 'application/json', 12345, 'RECEIVED', '2026-01-10 09:59:46');

-- --------------------------------------------------------

--
-- Table structure for table `ingest_file_states`
--

CREATE TABLE `ingest_file_states` (
  `state_id` bigint(20) NOT NULL,
  `file_id` bigint(20) NOT NULL,
  `state` varchar(32) NOT NULL,
  `set_by` varchar(32) NOT NULL,
  `set_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `intel_derived_signals`
--

CREATE TABLE `intel_derived_signals` (
  `signal_id` bigint(20) NOT NULL,
  `source_type` varchar(32) NOT NULL,
  `source_id` bigint(20) NOT NULL,
  `signal_type` varchar(64) NOT NULL,
  `signal_value` varchar(128) NOT NULL,
  `confidence` decimal(5,4) DEFAULT NULL,
  `model_version` varchar(64) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `lang_documents`
--

CREATE TABLE `lang_documents` (
  `doc_id` bigint(20) NOT NULL,
  `title` varchar(128) NOT NULL,
  `domain` varchar(64) DEFAULT NULL,
  `audience` varchar(32) DEFAULT NULL,
  `status` varchar(32) DEFAULT NULL,
  `version` varchar(32) DEFAULT NULL,
  `effective_from` datetime DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `lang_exchange_rules`
--

CREATE TABLE `lang_exchange_rules` (
  `exchange_id` bigint(20) NOT NULL,
  `section_id` bigint(20) NOT NULL,
  `source_actor` varchar(32) NOT NULL,
  `target_actor` varchar(32) NOT NULL,
  `direction` enum('SYSTEM_TO_USER','AI_TO_USER','AI_TO_SYSTEM','HUMAN_TO_AI','SYSTEM_TO_AI') NOT NULL,
  `access_level` enum('ALLOW','DENY','EXPLAIN_ONLY','READ_ONLY') NOT NULL,
  `context_scope` varchar(64) DEFAULT NULL,
  `requires_policy` varchar(128) DEFAULT NULL,
  `active` tinyint(1) DEFAULT 1,
  `effective_from` datetime DEFAULT NULL,
  `effective_to` datetime DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

--
-- Dumping data for table `lang_exchange_rules`
--

INSERT INTO `lang_exchange_rules` (`exchange_id`, `section_id`, `source_actor`, `target_actor`, `direction`, `access_level`, `context_scope`, `requires_policy`, `active`, `effective_from`, `effective_to`) VALUES
(1, 12, 'AI', 'USER', 'AI_TO_USER', 'ALLOW', 'activation_flow', NULL, 1, '2026-01-09 19:52:30', NULL),
(2, 12, 'AI', 'USER', 'AI_TO_USER', 'ALLOW', 'activation_flow', NULL, 1, '2026-01-09 19:53:51', NULL),
(3, 18, 'AI', 'USER', 'AI_TO_USER', 'DENY', 'internal_diagnostics', NULL, 1, '2026-01-09 19:54:25', NULL),
(4, 21, 'AI', 'SYSTEM', 'AI_TO_SYSTEM', 'EXPLAIN_ONLY', 'postmortem', NULL, 1, '2026-01-09 19:56:02', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `lang_sections`
--

CREATE TABLE `lang_sections` (
  `section_id` bigint(20) NOT NULL,
  `doc_id` bigint(20) NOT NULL,
  `topic_key` varchar(128) NOT NULL,
  `markdown_body` text NOT NULL,
  `intent` varchar(32) DEFAULT NULL,
  `tone` varchar(32) DEFAULT NULL,
  `user_safe` tinyint(1) DEFAULT 1,
  `priority` int(11) DEFAULT 100,
  `active` tinyint(1) DEFAULT 1
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `published_context_reports`
--

CREATE TABLE `published_context_reports` (
  `report_id` bigint(20) UNSIGNED NOT NULL,
  `component_name` varchar(255) DEFAULT NULL,
  `report_type` varchar(100) DEFAULT NULL,
  `report_status` varchar(50) DEFAULT 'draft',
  `report_content` longtext DEFAULT NULL,
  `report_version` int(11) DEFAULT 1,
  `published_at` datetime DEFAULT NULL,
  `published_by` varchar(100) DEFAULT NULL,
  `created_at` datetime DEFAULT current_timestamp(),
  `updated_at` datetime DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `sp_component_conversation_log`
--

CREATE TABLE `sp_component_conversation_log` (
  `conversation_id` bigint(20) UNSIGNED NOT NULL,
  `requesting_component` varchar(255) DEFAULT NULL,
  `intent` varchar(255) DEFAULT NULL,
  `requested_at` datetime DEFAULT current_timestamp(),
  `routed_to_sps` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`routed_to_sps`)),
  `results_returned` int(11) DEFAULT NULL,
  `status` varchar(50) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `sp_intent_routing`
--

CREATE TABLE `sp_intent_routing` (
  `routing_id` bigint(20) UNSIGNED NOT NULL,
  `intent` varchar(255) DEFAULT NULL,
  `intent_description` text DEFAULT NULL,
  `required_sp_1` varchar(255) DEFAULT NULL,
  `required_sp_2` varchar(255) DEFAULT NULL,
  `required_sp_3` varchar(255) DEFAULT NULL,
  `required_sp_4` varchar(255) DEFAULT NULL,
  `fallback_query` text DEFAULT NULL,
  `created_at` datetime DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `sp_intent_routing`
--

INSERT INTO `sp_intent_routing` (`routing_id`, `intent`, `intent_description`, `required_sp_1`, `required_sp_2`, `required_sp_3`, `required_sp_4`, `fallback_query`, `created_at`) VALUES
(1, 'I need to understand system state', 'Full picture of all components and their current status)', 'sp_get_all_component_contexts', 'sp_get_global_published_reports', 'sp_get_global_job_status', 'sp_get_global_ops_capacity', NULL, '2026-01-29 16:05:13'),
(2, 'I need to check governance before proposing a rule', 'What rules already exist and what are candidates)', 'sp_get_global_governance_rules', 'sp_get_global_candidate_rules', 'sp_get_published_context_reports', '', NULL, '2026-01-29 16:05:18'),
(3, 'I need to detect coordination gaps', 'Who is reading what and from where)', 'sp_get_global_access_log', 'sp_get_all_component_contexts', '', '', NULL, '2026-01-29 16:05:22'),
(4, 'I need to understand a specific component', 'Deep context on a component\'s role and constraints)', 'sp_get_component_context', 'sp_get_full_context_report', 'sp_get_publication_history', '', NULL, '2026-01-29 16:05:27'),
(5, 'I need to check if context is fresh', 'Verify that decision context is current)', 'sp_get_global_context_snapshots', 'sp_get_stale_contexts', '', '', NULL, '2026-01-29 16:05:32'),
(6, 'I need to publish a formal decision', 'Generate and publish formatted report for human review)', 'sp_publish_context_report', 'sp_get_publication_status', '', '', NULL, '2026-01-29 16:05:36'),
(7, 'I need to refresh my knowledge of a component', 'Update context snapshot for a specific component)', 'sp_update_component_context', 'sp_get_component_context', '', '', NULL, '2026-01-29 16:05:41'),
(8, 'I need to audit a past decision', 'Trace what context was available and what was accessed)', 'sp_get_context_access_log', 'sp_get_global_context_snapshots', 'sp_get_full_context_report', '', NULL, '2026-01-29 16:05:45');

-- --------------------------------------------------------

--
-- Table structure for table `telemetry_component_runs`
--

CREATE TABLE `telemetry_component_runs` (
  `id` bigint(20) NOT NULL,
  `run_id` varchar(64) DEFAULT NULL,
  `component` varchar(64) DEFAULT NULL,
  `start_ts` datetime DEFAULT NULL,
  `end_ts` datetime DEFAULT NULL,
  `result` varchar(16) DEFAULT NULL,
  `created_at` datetime DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

--
-- Dumping data for table `telemetry_component_runs`
--

INSERT INTO `telemetry_component_runs` (`id`, `run_id`, `component`, `start_ts`, `end_ts`, `result`, `created_at`) VALUES
(1, 'MR_20260111_ 91317', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'FAILURE', '2026-01-11 08:13:22'),
(2, 'MR_20260111_ 91649', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'FAILURE', '2026-01-11 08:16:53'),
(3, 'MR_20260111_101224', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'FAILURE', '2026-01-11 09:12:46'),
(4, 'MR_20260111_163343', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'FAILURE', '2026-01-11 15:33:58'),
(5, 'MR_20260111_163846', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'FAILURE', '2026-01-11 15:39:19'),
(6, 'MR_20260111_175851', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'FAILURE', '2026-01-11 16:59:28'),
(7, '', 'db_grinder_trigger', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'SUCCESS', '2026-01-11 17:01:48'),
(8, 'MR_20260111_180117', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'SUCCESS', '2026-01-11 17:01:50'),
(9, '', 'db_grinder_worker', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'SUCCESS', '2026-01-11 17:08:30'),
(10, '', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'SUCCESS', '2026-01-11 17:08:32'),
(11, 'MR_20260111_180757', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'SUCCESS', '2026-01-11 17:08:34'),
(12, '', 'db_grinder_worker', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'SUCCESS', '2026-01-11 17:10:22'),
(13, '', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'SUCCESS', '2026-01-11 17:10:24'),
(14, 'MR_20260111_180955', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'SUCCESS', '2026-01-11 17:10:25'),
(15, '', 'db_grinder_worker', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'SUCCESS', '2026-01-11 17:12:37'),
(16, '', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'SUCCESS', '2026-01-11 17:12:39'),
(17, 'MR_20260111_181224', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'SUCCESS', '2026-01-11 17:12:41'),
(18, '', 'db_grinder_worker', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'FAILURE', '2026-01-11 17:17:34'),
(19, '', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'FAILURE', '2026-01-11 17:17:36'),
(20, 'MR_20260111_181701', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'FAILURE', '2026-01-11 17:17:38'),
(21, '', 'db_grinder_worker', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'FAILURE', '2026-01-11 17:28:16'),
(22, '', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'FAILURE', '2026-01-11 17:28:18'),
(23, 'MR_20260111_182739', 'master_runner', '0000-00-00 00:00:00', '0000-00-00 00:00:00', 'FAILURE', '2026-01-11 17:28:20');

-- --------------------------------------------------------

--
-- Table structure for table `telemetry_upload_events`
--

CREATE TABLE `telemetry_upload_events` (
  `id` bigint(20) NOT NULL,
  `run_id` varchar(64) NOT NULL,
  `file_name` varchar(255) NOT NULL,
  `file_size` bigint(20) NOT NULL,
  `upload_ms` int(11) NOT NULL,
  `status` varchar(16) NOT NULL,
  `transport` varchar(32) NOT NULL,
  `source` varchar(64) NOT NULL,
  `created_at` datetime NOT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

--
-- Dumping data for table `telemetry_upload_events`
--

INSERT INTO `telemetry_upload_events` (`id`, `run_id`, `file_name`, `file_size`, `upload_ms`, `status`, `transport`, `source`, `created_at`) VALUES
(1, '', 'series_7.newman.json', 293936, -1, 'FAILURE', 'ftp', 'db_grinder_upload_bat', '2026-01-11 17:28:14'),
(2, 'Mon 01/12/2026_15:20:37.43', '._conversations.json', 207, -1, 'FAILURE', 'ftp', 'db_grinder_upload_bat', '2026-01-12 14:20:43'),
(3, 'Mon 01/12/2026_15:22:57.33', '._conversations.json', 207, -1, 'FAILURE', 'ftp', 'db_grinder_upload_bat', '2026-01-12 14:23:02');

-- --------------------------------------------------------

--
-- Stand-in structure for view `v_worker_ingest_files`
-- (See below for the actual view)
--
CREATE TABLE `v_worker_ingest_files` (
`file_id` bigint(20)
,`hash` char(64)
,`mime_type` varchar(64)
,`path` varchar(512)
,`received_at` datetime
,`size_bytes` bigint(20)
,`source` varchar(64)
,`status` varchar(32)
);

--
-- Indexes for dumped tables
--

--
-- Indexes for table `ai_component_learning_log`
--
ALTER TABLE `ai_component_learning_log`
  ADD PRIMARY KEY (`learning_id`);

--
-- Indexes for table `ai_component_registry`
--
ALTER TABLE `ai_component_registry`
  ADD PRIMARY KEY (`component_id`),
  ADD UNIQUE KEY `component_name` (`component_name`);

--
-- Indexes for table `ai_context_access_log`
--
ALTER TABLE `ai_context_access_log`
  ADD PRIMARY KEY (`access_id`),
  ADD KEY `idx_component_time` (`accessing_component`,`accessed_at`),
  ADD KEY `idx_accessed_component` (`accessed_component`);

--
-- Indexes for table `ai_memory_index`
--
ALTER TABLE `ai_memory_index`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `audit_log`
--
ALTER TABLE `audit_log`
  ADD PRIMARY KEY (`audit_id`);

--
-- Indexes for table `cm_system_context_snapshots`
--
ALTER TABLE `cm_system_context_snapshots`
  ADD PRIMARY KEY (`snapshot_id`),
  ADD UNIQUE KEY `uk_comp_date` (`component_name`,`snapshot_date`);

--
-- Indexes for table `cortex_procedure_execution`
--
ALTER TABLE `cortex_procedure_execution`
  ADD PRIMARY KEY (`procedure_id`);

--
-- Indexes for table `cortex_procedure_failure`
--
ALTER TABLE `cortex_procedure_failure`
  ADD PRIMARY KEY (`procedure_id`);

--
-- Indexes for table `cortex_procedure_governance`
--
ALTER TABLE `cortex_procedure_governance`
  ADD PRIMARY KEY (`procedure_id`);

--
-- Indexes for table `cortex_procedure_registry`
--
ALTER TABLE `cortex_procedure_registry`
  ADD PRIMARY KEY (`procedure_id`),
  ADD KEY `idx_domain_active` (`domain`,`active`),
  ADD KEY `idx_proc_name` (`procedure_name`);

--
-- Indexes for table `cortex_procedure_relations`
--
ALTER TABLE `cortex_procedure_relations`
  ADD PRIMARY KEY (`relation_id`),
  ADD KEY `procedure_id` (`procedure_id`),
  ADD KEY `idx_relation_type` (`related_type`);

--
-- Indexes for table `cortex_procedure_state`
--
ALTER TABLE `cortex_procedure_state`
  ADD PRIMARY KEY (`procedure_id`),
  ADD KEY `supersedes_id` (`supersedes_id`);

--
-- Indexes for table `ctrl_ai_modes`
--
ALTER TABLE `ctrl_ai_modes`
  ADD PRIMARY KEY (`mode_id`);

--
-- Indexes for table `facts_events`
--
ALTER TABLE `facts_events`
  ADD PRIMARY KEY (`event_id`);

--
-- Indexes for table `facts_telemetry`
--
ALTER TABLE `facts_telemetry`
  ADD PRIMARY KEY (`telemetry_id`);

--
-- Indexes for table `gov_policies`
--
ALTER TABLE `gov_policies`
  ADD PRIMARY KEY (`policy_id`);

--
-- Indexes for table `gov_policy_rules`
--
ALTER TABLE `gov_policy_rules`
  ADD PRIMARY KEY (`rule_id`),
  ADD KEY `policy_id` (`policy_id`);

--
-- Indexes for table `ingest_files`
--
ALTER TABLE `ingest_files`
  ADD PRIMARY KEY (`file_id`);

--
-- Indexes for table `ingest_file_states`
--
ALTER TABLE `ingest_file_states`
  ADD PRIMARY KEY (`state_id`),
  ADD KEY `file_id` (`file_id`);

--
-- Indexes for table `intel_derived_signals`
--
ALTER TABLE `intel_derived_signals`
  ADD PRIMARY KEY (`signal_id`);

--
-- Indexes for table `lang_documents`
--
ALTER TABLE `lang_documents`
  ADD PRIMARY KEY (`doc_id`);

--
-- Indexes for table `lang_exchange_rules`
--
ALTER TABLE `lang_exchange_rules`
  ADD PRIMARY KEY (`exchange_id`),
  ADD KEY `section_id` (`section_id`);

--
-- Indexes for table `lang_sections`
--
ALTER TABLE `lang_sections`
  ADD PRIMARY KEY (`section_id`),
  ADD KEY `doc_id` (`doc_id`);

--
-- Indexes for table `published_context_reports`
--
ALTER TABLE `published_context_reports`
  ADD PRIMARY KEY (`report_id`),
  ADD KEY `idx_status` (`report_status`),
  ADD KEY `idx_component` (`component_name`),
  ADD KEY `idx_published_at` (`published_at`);

--
-- Indexes for table `sp_component_conversation_log`
--
ALTER TABLE `sp_component_conversation_log`
  ADD PRIMARY KEY (`conversation_id`),
  ADD KEY `idx_component` (`requesting_component`),
  ADD KEY `idx_intent` (`intent`);

--
-- Indexes for table `sp_intent_routing`
--
ALTER TABLE `sp_intent_routing`
  ADD PRIMARY KEY (`routing_id`),
  ADD UNIQUE KEY `uk_intent` (`intent`);

--
-- Indexes for table `telemetry_component_runs`
--
ALTER TABLE `telemetry_component_runs`
  ADD PRIMARY KEY (`id`),
  ADD KEY `run_id` (`run_id`),
  ADD KEY `component` (`component`);

--
-- Indexes for table `telemetry_upload_events`
--
ALTER TABLE `telemetry_upload_events`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_run_id` (`run_id`),
  ADD KEY `idx_status` (`status`),
  ADD KEY `idx_created_at` (`created_at`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `ai_component_learning_log`
--
ALTER TABLE `ai_component_learning_log`
  MODIFY `learning_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `ai_component_registry`
--
ALTER TABLE `ai_component_registry`
  MODIFY `component_id` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=7;

--
-- AUTO_INCREMENT for table `ai_context_access_log`
--
ALTER TABLE `ai_context_access_log`
  MODIFY `access_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `ai_memory_index`
--
ALTER TABLE `ai_memory_index`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `audit_log`
--
ALTER TABLE `audit_log`
  MODIFY `audit_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `cm_system_context_snapshots`
--
ALTER TABLE `cm_system_context_snapshots`
  MODIFY `snapshot_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=8;

--
-- AUTO_INCREMENT for table `cortex_procedure_registry`
--
ALTER TABLE `cortex_procedure_registry`
  MODIFY `procedure_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `cortex_procedure_relations`
--
ALTER TABLE `cortex_procedure_relations`
  MODIFY `relation_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `ctrl_ai_modes`
--
ALTER TABLE `ctrl_ai_modes`
  MODIFY `mode_id` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `facts_events`
--
ALTER TABLE `facts_events`
  MODIFY `event_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `facts_telemetry`
--
ALTER TABLE `facts_telemetry`
  MODIFY `telemetry_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `gov_policies`
--
ALTER TABLE `gov_policies`
  MODIFY `policy_id` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- AUTO_INCREMENT for table `gov_policy_rules`
--
ALTER TABLE `gov_policy_rules`
  MODIFY `rule_id` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=9;

--
-- AUTO_INCREMENT for table `ingest_files`
--
ALTER TABLE `ingest_files`
  MODIFY `file_id` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `ingest_file_states`
--
ALTER TABLE `ingest_file_states`
  MODIFY `state_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `intel_derived_signals`
--
ALTER TABLE `intel_derived_signals`
  MODIFY `signal_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `lang_documents`
--
ALTER TABLE `lang_documents`
  MODIFY `doc_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `lang_exchange_rules`
--
ALTER TABLE `lang_exchange_rules`
  MODIFY `exchange_id` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=5;

--
-- AUTO_INCREMENT for table `lang_sections`
--
ALTER TABLE `lang_sections`
  MODIFY `section_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `published_context_reports`
--
ALTER TABLE `published_context_reports`
  MODIFY `report_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `sp_component_conversation_log`
--
ALTER TABLE `sp_component_conversation_log`
  MODIFY `conversation_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `sp_intent_routing`
--
ALTER TABLE `sp_intent_routing`
  MODIFY `routing_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=9;

--
-- AUTO_INCREMENT for table `telemetry_component_runs`
--
ALTER TABLE `telemetry_component_runs`
  MODIFY `id` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=24;

--
-- AUTO_INCREMENT for table `telemetry_upload_events`
--
ALTER TABLE `telemetry_upload_events`
  MODIFY `id` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=4;

-- --------------------------------------------------------

--
-- Structure for view `v_worker_ingest_files`
--
DROP TABLE IF EXISTS `v_worker_ingest_files`;

CREATE ALGORITHM=UNDEFINED DEFINER=`xpdgxfsp`@`localhost` SQL SECURITY DEFINER VIEW `v_worker_ingest_files`  AS SELECT `ingest_files`.`file_id` AS `file_id`, `ingest_files`.`hash` AS `hash`, `ingest_files`.`mime_type` AS `mime_type`, `ingest_files`.`path` AS `path`, `ingest_files`.`received_at` AS `received_at`, `ingest_files`.`size_bytes` AS `size_bytes`, `ingest_files`.`source` AS `source`, `ingest_files`.`status` AS `status` FROM `ingest_files` ;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
