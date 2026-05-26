-- phpMyAdmin SQL Dump
-- version 5.2.2
-- https://www.phpmyadmin.net/
--
-- Host: localhost:3306
-- Generation Time: Mar 16, 2026 at 11:57 AM
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
-- Database: `xpdgxfsp_ops`
--

DELIMITER $$
--
-- Procedures
--
CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `record_batch_start` ()   BEGIN END$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `report_ops_capacity` ()   BEGIN
  SELECT
    COUNT(*)                                              AS total_runs,
    SUM(status = 'running')                               AS active_runs,
    SUM(status = 'failed')                                AS failed_runs,
    (1 - (SUM(status = 'failed') / COUNT(*)))             AS capacity_score,
    NOW()                                                  AS as_of
  FROM job_runs;
END$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_cvi_publish` (IN `p_component` VARCHAR(128), IN `p_payload_type` VARCHAR(64), IN `p_payload` LONGTEXT, IN `p_source_actor` VARCHAR(128), IN `p_source_system` VARCHAR(128), IN `p_signature` VARCHAR(255))   BEGIN
  INSERT INTO cvi_carousel
    (component, payload_type, payload, source_actor, source_system, signature)
  VALUES
    (p_component, p_payload_type, p_payload, p_source_actor, p_source_system, p_signature);

  SELECT LAST_INSERT_ID() AS inserted_id;
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

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_get_event_count_by_source` (IN `p_source` VARCHAR(128), IN `p_start` DATETIME, IN `p_end` DATETIME)   BEGIN
  SELECT COUNT(*) AS event_count
  FROM ai_telemetry
  WHERE source = p_source
    AND created_at BETWEEN p_start AND p_end;
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

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_get_job_run_counts` (IN `p_status` VARCHAR(32), IN `p_start` DATETIME, IN `p_end` DATETIME)   BEGIN
  SELECT COUNT(*) AS run_count
  FROM job_runs
  WHERE status = p_status
    AND started_at BETWEEN p_start AND p_end;
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

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_get_recent_job_events` (IN `p_job_key` VARCHAR(128), IN `p_limit` INT)   BEGIN
  DECLARE v_limit INT;
  SET v_limit = LEAST(GREATEST(p_limit, 1), 1000);

  SET @sql = CONCAT(
    'SELECT event_id, run_id, job_key, event_type, event_detail, created_at ',
    'FROM job_events ',
    'WHERE job_key = ? ',
    'ORDER BY created_at DESC ',
    'LIMIT ', v_limit
  );

  PREPARE stmt FROM @sql;
  SET @p_job_key = p_job_key;
  EXECUTE stmt USING @p_job_key;
  DEALLOCATE PREPARE stmt;
END$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_get_recent_telemetry` (IN `p_source` VARCHAR(128), IN `p_limit` INT)   BEGIN
  DECLARE v_limit INT;
  SET v_limit = LEAST(GREATEST(p_limit, 1), 1000);

  SET @sql = CONCAT(
    'SELECT id, created_at, task, source, latency_ms, confidence, job_run_id ',
    'FROM ai_telemetry ',
    'WHERE source = ? ',
    'ORDER BY created_at DESC ',
    'LIMIT ', v_limit
  );

  PREPARE stmt FROM @sql;
  SET @p_source = p_source;
  EXECUTE stmt USING @p_source;
  DEALLOCATE PREPARE stmt;
END$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_ops_schema_snapshot` ()   BEGIN
  SELECT 
    table_schema,
    table_name,
    column_name,
    data_type,
    is_nullable,
    column_key,
    ordinal_position
  FROM information_schema.columns
  WHERE table_schema = DATABASE()
  ORDER BY table_name, ordinal_position;
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

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_route_intent` (IN `p_intent` VARCHAR(500))  READS SQL DATA SELECT routing_id, intent, intent_description, required_sp_1, required_sp_2, required_sp_3, required_sp_4 FROM sp_intent_routing WHERE intent LIKE CONCAT('%', p_intent, '%') LIMIT 1$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_test_read` ()  READS SQL DATA SELECT * FROM cm_system_context_snapshots LIMIT 1$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `test_schema_fixed` ()   BEGIN END$$

DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `active_memory_registry_meta`
--

CREATE TABLE `active_memory_registry_meta` (
  `meta_key` varchar(64) NOT NULL,
  `meta_value` text NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

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
(1, 'LLM', 'reasoning', 'learning', 'callosum_matrix', 'Language model - explanation, synthesis, coordination', '2026-01-29 16:12:26'),
(2, 'NeuroNet', 'pattern_detection', 'learning', 'lake_vector', 'Pattern detection - anomalies, signals, scoring', '2026-01-29 16:12:30'),
(3, 'ML', 'forecasting', 'learning', 'ops', 'Machine learning - capacity, performance, optimization', '2026-01-29 16:12:35'),
(4, 'GenAI', 'insight_generation', 'learning', 'i_m_g_vector_context', 'Generative AI - proposals, classifications, candidate rules', '2026-01-29 16:12:39'),
(5, 'VectorDB Agent', 'knowledge_navigation', 'learning', 'lake_knowledge', 'Vector search - semantic similarity, knowledge discovery', '2026-01-29 16:12:44'),
(6, 'LocalAI', 'embedded_reasoning', 'learning', 'cortex', 'Local on-device reasoning - edge inference', '2026-01-29 16:12:49');

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

--
-- Dumping data for table `ai_memory_index`
--

INSERT INTO `ai_memory_index` (`id`, `source_db`, `source_table`, `record_id`, `domain`, `topic`, `unit_type`, `summary`, `content_ref`, `confidence`, `priority_weight`, `active`, `created_at`, `updated_at`) VALUES
(1, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: backup of normalize web file.txt | Size: 5019 bytes', '<?php\r\nif (isset($_GET[\'debug\'])) {\r\n    header(\'Content-Type: application/json\');\r\n    echo json_encode([\r\n        \'ok\' => true,\r\n        \'worker\' => basename(__FILE__),\r\n        \'env\' => $_ENV[\'APP_ENV\'] ?? null,\r\n        \'headers\' => getallheaders(),\r\n        \'method\' => $_SERVER[\'REQUEST_METHOD\'] ?? null\r\n    ], JSON_PRETTY_PRINT);\r\n    exit;\r\n}\r\n\r\nrequire __DIR__ . \'/_worker_config.php\';\r\nrequire_token();\r\n\r\n$pdo = db();\r\nif (!acquire_lock($pdo, \'worker_series_normalize\', 1)) {\r\n  echo \"busy\n\";\r\n  exit;\r\n}\r\n\r\n$start = microtime(true);\r\n\r\ntry {\r\n  // One unparsed payload\r\n  $stmt = $pdo->query(\"\r\n    SELECT id, internal_series_id, provider_series_id, raw_provider_json\r\n    FROM series_details_raw\r\n    WHERE parsed = 0\r\n      AND raw_provider_json IS NOT NULL\r\n    ORDER BY id\r\n    LIMIT 1\r\n  \");\r\n  $row = $stmt->fetch();\r\n  if (!$row) {\r\n    echo \"done\n\";\r\n    exit;\r\n  }\r\n\r\n  $rawId = (int)$row[\'id\'];\r\n  $internalId = (int)$row[\'internal_series_id\'];\r\n  $providerId = (int)$row[\'provider_series_id\'];\r\n  $rawJson = $row[\'raw_provider_json\'];\r\n\r\n  $data = json_decode($rawJson, true);\r\n  if (!is_array($data)) {\r\n    $err = \"invalid_json\";\r\n    $u = $pdo->prepare(\"UPDATE series_details_raw SET parse_error=:e WHERE id=:id\");\r\n    $u->execute([\':e\'=>$err, \':id\'=>$rawId]);\r\n    echo \"error raw_id={$rawId} {$err}\n\";\r\n    exit;\r\n  }\r\n\r\n  $pdo->beginTransaction();\r\n\r\n  // -------- series_details (from info) --------\r\n  $info = $data[\'info\'] ?? [];\r\n\r\n  // backdrop_path sometimes array\r\n  $backdrop = null;\r\n  if (isset($info[\'backdrop_path\'])) {\r\n    if (is_array($info[\'backdrop_path\']) && count($info[\'backdrop_path\'])) $backdrop = $info[\'backdrop_path\'][0];\r\n    if (is_string($info[\'backdrop_path\'])) $backdrop = $info[\'backdrop_path\'];\r\n  }\r\n\r\n  $insDetails = $pdo->prepare(\"\r\n    REPLACE INTO series_details\r\n      (series_id, plot, genre, rating, release_date, backdrop_url, cover_url, updated_at)\r\n    VALUES\r\n      (:sid, :plot, :genre, :rating, :release, :backdrop, :cover, NOW())\r\n  \");\r\n  $insDetails->execute([\r\n    \':sid\'      => $internalId,\r\n    \':plot\'     => $info[\'plot\'] ?? null,\r\n    \':genre\'    => $info[\'genre\'] ?? null,\r\n    \':rating\'   => $info[\'rating\'] ?? null,\r\n    \':release\'  => $info[\'releaseDate\'] ?? null,\r\n    \':backdrop\' => $backdrop,\r\n    \':cover\'    => $info[\'cover\'] ?? null,\r\n  ]);\r\n\r\n  // -------- seasons --------\r\n  if (!empty($data[\'seasons\']) && is_array($data[\'seasons\'])) {\r\n    $insSeason = $pdo->prepare(\"\r\n      REPLACE INTO series_seasons\r\n        (series_id, season_number, name, episode_count, air_date, cover)\r\n      VALUES\r\n        (:sid, :num, :name, :cnt, :air, :cover)\r\n    \");\r\n\r\n    foreach ($data[\'seasons\'] as $s) {\r\n      if (!is_array($s)) continue;\r\n      $insSeason->execute([\r\n        \':sid\'   => $internalId,\r\n        \':num\'   => $s[\'season_number\'] ?? null,\r\n        \':name\'  => $s[\'name\'] ?? null,\r\n        \':cnt\'   => $s[\'episode_count\'] ?? null,\r\n        \':air\'   => $s[\'air_date\'] ?? null,\r\n        \':cover\' => $s[\'cover\'] ?? null,\r\n      ]);\r\n    }\r\n  }\r\n\r\n  // -------- episodes --------\r\n  // Structure: episodes { \"1\":[{...},{...}], \"2\":[...] }\r\n  if (!empty($data[\'episodes\']) && is_array($data[\'episodes\'])) {\r\n    $insEp = $pdo->prepare(\"\r\n      REPLACE INTO series_episodes\r\n        (series_id, season_number, episode_number, title, stream_id, container)\r\n      VALUES\r\n        (:sid, :season, :epnum, :title, :stream, :ext)\r\n    \");\r\n\r\n    foreach ($data[\'episodes\'] as $seasonKey => $eps) {\r\n      if (!is_array($eps)) continue;\r\n      foreach ($eps as $ep) {\r\n        if (!is_array($ep)) continue;\r\n        $insEp->execute([\r\n          \':sid\'    => $internalId,\r\n          \':season\' => (int)$seasonKey,\r\n          \':epnum\'  => $ep[\'episode_num\'] ?? null,\r\n          \':title\'  => $ep[\'title\'] ?? null,\r\n          \':stream\' => $ep[\'id\'] ?? null,\r\n          \':ext\'    => $ep[\'container_extension\'] ?? null,\r\n        ]);\r\n      }\r\n    }\r\n  }\r\n\r\n  // -------- flip bits (raw parsed + series flags) --------\r\n  $pdo->prepare(\"\r\n    UPDATE series_details_raw\r\n    SET parsed = 1, parsed_at = NOW(), parse_error = NULL\r\n    WHERE id = :rid\r\n  \")->execute([\':rid\'=>$rawId]);\r\n\r\n  $pdo->prepare(\"\r\n    UPDATE series\r\n    SET details_ingested = 1,\r\n        details_ingested_at = NOW(),\r\n        is_dirty = 0\r\n    WHERE id = :sid\r\n  \")->execute([\':sid\'=>$internalId]);\r\n\r\n  $pdo->commit();\r\n\r\n  $ms = (int)((microtime(true) - $start) * 1000);\r\n  echo \"ok raw_id={$rawId} internal_id={$internalId} provider_series_id={$providerId} ms={$ms}\n\";\r\n\r\n} catch (Throwable $e) {\r\n  if ($pdo->inTransaction()) $pdo->rollBack();\r\n  // record error on raw record if we can\r\n  try {\r\n    if (isset($rawId)) {\r\n      $u = $pdo->prepare(\"UPDATE series_details_raw SET parse_error=:e WHERE id=:id\");\r\n      $u->execute([\':e\'=>$e->getMessage(), \':id\'=>$rawId]);\r\n    }\r\n  } catch (Throwable $ignored) {}\r\n  http_response_code(500);\r\n  echo \"fatal: \" . $e->getMessage() . \"\n\";\r\n} finally {\r\n  release_lock($pdo, \'worker_series_normalize\');\r\n}\r\n', 0.95, 1, 1, '2026-02-18 14:44:52', '2026-02-18 14:44:52'),
(2, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: missing_guides.txt | Size: 141 bytes', 'db_component_catalog\r\nembedding_pipeline_component\r\nhow_to_use_dog_open_cvi\r\nseries_grinder_arrays_trigger\r\nxtream_api_simulation_component\r\n', 0.95, 1, 1, '2026-02-18 14:44:52', '2026-02-18 14:44:52'),
(3, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: New Text Document.txt | Size: 0 bytes', '', 0.95, 1, 1, '2026-02-18 14:44:53', '2026-02-18 14:44:53'),
(4, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: registry_process_names.txt | Size: 2339 bytes', 'app_component\r\nbatch_pipeline_component\r\ncontext_reports_ops_ingest_triggers_component\r\ncontext_reports_ops_ingest_triggers_component\r\ncvi_registry_instructions\r\ndb_grinder_batch_component\r\ndb_grinder_trigger_component\r\ndb_grinder_trigger_component\r\ndog_open_usage\r\nembedding_pipeline_worker\r\nembedding_pipeline_worker\r\nepisode_resolver_trigger\r\nepisode_resolver_trigger\r\ngovernance_telemetry_component\r\ngovernance_telemetry_component\r\nhuman_operator_onboarding_component\r\nhuman_operator_onboarding_component\r\nhuman_operator_onboarding_component\r\nhuman_operator_onboarding_component\r\nhuman_operator_onboarding_component\r\nhuman_operator_onboarding_component\r\nhuman_operator_onboarding_component\r\nhuman_operator_onboarding_component\r\nip_db_component\r\nip_db_component\r\nmaterialize_series_trigger\r\nmaterialize_series_trigger\r\nraw_ingest_trigger\r\nraw_ingest_trigger\r\nraw_router_ingest_triggers_component\r\nraw_router_ingest_triggers_component\r\nraw_table_parse_trigger\r\nraw_table_parse_trigger\r\nregistry_upload_automation_component\r\nrun_pipeline_worker\r\nrun_pipeline_worker\r\nrun_series_pipeline_worker\r\nrun_series_pipeline_worker\r\nscripting_batch_component\r\nseries_details_worker_trigger_component\r\nseries_grinder_embedding_triggers_component\r\nseries_grinder_embedding_triggers_component\r\nseries_grinder_master_trigger_component\r\nseries_grinder_pipeline_component\r\nseries_grinder_step01_trigger_component\r\nseries_grinder_step01_trigger_component\r\nseries_grinder_step01_trigger_component\r\nseries_grinder_step01_trigger_component\r\nseries_grinder_step01_trigger_component\r\nseries_normalizer_pipeline_component\r\nseries_normalizer_pipeline_component\r\nseries_normalize_worker\r\nseries_normalize_worker\r\nseries_upload_ingest_triggers_component\r\nserver_component\r\nshared_simple_log_utility\r\nshared_simple_log_utility\r\nshared_telemetry_worker\r\nshared_telemetry_worker\r\nspool_uploader_ai_sql_component\r\nspool_uploader_worker\r\nspool_uploader_worker\r\nspool_upload_triggers_component\r\ntelemetry_module_component\r\ntelemetry_module_component\r\ntelemetry_watcher_worker\r\ntelemetry_watcher_worker\r\ntest_utility_scripts_component\r\ntest_utility_scripts_component\r\ntest_utility_scripts_component\r\ntest_utility_scripts_component\r\ntest_utility_scripts_component\r\nupload_spool_once_utility\r\nupload_spool_once_utility\r\nwatcher_cvi_component\r\nxtream_api_gateway_component\r\n', 0.95, 1, 1, '2026-02-18 14:44:53', '2026-02-18 14:44:53'),
(5, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: upload_log.txt | Size: 1161 bytes', '[2026-02-18 15:44:50] ?? Scanning C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 15:44:50] Found 7 files to upload\r\n[2026-02-18 15:44:50] ?? Uploading: backup of normalize web file.txt\r\n[2026-02-18 15:44:52] ? Uploaded and moved to processed: backup of normalize web file.txt\r\n[2026-02-18 15:44:52] ?? Uploading: MiraTV Series Ingest & Materialize.txt\r\n[2026-02-18 15:44:52] ? Failed: MiraTV Series Ingest & Materialize.txt - {\"error\":\"Unauthorized\"}\r\n[2026-02-18 15:44:52] ?? Moved to failed folder\r\n[2026-02-18 15:44:52] ?? Uploading: missing_guides.txt\r\n[2026-02-18 15:44:52] ? Uploaded and moved to processed: missing_guides.txt\r\n[2026-02-18 15:44:52] ?? Uploading: New Text Document.txt\r\n[2026-02-18 15:44:53] ? Uploaded and moved to processed: New Text Document.txt\r\n[2026-02-18 15:44:53] ?? Uploading: registry_process_names.txt\r\n[2026-02-18 15:44:53] ? Uploaded and moved to processed: registry_process_names.txt\r\n[2026-02-18 15:44:53] ?? Uploading: response.txt\r\n[2026-02-18 15:44:53] ? Failed: response.txt - {\"error\":\"Unauthorized\"}\r\n[2026-02-18 15:44:53] ?? Moved to failed folder\r\n[2026-02-18 15:44:53] ?? Uploading: upload_log.txt\r\n', 0.95, 1, 1, '2026-02-18 14:44:54', '2026-02-18 14:44:54'),
(6, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: upload_log.txt | Size: 441 bytes', '[2026-02-18 15:44:54] ? Uploaded and moved to processed: upload_log.txt\r\n[2026-02-18 15:44:54] ?? Summary: 5 uploaded, 2 failed\r\n[2026-02-18 16:10:07] ??? Watching C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 16:10:07] Press Ctrl+C to stop\r\n[2026-02-18 16:12:37] ?? Scanning C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 16:12:38] Found 1 files to upload\r\n[2026-02-18 16:12:38] ?? Uploading: upload_log.txt\r\n', 0.95, 1, 1, '2026-02-18 15:12:39', '2026-02-18 15:12:39'),
(7, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: upload_log.txt | Size: 312 bytes', '[2026-02-18 16:12:39] ? Uploaded and moved to processed: upload_log.txt\r\n[2026-02-18 16:12:39] ?? Summary: 1 uploaded, 0 failed\r\n[2026-02-18 16:12:58] ?? Scanning C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 16:12:58] Found 1 files to upload\r\n[2026-02-18 16:12:58] ?? Uploading: upload_log.txt\r\n', 0.95, 1, 1, '2026-02-18 15:12:59', '2026-02-18 15:12:59'),
(8, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: upload_log.txt | Size: 312 bytes', '[2026-02-18 16:12:59] ? Uploaded and moved to processed: upload_log.txt\r\n[2026-02-18 16:12:59] ?? Summary: 1 uploaded, 0 failed\r\n[2026-02-18 16:13:05] ?? Scanning C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 16:13:05] Found 1 files to upload\r\n[2026-02-18 16:13:05] ?? Uploading: upload_log.txt\r\n', 0.95, 1, 1, '2026-02-18 15:13:06', '2026-02-18 15:13:06'),
(9, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: upload_log.txt | Size: 312 bytes', '[2026-02-18 16:13:05] ? Uploaded and moved to processed: upload_log.txt\r\n[2026-02-18 16:13:05] ?? Summary: 1 uploaded, 0 failed\r\n[2026-02-18 16:13:14] ?? Scanning C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 16:13:14] Found 1 files to upload\r\n[2026-02-18 16:13:14] ?? Uploading: upload_log.txt\r\n', 0.95, 1, 1, '2026-02-18 15:13:15', '2026-02-18 15:13:15'),
(10, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: upload_log.txt | Size: 312 bytes', '[2026-02-18 16:13:15] ? Uploaded and moved to processed: upload_log.txt\r\n[2026-02-18 16:13:15] ?? Summary: 1 uploaded, 0 failed\r\n[2026-02-18 16:13:34] ?? Scanning C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 16:13:34] Found 1 files to upload\r\n[2026-02-18 16:13:34] ?? Uploading: upload_log.txt\r\n', 0.95, 1, 1, '2026-02-18 15:13:35', '2026-02-18 15:13:35'),
(11, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: upload_log.txt | Size: 441 bytes', '[2026-02-18 16:13:35] ? Uploaded and moved to processed: upload_log.txt\r\n[2026-02-18 16:13:35] ?? Summary: 1 uploaded, 0 failed\r\n[2026-02-18 17:21:15] ??? Watching C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 17:21:15] Press Ctrl+C to stop\r\n[2026-02-18 17:22:47] ?? Scanning C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 17:22:47] Found 1 files to upload\r\n[2026-02-18 17:22:47] ?? Uploading: upload_log.txt\r\n', 0.95, 1, 1, '2026-02-18 16:22:49', '2026-02-18 16:22:49'),
(12, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: upload_log.txt | Size: 312 bytes', '[2026-02-18 17:22:49] ? Uploaded and moved to processed: upload_log.txt\r\n[2026-02-18 17:22:49] ?? Summary: 1 uploaded, 0 failed\r\n[2026-02-18 17:22:58] ?? Scanning C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 17:22:59] Found 1 files to upload\r\n[2026-02-18 17:22:59] ?? Uploading: upload_log.txt\r\n', 0.95, 1, 1, '2026-02-18 16:22:59', '2026-02-18 16:22:59'),
(13, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: upload_log.txt | Size: 312 bytes', '[2026-02-18 17:22:59] ? Uploaded and moved to processed: upload_log.txt\r\n[2026-02-18 17:22:59] ?? Summary: 1 uploaded, 0 failed\r\n[2026-02-18 17:23:02] ?? Scanning C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 17:23:02] Found 1 files to upload\r\n[2026-02-18 17:23:02] ?? Uploading: upload_log.txt\r\n', 0.95, 1, 1, '2026-02-18 16:23:03', '2026-02-18 16:23:03'),
(14, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: upload_log.txt | Size: 312 bytes', '[2026-02-18 17:23:03] ? Uploaded and moved to processed: upload_log.txt\r\n[2026-02-18 17:23:03] ?? Summary: 1 uploaded, 0 failed\r\n[2026-02-18 17:23:09] ?? Scanning C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 17:23:09] Found 1 files to upload\r\n[2026-02-18 17:23:09] ?? Uploading: upload_log.txt\r\n', 0.95, 1, 1, '2026-02-18 16:23:10', '2026-02-18 16:23:10'),
(15, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: upload_log.txt | Size: 312 bytes', '[2026-02-18 17:23:10] ? Uploaded and moved to processed: upload_log.txt\r\n[2026-02-18 17:23:10] ?? Summary: 1 uploaded, 0 failed\r\n[2026-02-18 17:23:12] ?? Scanning C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 17:23:12] Found 1 files to upload\r\n[2026-02-18 17:23:12] ?? Uploading: upload_log.txt\r\n', 0.95, 1, 1, '2026-02-18 16:23:12', '2026-02-18 16:23:12'),
(16, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: upload_log.txt | Size: 312 bytes', '[2026-02-18 17:23:12] ? Uploaded and moved to processed: upload_log.txt\r\n[2026-02-18 17:23:12] ?? Summary: 1 uploaded, 0 failed\r\n[2026-02-18 17:23:19] ?? Scanning C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 17:23:19] Found 1 files to upload\r\n[2026-02-18 17:23:19] ?? Uploading: upload_log.txt\r\n', 0.95, 1, 1, '2026-02-18 16:23:19', '2026-02-18 16:23:19'),
(17, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: upload_log.txt | Size: 312 bytes', '[2026-02-18 17:23:19] ? Uploaded and moved to processed: upload_log.txt\r\n[2026-02-18 17:23:19] ?? Summary: 1 uploaded, 0 failed\r\n[2026-02-18 17:25:46] ?? Scanning C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 17:25:46] Found 1 files to upload\r\n[2026-02-18 17:25:46] ?? Uploading: upload_log.txt\r\n', 0.95, 1, 1, '2026-02-18 16:25:47', '2026-02-18 16:25:47'),
(18, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: upload_log.txt | Size: 312 bytes', '[2026-02-18 17:25:47] ? Uploaded and moved to processed: upload_log.txt\r\n[2026-02-18 17:25:47] ?? Summary: 1 uploaded, 0 failed\r\n[2026-02-18 17:26:27] ?? Scanning C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 17:26:27] Found 1 files to upload\r\n[2026-02-18 17:26:27] ?? Uploading: upload_log.txt\r\n', 0.95, 1, 1, '2026-02-18 16:26:28', '2026-02-18 16:26:28'),
(19, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: upload_log.txt | Size: 312 bytes', '[2026-02-18 17:26:28] ? Uploaded and moved to processed: upload_log.txt\r\n[2026-02-18 17:26:28] ?? Summary: 1 uploaded, 0 failed\r\n[2026-02-18 17:27:19] ?? Scanning C:miratv_ingest for .spool, .txt, .log files...\r\n[2026-02-18 17:27:19] Found 1 files to upload\r\n[2026-02-18 17:27:19] ?? Uploading: upload_log.txt\r\n', 0.95, 1, 1, '2026-02-18 16:27:20', '2026-02-18 16:27:20'),
(20, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: ops_20260123.log | Size: 405 bytes', '2026-01-23T15:56:06.6798891-07:00 | master_accessory_loop | SERIES_RUN_FAILED | {}\r\n2026-01-23T15:56:09.8394807-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | {}\r\n2026-01-23T15:56:09.8376470-07:00 | master_accessory_loop | LOOP_END | {}\r\n2026-01-23T15:57:48.4302914-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | {}\r\n2026-01-23T15:59:20.2850058-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | {}\r\n', 0.95, 1, 1, '2026-02-18 16:36:58', '2026-02-18 16:36:58'),
(21, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: ops_20260124.log | Size: 159 bytes', '2026-01-24T21:24:50.4299955-07:00 | master_accessory_loop | SERIES_RUN_FAILED | {}\r\n2026-01-24T21:24:51.7605791-07:00 | master_accessory_loop | LOOP_END | {}\r\n', 0.95, 1, 1, '2026-02-18 16:36:58', '2026-02-18 16:36:58'),
(22, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: ops_20260125.log | Size: 85 bytes', '2026-01-25T23:48:30.8216267-07:00 | master_accessory_loop | SERIES_RUN_SUCCESS | {}\r\n', 0.95, 1, 1, '2026-02-18 16:36:59', '2026-02-18 16:36:59'),
(23, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: ops_20260126.log | Size: 413 bytes', '2026-01-26T22:44:15.8752470-07:00 | master_accessory_loop | SERIES_RUN_SUCCESS | {}\r\n2026-01-26T22:44:36.5834385-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | {}\r\n2026-01-26T22:45:42.3328679-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | {}\r\n2026-01-26T22:46:51.5574095-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | {}\r\n2026-01-26T22:48:06.4218278-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | {}\r\n', 0.95, 1, 1, '2026-02-18 16:36:59', '2026-02-18 16:36:59'),
(24, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: ops_20260127.log | Size: 157 bytes', '2026-01-27T19:48:39.1111955-07:00 | master_accessory_loop | SERIES_RUN_SUCCESS | {}\r\n2026-01-27T20:04:33.8461443-07:00 | master_accessory | LOOP_START | {}\r\n', 0.95, 1, 1, '2026-02-18 16:37:00', '2026-02-18 16:37:00'),
(25, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: ops_20260129.log | Size: 577 bytes', '2026-01-29T23:27:04.3729027-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | {}\r\n2026-01-29T23:27:23.9925186-07:00 | master_accessory_loop | SERIES_RUN_SUCCESS | {}\r\n2026-01-29T23:28:01.6165906-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | {}\r\n2026-01-29T23:28:40.2472263-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | {}\r\n2026-01-29T23:29:37.2725318-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | {}\r\n2026-01-29T23:30:35.9610957-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | {}\r\n2026-01-29T23:31:28.4707262-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | {}\r\n', 0.95, 1, 1, '2026-02-18 16:37:00', '2026-02-18 16:37:00'),
(26, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: ops_20260130.log | Size: 963 bytes', '2026-01-30T23:48:12.6037831-07:00 | master_accessory_loop | SERIES_RUN_SUCCESS | \r\n2026-01-30T23:48:20.3529202-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | \r\n2026-01-30T23:49:15.5138168-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | \r\n2026-01-30T23:50:15.8795394-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | \r\n2026-01-30T23:51:24.7755370-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | \r\n2026-01-30T23:52:39.1883967-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | \r\n2026-01-30T23:53:52.2652328-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | \r\n2026-01-30T23:55:03.0475261-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | \r\n2026-01-30T23:56:07.0218126-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | \r\n2026-01-30T23:57:15.3106809-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | \r\n2026-01-30T23:58:27.9345822-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | \r\n2026-01-30T23:59:42.0428493-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | \r\n', 0.95, 1, 1, '2026-02-18 16:37:01', '2026-02-18 16:37:01'),
(27, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: ops_20260131.log | Size: 153 bytes', '2026-01-31T21:06:14.8481027-07:00 | master_accessory_loop | SERIES_RUN_SUCCESS | \r\n2026-01-31T22:11:33.7158333-07:00 | master_accessory | LOOP_START | \r\n', 0.95, 1, 1, '2026-02-18 16:37:01', '2026-02-18 16:37:01'),
(28, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: ops_20260201.log | Size: 153 bytes', '2026-02-01T15:09:26.7076309-07:00 | master_accessory_loop | SERIES_RUN_SUCCESS | \r\n2026-02-01T15:27:21.8979456-07:00 | master_accessory | LOOP_START | \r\n', 0.95, 1, 1, '2026-02-18 16:37:02', '2026-02-18 16:37:02'),
(29, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: ops_20260217.log | Size: 70 bytes', '2026-02-17T16:39:47.2042084-07:00 | master_accessory | LOOP_START | \r\n', 0.95, 1, 1, '2026-02-18 16:37:02', '2026-02-18 16:37:02'),
(30, 'ops', 'ingest', 0, 'miratv_ingest', NULL, 'ingest_file', 'File: ops_20260218.log | Size: 153 bytes', '2026-02-18T14:36:17.3549867-07:00 | master_accessory_loop | SERIES_RUN_SUCCESS | \r\n2026-02-18T14:36:17.9996358-07:00 | master_accessory | LOOP_START | \r\n', 0.95, 1, 1, '2026-02-18 16:37:03', '2026-02-18 16:37:03');

-- --------------------------------------------------------

--
-- Table structure for table `ai_telemetry`
--

CREATE TABLE `ai_telemetry` (
  `id` bigint(20) NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `task` varchar(64) NOT NULL,
  `source` varchar(32) NOT NULL,
  `time_flexibility` varchar(16) NOT NULL,
  `route` varchar(16) NOT NULL,
  `route_reason` varchar(64) NOT NULL,
  `forced` tinyint(1) NOT NULL,
  `provider` varchar(16) NOT NULL,
  `latency_ms` int(11) NOT NULL,
  `confidence` decimal(5,4) DEFAULT NULL,
  `job_run_id` bigint(20) DEFAULT NULL,
  `job_name` varchar(64) DEFAULT NULL
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
(1, 'Grinder / Ingest Pipeline', '2026-01-29', 'High on state, Low on downstream', '<!--\r\nCOPILOT INSTRUCTIONS (READ CAREFULLY):\r\n\r\nYou are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.\r\n\r\nDO:\r\n- Describe intent, pressure, goals, blind spots\r\n- Use plain language\r\n- Leave unknowns explicit\r\n\r\nDO NOT:\r\n- Propose solutions\r\n- Invent metrics\r\n- Write code\r\n- Make decisions\r\n- Use theory language\r\n\r\nThis file is a SITUATIONAL SNAPSHOT, not a design doc.\r\n\r\nComponent: Grinder / Ingest Pipeline\r\n-->\r\n\r\n# Contextual Summary — Grinder / Ingest Pipeline\r\n\r\n## Component Role\r\n\r\nLocal batch processor on `C:miratv_ingest`. Reads raw IPTV provider data (JSON/XML). Normalizes into structured JSON. Queues for database ingest. Produces processed files and quarantine logs for failures.\r\n\r\n## Current Intent\r\n\r\nExtract structured data from unreliable provider feeds without inventing missing fields. Preserve partial truth explicitly. Flag ambiguities and failures for human review. Enable downstream database ingest with confidence.\r\n\r\n## Operating Mode\r\n\r\nBatch-oriented workers (C:miratv_ingestworkers). Read raw/ folder. Parse JSON/XML. Extract fields into normalized payloads. Quarantine failures into dedicated directories. Write processed/ outputs. Mark checkpoint files for orchestrator tracking.\r\n\r\n## Frequency & Cadence\r\n\r\nTriggered by PowerShell orchestration (spine scheduler). Currently manual or scheduled nightly. No real-time processing. Single provider at a time or sequential batch runs.\r\n\r\n## Pressures Detected\r\n\r\nProvider data inconsistent (missing fields, renamed keys). Parser failures block entire batches. No graceful degradation for partial data. Manual quarantine review creates bottleneck. Unknown which failures are recoverable vs. genuine data issues.\r\n\r\n## Active Constraints\r\n\r\nLocal filesystem only (no direct DB writes). Must preserve all raw data for audit. Parser logic coupled to specific provider format. Quarantined files accumulate without automated cleanup or re-processing. No real-time feedback from database ingest layer.\r\n\r\n## Short-Horizon Goals (Now → Soon)\r\n\r\nParse more provider formats without code changes. Reduce quarantine pile. Surface grinder failures to governance system. Enable AI-assisted recovery of quarantined records. Track parse success rate per provider.\r\n\r\n## Long-Horizon Goals\r\n\r\nZero manual quarantine intervention. Self-healing grinder that learns provider patterns. AI suggests format fixes. Streaming (not batch) processing. Real-time feedback loop from database → grinder.\r\n\r\n## Blind Spots\r\n\r\nUnclear which quarantined files are fixable vs. permanently malformed. No visibility into downstream ingest failures (grinder succeeded, DB write failed). Unknown provider field semantics (is this field optional or missing due to provider error?). No cross-provider pattern recognition.\r\n\r\n## Friction Points\r\n\r\nGrinder workers run independently; no coordination with other workers. Quarantined files require manual inspection. No integration with governance rules (what should grinder reject vs. accept?). Errors don\'t trigger escalation; they just accumulate in logs.\r\n\r\n## Metrics Currently Used\r\n\r\nFile count (raw, processed, quarantine). Parse success/failure count. Job duration.\r\n\r\n## Metrics Missing\r\n\r\nPer-field extraction confidence. Provider consistency score. Quarantine resolution rate. Downstream ingest success vs. grinder output quality. Time-to-fix for quarantined records.\r\n\r\n## Suggested Stored Procedures (Do Not Exist Yet)\r\n\r\n- `sp_grinder_register_job()` - log start/end of grinder run\r\n- `sp_grinder_log_failure()` - insert quarantine event with provider, file, error reason\r\n- `sp_grinder_get_recoverable_failures()` - query quarantine for retryable patterns\r\n- `sp_grinder_confidence_score()` - return extraction confidence per field per provider\r\n\r\n## Desired Context From Other Components\r\n\r\nGovernance: Which fields are mandatory vs. optional? Ops: What downstream DB failures occurred from grinder output? Lake: Historical provider format patterns (has this field appeared before?). Inhibitor: Rules about what constitutes acceptable partial data.\r\n\r\n## Confidence Level\r\n\r\nHigh on current state (observable filesystem, checkpoint files). Medium on downstream effects (unknown how DB layer sees grinder failures). Low on provider semantics (unclear if missing fields are errors or valid nulls).\r\n\r\n## Notes\r\n\r\nGrinder is effectively a filter and normalizer, not an enforcer. It passes data downstream; database layer decides accept/reject. This separation is intentional but creates blind spot: grinder doesn\'t know if its output is usable.\r\n\r\n', '2026-01-29 15:39:53.440371'),
(2, 'Ops / Orchestration', '2026-01-29', 'High on state, Medium on worker state', '<!--\r\nCOPILOT INSTRUCTIONS (READ CAREFULLY):\r\n\r\nYou are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.\r\n\r\nDO:\r\n- Describe intent, pressure, goals, blind spots\r\n- Use plain language\r\n- Leave unknowns explicit\r\n\r\nDO NOT:\r\n- Propose solutions\r\n- Invent metrics\r\n- Write code\r\n- Make decisions\r\n- Use theory language\r\n\r\nThis file is a SITUATIONAL SNAPSHOT, not a design doc.\r\n\r\nComponent: Ops / Orchestration\r\n-->\r\n\r\n# Contextual Summary — Ops / Orchestration\r\n\r\n## Component Role\r\n\r\nMaster scheduler (spine). Coordinates grinder workers. Triggers ingest sequences via PowerShell. Manages job state via `xpdgxfsp_ops` database. Tracks job_runs, job_definitions, checkpoints, failures, locks.\r\n\r\n## Current Intent\r\n\r\nOrchestrate reliable, repeatable, auditable batch pipelines. Prevent job collisions (locks). Track what ran, when, why. Enable human visibility into pipeline health. Provide state recovery on failure.\r\n\r\n## Operating Mode\r\n\r\nPowerShell-driven scheduling (manual triggers or Windows Task Scheduler). Reads job definitions from DB. Manages locks (acquisition, release). Executes workers sequentially or in parallel. Logs events to job_events table. Marks checkpoints for recovery.\r\n\r\n## Frequency & Cadence\r\n\r\nScheduled nightly or on-demand. Single orchestration run per trigger. Sequential or parallel worker execution within one run. Waits for all workers to complete before marking job_runs complete.\r\n\r\n## Pressures Detected\r\n\r\nJob failures don\'t stop pipeline; jobs just error and continue. No escalation path (critical failures don\'t alert). Lock timeouts are manual (no auto-recovery). Checkpoint logic informal (unclear when to retry). Job state can diverge from actual worker state (ghost jobs).\r\n\r\n## Active Constraints\r\n\r\nSingle-threaded orchestration (one spine run at a time, enforced by DB lock). No distributed orchestration. All state in ops DB (no external job queues). Workers execute on same machine as orchestrator. No cross-system coordination.\r\n\r\n## Short-Horizon Goals (Now → Soon)\r\n\r\nClear visibility into job success/failure. Automated alerts for critical failures. Reliable checkpoint restart (resume from failure point). Distinguish retriable vs. permanent failures.\r\n\r\n## Long-Horizon Goals\r\n\r\nDistributed orchestration (multiple spines). Cross-system job dependencies. Real-time worker health monitoring. Automatic escalation for governance violations.\r\n\r\n## Blind Spots\r\n\r\nWorker state vs. job_runs state (did worker truly complete?). Unknown which failures are transient (network, temp file lock) vs. data (provider format changed). No feedback loop from database ingest (did downstream processes succeed?). Unclear job scheduling priority (which job should run first if queue backs up?).\r\n\r\n## Friction Points\r\n\r\nManual lock management. No built-in retry logic (devs must handle). Workers must handle their own checkpointing (inconsistent). Spine doesn\'t know if downstream (DB ingest) succeeded. Job definitions live in DB but logic lives in scripts (two sources of truth).\r\n\r\n## Metrics Currently Used\r\n\r\nJob duration. Job status (success/fail). Failure count per job.\r\n\r\n## Metrics Missing\r\n\r\nWorker-level state (did worker finish, or did it hang?). Lock wait time. Retry count. Time-to-escalation for failures. Success rate of resumed jobs (recovery viability).\r\n\r\n## Suggested Stored Procedures (Do Not Exist Yet)\r\n\r\n- `sp_job_mark_retriable()` - mark failed job as safe to retry\r\n- `sp_job_mark_permanent_failure()` - mark failed job as irrecoverable\r\n- `sp_job_escalate_to_governance()` - route critical failure to IGM\r\n- `sp_job_get_recovery_state()` - return checkpoint data to resume from\r\n\r\n## Desired Context From Other Components\r\n\r\nGrinder: Which output files are valid? Database: Which grinder output was successfully ingested? Governance: Are job failures violations or expected? Human Operator: Do you want to retry this job or escalate?\r\n\r\n## Confidence Level\r\n\r\nHigh on current state (job_runs table is observable, locks are explicit). Medium on worker state (unclear if worker completed or hung). Low on downstream effects (can\'t see if DB ingest succeeded).\r\n\r\n## Notes\r\n\r\nOrchestration is effectively a state tracker and task sequencer, not an enforcer. It coordinates but doesn\'t validate. This separation is intentional but creates blind spot: spine doesn\'t know if its tasks actually succeeded.\r\n\r\n', '2026-01-29 15:39:58.369931'),
(3, 'Database (Authority)', '2026-01-29', 'High on state, Low on lineage', '<!--\r\nCOPILOT INSTRUCTIONS (READ CAREFULLY):\r\n\r\nYou are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.\r\n\r\nDO:\r\n- Describe intent, pressure, goals, blind spots\r\n- Use plain language\r\n- Leave unknowns explicit\r\n\r\nDO NOT:\r\n- Propose solutions\r\n- Invent metrics\r\n- Write code\r\n- Make decisions\r\n- Use theory language\r\n\r\nThis file is a SITUATIONAL SNAPSHOT, not a design doc.\r\n\r\nComponent: Database (Authority) - xpdgxfsp_* (8 databases)\r\n-->\r\n\r\n# Contextual Summary — Database (Authority)\r\n\r\n## Component Role\r\n\r\nMySQL server hosting 8 databases: lake_knowledge, lake_vector, content, cortex, callosum_matrix, ops, inhibitor_govenor_matrix, i_m_g_vector_context, ip. Enforces constraints. Preserves provenance. Audits all writes. Source of truth for all operational, architectural, governance data.\r\n\r\n## Current Intent\r\n\r\nBe the single authoritative record for system state. Enforce integrity through constraints and keys. Never accept invalid writes. Make truth auditable and traceable. Reject rather than corrupt.\r\n\r\n## Operating Mode\r\n\r\nTransactional writes (explicit INSERT/UPDATE/DELETE). Stored procedures handle complex logic. Views for read-only presentation. Triggers for audit logging (where implemented). No direct ORM access; all writes parameterized.\r\n\r\n## Frequency & Cadence\r\n\r\nContinuous operational writes (series ingest, EPG updates, job state). Nightly batch ingests (grinder → ingest workers → DB). Real-time reads (UI queries, API calls). Periodic archival/cleanup (manual or scripted).\r\n\r\n## Pressures Detected\r\n\r\nSchemas growing without consistent versioning. Different DBs have different table structures (no unified schema). Foreign key constraints sometimes unenforced. Audit trail incomplete (not all tables have created_at/updated_by). Raw API responses stored directly (no normalization layer).\r\n\r\n## Active Constraints\r\n\r\nShared hosting (resources limited). No schema versioning. No cross-database transactions. Limited trigger support (performance concern). Credential exposure in legacy scripts (being phased out with CVI).\r\n\r\n## Short-Horizon Goals (Now → Soon)\r\n\r\nUnified schema pattern across all 8 DBs. Complete audit trail (who wrote, when, why). Enforce foreign keys on content references. Twin write enforcement (inhibitor_govenor_matrix ↔ i_m_g_vector_context).\r\n\r\n## Long-Horizon Goals\r\n\r\nSchema versioning and zero-downtime migrations. Cross-database consistency (replication or eventual consistency pattern). Query-time access control (row-level security). Decentralized autonomy (federation).\r\n\r\n## Blind Spots\r\n\r\nUnknown which applications write to which tables. No query logging (can\'t see what\'s being read). Unknown data lineage (where did this record originate?). No enforcement of \"no direct writes\" policy (legacy apps may bypass control layer).\r\n\r\n## Friction Points\r\n\r\nSchema changes require manual coordination. No automated testing of constraint enforcement. Audit trail requires manual trigger creation. Twin-write logic not automated (relies on application layer). Grinder output stored as JSON (requires post-ingest parsing).\r\n\r\n## Metrics Currently Used\r\n\r\nDatabase size. Table row counts. Query latency (app-level, not DB-level).\r\n\r\n## Metrics Missing\r\n\r\nWrite volume per table. Constraint violation attempts. Audit trail completeness (% of writes captured). Data staleness (how old is the oldest record). Foreign key violations (attempted but prevented).\r\n\r\n## Suggested Stored Procedures (Do Not Exist Yet)\r\n\r\n- `sp_audit_write()` - universal audit logging (actor, table, operation, before/after)\r\n- `sp_verify_twins()` - check consistency between inhibitor_govenor_matrix and i_m_g_vector_context\r\n- `sp_get_data_lineage()` - trace record origin (source table, timestamp, actor)\r\n- `sp_enforce_schema_version()` - validate incoming writes against canonical schema\r\n\r\n## Desired Context From Other Components\r\n\r\nGrinder: Which grinder outputs failed to ingest (and why)? Governance: Which tables require twinning? Ops: Which job writes succeeded vs. failed? CVI: What are the allowed write patterns?\r\n\r\n## Confidence Level\r\n\r\nHigh on current state (schema is queryable, constraints are explicit). Medium on write source (who writes what?). Low on data lineage (how did this record get here?).\r\n\r\n## Notes\r\n\r\nDatabase is purely defensive: it enforces what\'s allowed, doesn\'t determine what should happen. This is correct design but creates blind spot: DB rejects bad writes but can\'t advise what\'s good. That judgment lives in application layers.\r\n', '2026-01-29 15:40:03.151598'),
(4, 'Governance / IGM', '2026-01-29', 'High on structure, Low on adoption', '<!--\r\nCOPILOT INSTRUCTIONS (READ CAREFULLY):\r\n\r\nYou are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.\r\n\r\nDO:\r\n- Describe intent, pressure, goals, blind spots\r\n- Use plain language\r\n- Leave unknowns explicit\r\n\r\nDO NOT:\r\n- Propose solutions\r\n- Invent metrics\r\n- Write code\r\n- Make decisions\r\n- Use theory language\r\n\r\nThis file is a SITUATIONAL SNAPSHOT, not a design doc.\r\n\r\nComponent: Governance / IGM (Inhibitor Governor Matrix + i_m_g_vector_context)\r\n-->\r\n\r\n# Contextual Summary — Governance / IGM\r\n\r\n## Component Role\r\n\r\nEnforce architectural rules (canon). Hold candidate rules pending human review. Track governance decisions and attestations. Two databases in twin formation (inhibitor_govenor_matrix, i_m_g_vector_context). Canon rules are enforceable; provisional rules inform but don\'t block.\r\n\r\n## Current Intent\r\n\r\nEmbed governance into system execution, not as external checklist. Make rules observable and auditable. Distinguish between canon (hard constraints) and provisional (guidance). Enable humans to promote rules to canon as confidence grows.\r\n\r\n## Operating Mode\r\n\r\nStored procedures read rules before allowing operations. Attestation spools record rule evaluation in real time. Candidate rules staged for human review. Canon rules enforced at ingest/write time. Overrides logged and escalated.\r\n\r\n## Frequency & Cadence\r\n\r\nRule evaluation on every write (real-time). Human review of candidate rules (ad-hoc, weekly?). Rule promotion to canon (formal, rare). Attestation spools written continuously; aggregated periodically.\r\n\r\n## Pressures Detected\r\n\r\nCandidate rules accumulating without formal review process. Human reviewers unclear (who can promote to canon?). No feedback loop from enforcement (blocked operations not visible to rule authors). Provisional rules remain provisional indefinitely. Rule conflicts undetected (two rules contradict but both active).\r\n\r\n## Active Constraints\r\n\r\nNo rule versioning (old rules can\'t be deprecated easily). Twin constraint (inhibitor_govenor_matrix ↔ i_m_g_vector_context must stay synchronized). No rule composition (can\'t say \"rule A applies IF rule B is active\"). Attestations are append-only (can\'t revise historical judgments).\r\n\r\n## Short-Horizon Goals (Now → Soon)\r\n\r\nPromote TOGAF 6 principles to canon. Establish rule review board and promotion criteria. Route all component writes through governance checks. Make attestation spools queryable.\r\n\r\n## Long-Horizon Goals\r\n\r\nAutomatic rule inference (ML suggests new rules based on pattern violations). Rule evolution (deprecate, versioned rules). Cross-rule dependency tracking. Human-AI collaboration on rule confidence (AI proposes, humans decide).\r\n\r\n## Blind Spots\r\n\r\nUnknown which operations should trigger rule checks. Unclear if existing operations violate rules (audit trail doesn\'t exist yet). No way to test rule changes before deployment. Unknown rule impact (what operations would be blocked by this rule if activated?).\r\n\r\n## Friction Points\r\n\r\nRule review process not formalized. No tool to simulate rule activation. Attestation spools verbose; hard to extract signal. Twin-write enforcement relies on application layer (not DB-enforced). Candidate rules don\'t show which operations they\'d affect.\r\n\r\n## Metrics Currently Used\r\n\r\nRule count (canon vs. provisional). Attestation count (per rule, per status).\r\n\r\n## Metrics Missing\r\n\r\nRule violation frequency (how often are blocked operations attempted?). Rule promotion latency (time from candidate to canon). Override frequency (how often are rules bypassed?). Attestation completion rate (% of operations with attestation vs. silently succeeding).\r\n\r\n## Suggested Stored Procedures (Do Not Exist Yet)\r\n\r\n- `sp_evaluate_rule_set()` - check if operation violates any canon rules\r\n- `sp_simulate_rule_activation()` - show what operations would be blocked if rule activated\r\n- `sp_promote_rule_to_canon()` - promote candidate rule (requires human approval)\r\n- `sp_find_rule_conflicts()` - detect contradictory active rules\r\n\r\n## Desired Context From Other Components\r\n\r\nAll: Which of my writes need rule checks? Database: Have rule checks detected constraint violations before? Grinder: Are there rules about acceptable provider data? Ops: Should failed jobs trigger governance escalation?\r\n\r\n## Confidence Level\r\n\r\nHigh on current state (candidate rules visible in DB, canonical principles known). Medium on application (which operations are actually checking rules?). Low on impact (what happens if we enforce all candidate rules?).\r\n\r\n## Notes\r\n\r\nGovernance is currently advisory (candidate rules) to enforcement-ready (canon rules). This transition is the critical unknown: which rules should be canon, and who decides? Human authority is essential but not yet formalized.\r\n', '2026-01-29 15:40:07.786331'),
(5, 'CVI / AI Interface', '2026-01-29', 'High on design, Low on deployment', '<!--\r\nCOPILOT INSTRUCTIONS (READ CAREFULLY):\r\n\r\nYou are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.\r\n\r\nDO:\r\n- Describe intent, pressure, goals, blind spots\r\n- Use plain language\r\n- Leave unknowns explicit\r\n\r\nDO NOT:\r\n- Propose solutions\r\n- Invent metrics\r\n- Write code\r\n- Make decisions\r\n- Use theory language\r\n\r\nThis file is a SITUATIONAL SNAPSHOT, not a design doc.\r\n\r\nComponent: CVI / AI Interface (Callosum Vector Integration)\r\n-->\r\n\r\n# Contextual Summary — CVI / AI Interface\r\n\r\n## Component Role\r\n\r\nMediate communication between AI components and databases. Provide request/response carousel for structured, audited conversations. Gateway (cvi_gateway.php) exposes whitelisted stored procedures over HTTP. Workers (PowerShell) post queries; processors execute; responses returned to workers.\r\n\r\n## Current Intent\r\n\r\nEnable AI to read system state and propose actions without direct write access. Keep all AI communication parameterized and logged. Separate AI authentication from database access (token vs. credentials). Build audit trail of AI reasoning.\r\n\r\n## Operating Mode\r\n\r\nAI posts structured request JSON via gateway. Gateway validates token, looks up procedure whitelist, executes stored procedure. Results returned as JSON. AI reads response, optionally posts follow-up. All requests logged in cvi_carousel table.\r\n\r\n## Frequency & Cadence\r\n\r\nOpportunistic (on-demand). AI queries when analyzing system state. Processor executes immediately or queues for batch. Response available within seconds to minutes (not real-time). Spools written continuously; aggregated into lake_vector periodically.\r\n\r\n## Pressures Detected\r\n\r\nCVI not yet deployed (only schema + PHP skeleton exist). AI components not registered (no cm_components entries). Request/response carousel not populated (no traffic). Gateway token hardcoded (should be environment variable). Whitelisted procedures not defined (gateway has empty allowed_procs).\r\n\r\n## Active Constraints\r\n\r\nHTTP-only (no WebSocket, no streaming). Token-based auth (shared secret, no per-AI identity). Blocking (AI waits for response; no async pattern). Limited to whitelisted procs (extensible but manual). Response size limited (HTTP payload limits).\r\n\r\n## Short-Horizon Goals (Now → Soon)\r\n\r\nDeploy gateway to production. Register AI components (me, NeuroNet, future ML models). Define initial whitelist of safe procedures. Test request/response flow end-to-end.\r\n\r\n## Long-Horizon Goals\r\n\r\nPer-AI authentication (not shared token). Async request/response (queues, subscriptions). Streaming responses (for large datasets). Rate limiting and quota tracking per AI. Signed requests (HMAC verification).\r\n\r\n## Blind Spots\r\n\r\nUnknown which stored procedures should be whitelisted (safety vs. utility tradeoff). No clarity on AI → AI communication (can AIs talk to each other via CVI?). Unknown how many concurrent requests CVI can handle. No error handling strategy (what if SP timeout?).\r\n\r\n## Friction Points\r\n\r\nToken in code (should be in .env). Gateway validation weak (no signature check, no rate limit). Whitelist requires manual updates (no dynamic registration). No circuit breaker (failed SP doesn\'t gracefully degrade). Request/response schema not validated.\r\n\r\n## Metrics Currently Used\r\n\r\nNone yet (not deployed).\r\n\r\n## Metrics Missing\r\n\r\nRequest volume per AI component. Request latency (AI → gateway → SP → response). Error rate (failed requests, timeouts). Token usage (unusual patterns?). Whitelist hit rate (which procedures used most?).\r\n\r\n## Suggested Stored Procedures (Do Not Exist Yet)\r\n\r\n- `sp_cvi_register_component()` - register new AI entity with token\r\n- `sp_cvi_get_whitelist()` - return allowed procedures for requesting component\r\n- `sp_cvi_log_request()` - audit log for CVI traffic\r\n- `sp_cvi_get_component_quota()` - check request quota for AI\r\n\r\n## Desired Context From Other Components\r\n\r\nAll: Can I trust CVI to be the comms channel? Governance: Should AI requests be checked against rules? Ops: How do we monitor CVI health? Database: Which SPs are safe to expose to AI?\r\n\r\n## Confidence Level\r\n\r\nHigh on architecture (CVI design is solid, schema exists). Low on deployment (not in production yet). Low on adoption (no AI components using it). Low on safety (whitelisting not finalized).\r\n\r\n## Notes\r\n\r\nCVI is the intended channel for AI ↔ system communication but is still a blueprint. It requires activation (deployment + registration) before it becomes a living part of the system. Current state: ready to deploy, waiting for go-ahead.\r\n', '2026-01-29 15:40:12.658104'),
(6, 'Android Client', '2026-01-29', 'High on architecture, Medium on edge cases', '<!--\r\nCOPILOT INSTRUCTIONS (READ CAREFULLY):\r\n\r\nYou are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.\r\n\r\nDO:\r\n- Describe intent, pressure, goals, blind spots\r\n- Use plain language\r\n- Leave unknowns explicit\r\n\r\nDO NOT:\r\n- Propose solutions\r\n- Invent metrics\r\n- Write code\r\n- Make decisions\r\n- Use theory language\r\n\r\nThis file is a SITUATIONAL SNAPSHOT, not a design doc.\r\n\r\nComponent: Android Client (MiraTV app, Phases 1-8)\r\n-->\r\n\r\n# Contextual Summary — Android Client\r\n\r\n## Component Role\r\n\r\nLive TV, VOD, and series streaming app for Android. Activation via MAC address. Session management (username/password). Xtream API client (Retrofit). ExoPlayer HLS playback. RecyclerView shelves. Parental PIN (scaffolded). Adult mode toggle. Favorites (local, not synced).\r\n\r\n## Current Intent\r\n\r\nProvide smooth IPTV experience on TVs (Leanback-compatible). Auto-activate via device identity (MAC). Support Live, VOD, Series browse/search. Stream HLS without credentials stored on device. Respect parental controls.\r\n\r\n## Operating Mode\r\n\r\nSplashActivity → ActivationActivity (MAC validation) → HomeActivity (category shelves) → (ChannelsActivity | VodCategoriesActivity | SeriesCategoriesActivity) → PlayerActivity (ExoPlayer). Session persists via SessionManager. UI driven by Retrofit repos. Coroutine-based async.\r\n\r\n## Frequency & Cadence\r\n\r\nLaunch on-demand (user). Activation once per device. Category fetches on HomeActivity load (cached). Stream URLs fetched on player start (fresh). EPG (future) would be periodic fetch.\r\n\r\n## Pressures Detected\r\n\r\nActivation endpoint hard-coded (`api.miratv.club`). Credentials stored in SessionManager plaintext (should be EncryptedSharedPreferences). RecyclerView/Leanback mixed (not consistent). By-concepts endpoint sometimes returns 0 series (null-handling edge case). Adult PIN dialog not wired. Series categories endpoint returns 14 categories but drill-down unclear.\r\n\r\n## Active Constraints\r\n\r\nAPI 26+ (legacy support limits modern Android features). ExoPlayer 2.19.1 (older version, specific dependency). No local DB (SharedPreferences only). Single-repo pattern (all API calls through repos). No VPN SDK yet (planned Phase 10). No background sync.\r\n\r\n## Short-Horizon Goals (Now → Soon)\r\n\r\nVerify series categories drill-down working (by_concepts returning data). Wire parental PIN dialog. Test adult mode toggle. Verify favorites persistence. Build against all endpoints (series, VOD, live). Test on real TV hardware (Leanback).\r\n\r\n## Long-Horizon Goals\r\n\r\nEncrypt credentials (EncryptedSharedPreferences). Cloud favorites sync. Pluggable VPN provider. EPG overlay. Recording/DVR. Recommendation engine. Offline playback.\r\n\r\n## Blind Spots\r\n\r\nUnknown if all users can see live channels (depends on m3u_link, provider state). Unknown if series drill-down works reliably (inconsistent null fields). Unknown playback issues on various TV hardware (tested only on emulator?). Unknown if parental PIN works when enabled. Unknown user retention rate. Unknown which features matter most.\r\n\r\n## Friction Points\r\n\r\nHard-coded endpoints (not configurable). Credentials not encrypted (security issue). No error recovery (failed API call doesn\'t retry). No offline fallback. RecyclerView jank on large category lists. Player doesn\'t show EPG. Category refresh is manual (no background refresh).\r\n\r\n## Metrics Currently Used\r\n\r\nApp install count (from store). Crash reports (Firebase?). Usage (?) - unknown.\r\n\r\n## Metrics Missing\r\n\r\nSession success rate (% of activation attempts succeed). Stream playback success rate (% of playback attempts play vs. 404). Category load latency. Feature adoption (% using favorites, adult mode, PIN). Drop-off rate (activation → browse → stream).\r\n\r\n## Suggested Stored Procedures (Do Not Exist Yet)\r\n\r\nNone required on app. (DB-side could track app telemetry, but not app responsibility.)\r\n\r\n## Desired Context From Other Components\r\n\r\nXtream API: Which endpoints are stable? Activation: Device binding working? Series categories: Why are some drill-downs returning 0? EPG (future): What data format? VPN (future): Which providers supported?\r\n\r\n## Confidence Level\r\n\r\nHigh on architecture (three-layer pattern is solid, Retrofit repos work). High on core flow (splash → activation → home → player). Medium on edge cases (adult mode, PIN, edge cases). Low on real-world hardware (Leanback/TV testing). Low on user behavior (no analytics yet).\r\n\r\n## Notes\r\n\r\nApp is a competent thin client but blind to backend issues. It succeeds or fails on stream URLs but has no way to diagnose why. This separation is intentional (UI doesn\'t need to know why DB rejected data) but means users get generic errors.\r\n', '2026-01-29 15:40:17.350513'),
(7, 'Human Operator', '2026-01-29', 'High on intent, Low on process', '<!--\r\nCOPILOT INSTRUCTIONS (READ CAREFULLY):\r\n\r\nYou are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.\r\n\r\nDO:\r\n- Describe intent, pressure, goals, blind spots\r\n- Use plain language\r\n- Leave unknowns explicit\r\n\r\nDO NOT:\r\n- Propose solutions\r\n- Invent metrics\r\n- Write code\r\n- Make decisions\r\n- Use theory language\r\n\r\nThis file is a SITUATIONAL SNAPSHOT, not a design doc.\r\n\r\nComponent: Human Operator (You, Architecture Authority)\r\n-->\r\n\r\n# Contextual Summary — Human Operator\r\n\r\n## Component Role\r\n\r\nDecision maker. Rule promoter. Architect. Escalation point for system conflicts. Authority on what is canon vs. provisional. Decides which AI proposals become policy. Owns MiraTV vision and governance. Approves major changes.\r\n\r\n## Current Intent\r\n\r\nMaintain system coherence and truth. Evolve architecture based on evidence (not theory). Decide which technical constraints become non-negotiable rules. Separate signal (important insight) from noise (AI chatter). Keep humans in charge of consequential decisions.\r\n\r\n## Operating Mode\r\n\r\nReads context summaries and architectural docs. Queries databases via trigger script. Reviews AI proposals. Makes binary decisions (canon/provisional/reject). Signs off on major changes. Escalates to board if needed. Sets quarterly priorities.\r\n\r\n## Frequency & Cadence\r\n\r\nDaily or ad-hoc (responding to system signals). Weekly planning (what should system focus on next?). Monthly architectural review (are current principles holding?). Quarterly strategy (bigger bets, direction changes).\r\n\r\n## Pressures Detected\r\n\r\nToo much data (databases, logs, docs, spools). Hard to see patterns (need aggregation). AI sometimes proposes contradictory things (need filtering). Team decisions unclear (who decides what?). Governance rules still provisional (need promotion process). System growing without clear ownership handoff strategy.\r\n\r\n## Active Constraints\r\n\r\nTime (can\'t read everything). Knowledge (some technical details unclear). Availability (can\'t always be present for urgent decisions). Authority scope (some decisions require board/team consensus). Legacy debt (some constraints are inherited, not chosen).\r\n\r\n## Short-Horizon Goals (Now → Soon)\r\n\r\nPromote 6 TOGAF principles to canon rules. Clarify rule review board (who + criteria). Establish escalation path (when does AI surface something to you?). Make system state queryable (one dashboard, not scattered DBs). Decide on CVI deployment (when to activate?).\r\n\r\n## Long-Horizon Goals\r\n\r\nAutomate routine decisions (let AI propose + apply low-stakes rules). Evolve governance from advisory to enforceable. Build human-AI collaborative loop (humans decide, AI executes and learns). Maintain architectural coherence as system scales.\r\n\r\n## Blind Spots\r\n\r\nUnknown which system problems are AI-observable vs. human-only (taste, business judgment). Unknown which team members understand governance model. Unknown user feedback (what do TV watchers actually want?). Unknown where technical debt is hiding. Unknown which decisions were mistakes (no post-mortems yet).\r\n\r\n## Friction Points\r\n\r\nContext scattered across many files (need aggregation). Rule promotion process informal (should be documented). No formal authority structure (who breaks ties?). AI sometimes makes suggestions outside its scope (need boundaries). Emergency decisions vs. deliberate decisions (different speeds).\r\n\r\n## Metrics Currently Used\r\n\r\nSystem uptime. Data accuracy (spot-checks). Rule enforcement (canon rules active?).\r\n\r\n## Metrics Missing\r\n\r\nDecision latency (time from proposal to approval). Decision reversal rate (how often do rules get deprecated?). Team alignment (do people understand the rules?). Business impact (are users happy?). Operator burden (how much of your time is this taking?).\r\n\r\n## Suggested Stored Procedures (Do Not Exist Yet)\r\n\r\n- `sp_get_escalated_items()` - show critical decisions waiting for human approval\r\n- `sp_operator_promote_rule()` - record human decision (rule → canon)\r\n- `sp_operator_override()` - record human override of system decision (with rationale)\r\n- `sp_operator_log_decision()` - audit trail for all human decisions\r\n\r\n## Desired Context From Other Components\r\n\r\nAll: When should I escalate to you? AI (me): What are your decision criteria? Governance: Which rules need your approval? Team: Who do I ask when unsure? System: Are we meeting architectural goals?\r\n\r\n## Confidence Level\r\n\r\nHigh on intent (system should serve your judgment, not replace it). Low on process (no formal decision-making workflow). Low on team alignment (unclear if everyone understands vision). Low on success metrics (hard to measure).\r\n\r\n## Notes\r\n\r\nYou are the coherence keeper. Without your judgment, system becomes a collection of reactive automations. With it, system becomes a governed platform. This role is irreplaceable but can be scaled with better tools (dashboards, automation, escalation routing).\r\n', '2026-01-29 15:40:21.997154');

-- --------------------------------------------------------

--
-- Table structure for table `cm_system_context_snapshots_ml_forecasts`
--

CREATE TABLE `cm_system_context_snapshots_ml_forecasts` (
  `snapshot_id` bigint(20) UNSIGNED NOT NULL,
  `component_name` varchar(255) NOT NULL,
  `snapshot_date` date NOT NULL,
  `forecast_type` varchar(100) DEFAULT NULL,
  `context_snapshot` longtext NOT NULL,
  `forecast_metrics` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`forecast_metrics`)),
  `risk_score` decimal(3,2) DEFAULT NULL,
  `created_at` datetime(6) DEFAULT current_timestamp(6)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `consumed_db_introductions`
--

CREATE TABLE `consumed_db_introductions` (
  `id` int(11) NOT NULL,
  `source_database` varchar(64) NOT NULL,
  `introduction_body` text NOT NULL,
  `published_at` datetime NOT NULL,
  `consumed_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

--
-- Dumping data for table `consumed_db_introductions`
--

INSERT INTO `consumed_db_introductions` (`id`, `source_database`, `introduction_body`, `published_at`, `consumed_at`) VALUES
(1, 'xpdgxfsp_ops', 'Database: xpdgxfsp_ops\nSchema published: 2026-01-30 23:05:13\n\n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: ai_memory_index\n  - id (int) NOT NULL [PRI]\n  - source_db (varchar) NOT NULL \n  - source_table (varchar) NOT NULL \n  - record_id (int) NOT NULL \n  - domain (varchar) NOT NULL \n  - topic (varchar) NULL \n  - unit_type (varchar) NOT NULL \n  - summary (text) NOT NULL \n  - content_ref (text) NOT NULL \n  - confidence (float) NULL \n  - priority_weight (float) NULL \n  - active (tinyint) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: ai_telemetry\n  - id (bigint) NOT NULL [PRI]\n  - created_at (datetime) NOT NULL [MUL]\n  - task (varchar) NOT NULL [MUL]\n  - source (varchar) NOT NULL \n  - time_flexibility (varchar) NOT NULL \n  - route (varchar) NOT NULL [MUL]\n  - route_reason (varchar) NOT NULL \n  - forced (tinyint) NOT NULL \n  - provider (varchar) NOT NULL [MUL]\n  - latency_ms (int) NOT NULL \n  - confidence (decimal) NULL \n  - job_run_id (bigint) NULL [MUL]\n  - job_name (varchar) NULL \n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cm_system_context_snapshots_ml_forecasts\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - forecast_type (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - forecast_metrics (longtext) NULL \n  - risk_score (decimal) NULL \n  - created_at (datetime) NULL \n\nTable: cvi_carousel\n  - id (bigint) NOT NULL [PRI]\n  - component (varchar) NOT NULL \n  - payload_type (varchar) NOT NULL \n  - payload (longtext) NOT NULL \n  - source_actor (varchar) NULL \n  - source_system (varchar) NULL \n  - signature (varchar) NULL \n  - created_at (datetime) NOT NULL \n  - processed (tinyint) NOT NULL \n  - processed_at (datetime) NULL \n\nTable: job_checkpoints\n  - job_key (varchar) NOT NULL [PRI]\n  - environment (enum) NOT NULL [PRI]\n  - checkpoint_key (varchar) NOT NULL [PRI]\n  - checkpoint_val (varchar) NULL \n  - updated_at (datetime) NOT NULL \n\nTable: job_definitions\n  - job_key (varchar) NOT NULL [PRI]\n  - description (varchar) NULL \n  - job_class (enum) NOT NULL \n  - enabled (tinyint) NOT NULL \n  - created_at (datetime) NOT NULL \n\nTable: job_events\n  - event_id (bigint) NOT NULL [PRI]\n  - run_id (bigint) NOT NULL [MUL]\n  - job_key (varchar) NOT NULL \n  - environment (enum) NOT NULL \n  - event_type (varchar) NOT NULL \n  - event_detail (varchar) NULL \n  - created_at (datetime) NOT NULL \n\nTable: job_failures\n  - failure_id (bigint) NOT NULL [PRI]\n  - run_id (bigint) NOT NULL \n  - job_key (varchar) NOT NULL [MUL]\n  - environment (enum) NOT NULL \n  - phase (varchar) NULL \n  - error_type (varchar) NOT NULL \n  - error_summary (varchar) NOT NULL \n  - occurred_at (datetime) NOT NULL \n\nTable: job_locks\n  - job_key (varchar) NOT NULL [PRI]\n  - environment (enum) NOT NULL [PRI]\n  - locked_at (datetime) NOT NULL \n  - expires_at (datetime) NOT NULL [MUL]\n  - host (varchar) NULL \n  - pid (int) NULL \n  - run_id (bigint) NULL \n\nTable: job_runs\n  - run_id (bigint) NOT NULL [PRI]\n  - job_key (varchar) NOT NULL [MUL]\n  - environment (enum) NOT NULL \n  - started_at (datetime) NOT NULL \n  - finished_at (datetime) NULL \n  - status (enum) NOT NULL \n  - exit_code (int) NULL \n  - summary (varchar) NULL \n  - host (varchar) NULL \n  - pid (int) NULL \n  - created_at (datetime) NOT NULL \n\nTable: mc_perspective_records\n  - perspective_id (char) NOT NULL [PRI]\n  - focus (longtext) NOT NULL \n  - views (longtext) NOT NULL \n  - time_from (datetime) NOT NULL \n  - time_to (datetime) NOT NULL \n  - constraints (longtext) NOT NULL \n  - authorized_by (varchar) NOT NULL \n  - created_at (datetime) NOT NULL \n\nTable: ops_events\n  - id (bigint) NOT NULL [PRI]\n  - event_ts (datetime) NOT NULL [MUL]\n  - worker (varchar) NOT NULL [MUL]\n  - stage (varchar) NOT NULL \n  - series_id (int) NULL [MUL]\n  - event_type (varchar) NOT NULL \n  - payload (text) NOT NULL \n  - run_id (varchar) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL \n  - intent (varchar) NULL \n  - requested_at (datetime) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n\nTable: vw_focus_ops\n  - focus_name (varchar) NOT NULL \n  - source_component (varchar) NOT NULL \n  - record_time (datetime) NOT NULL \n  - total_runs (bigint) NOT NULL \n  - active_runs (decimal) NULL \n  - failed_runs (decimal) NULL \n  - capacity_score (decimal) NULL \n  - latest_run_time (datetime) NULL \n\nTable: vw_focus_system\n  - focus_name (varchar) NOT NULL \n  - source_component (varchar) NOT NULL \n  - record_time (datetime) NOT NULL \n  - job_key (varchar) NOT NULL \n  - status (enum) NOT NULL \n  - started_at (datetime) NOT NULL \n  - finished_at (datetime) NULL \n  - duration_sec (bigint) NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:14:33'),
(2, 'xpdgxfsp_content', 'Database: xpdgxfsp_content\nSchema published: 2026-01-30 23:05:13\n\n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: ai_memory_index\n  - id (int) NOT NULL [PRI]\n  - source_db (varchar) NOT NULL \n  - source_table (varchar) NOT NULL \n  - record_id (int) NOT NULL \n  - domain (varchar) NOT NULL \n  - topic (varchar) NULL \n  - unit_type (varchar) NOT NULL \n  - summary (text) NOT NULL \n  - content_ref (text) NOT NULL \n  - confidence (float) NULL \n  - priority_weight (float) NULL \n  - active (tinyint) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: category_concepts\n  - id (int) NOT NULL [PRI]\n  - concept_key (varchar) NOT NULL [UNI]\n  - display_name (varchar) NOT NULL \n\nTable: category_concept_i18n\n  - concept_id (int) NOT NULL [PRI]\n  - lang (char) NOT NULL [PRI]\n  - display_name (varchar) NOT NULL \n\nTable: category_concept_map\n  - category_id (int) NOT NULL [PRI]\n  - concept_id (int) NOT NULL [PRI]\n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cvi_carousel\n  - id (bigint) NOT NULL [PRI]\n  - component (varchar) NOT NULL \n  - payload_type (varchar) NOT NULL \n  - payload (longtext) NOT NULL \n  - source_actor (varchar) NULL \n  - source_system (varchar) NULL \n  - signature (varchar) NULL \n  - created_at (datetime) NOT NULL \n  - processed (tinyint) NOT NULL \n  - processed_at (datetime) NULL \n\nTable: epg_programmes\n  - id (bigint) NOT NULL [PRI]\n  - provider (varchar) NOT NULL [MUL]\n  - channel (varchar) NOT NULL \n  - start_time (char) NOT NULL \n  - end_time (char) NULL \n  - title (text) NULL \n  - description (text) NULL \n\nTable: epg_programs\n  - id (bigint) NOT NULL [PRI]\n  - channel_id (int) NOT NULL [MUL]\n  - epg_channel_id (varchar) NOT NULL [MUL]\n  - title (varchar) NULL \n  - description (text) NULL \n  - start_time (datetime) NOT NULL [MUL]\n  - end_time (datetime) NOT NULL \n  - catchup (tinyint) NULL \n  - provider (varchar) NULL [MUL]\n  - created_at (timestamp) NOT NULL \n  - provider_channel_id (int) NOT NULL [MUL]\n\nTable: live_categories\n  - id (int) NOT NULL [PRI]\n  - provider_category_id (int) NOT NULL \n  - provider (varchar) NOT NULL [MUL]\n  - name (varchar) NOT NULL [MUL]\n  - created_at (timestamp) NOT NULL \n  - updated_at (timestamp) NOT NULL \n\nTable: live_channels\n  - id (int) NOT NULL [PRI]\n  - provider_stream_id (int) NOT NULL \n  - provider (varchar) NOT NULL [MUL]\n  - is_active (tinyint) NULL \n  - updated_at (timestamp) NOT NULL \n  - name (varchar) NOT NULL [MUL]\n  - category_id (int) NULL [MUL]\n  - logo_url (text) NULL \n  - stream_type (varchar) NULL \n  - epg_channel_id (varchar) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: series\n  - id (int) NOT NULL [PRI]\n  - provider_series_id (int) NOT NULL \n  - provider (varchar) NOT NULL [MUL]\n  - name (varchar) NOT NULL [MUL]\n  - plot (text) NULL \n  - genre (varchar) NULL \n  - release_date (date) NULL \n  - rating (decimal) NULL \n  - cover_url (text) NULL \n  - backdrop_url (text) NULL \n  - category_id (int) NULL [MUL]\n  - last_modified (int) NULL \n  - last_provider_update (int) NULL \n  - last_ingest_at (datetime) NOT NULL [MUL]\n  - ingest_hash (char) NULL \n  - is_dirty (tinyint) NOT NULL [MUL]\n  - dirty_reason (varchar) NULL \n  - created_at (timestamp) NOT NULL \n  - updated_at (timestamp) NOT NULL \n  - details_ingested (tinyint) NOT NULL [MUL]\n  - details_ingested_at (datetime) NULL \n  - details_state (varchar) NOT NULL \n  - details_worker (varchar) NULL \n  - details_locked_at (datetime) NULL \n  - details_last_attempt_at (datetime) NULL \n  - details_attempt_count (int) NOT NULL \n  - details_error_code (varchar) NULL \n  - details_error_msg (varchar) NULL \n\nTable: series_ai_metadata\n  - series_id (int) NOT NULL \n  - plot (text) NULL \n  - genre (varchar) NULL \n  - rating (decimal) NULL \n  - release_date (date) NULL \n  - cover_url (text) NULL \n  - backdrop_url (text) NULL \n\nTable: series_categories\n  - id (int) NOT NULL [PRI]\n  - name (varchar) NOT NULL [UNI]\n  - provider (varchar) NULL \n  - provider_category_id (int) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: series_category_map\n  - series_id (int) NOT NULL [PRI]\n  - category_id (int) NOT NULL [PRI]\n  - created_at (timestamp) NOT NULL \n\nTable: series_details\n  - id (int) NOT NULL [PRI]\n  - series_id (int) NOT NULL [UNI]\n  - name (varchar) NULL \n  - plot (text) NULL \n  - genre (varchar) NULL \n  - rating (varchar) NULL \n  - category_id (int) NULL \n  - released (varchar) NULL \n  - raw_json (longtext) NOT NULL \n  - created_at (datetime) NOT NULL \n  - updated_at (datetime) NULL \n  - cast (text) NULL \n  - director (varchar) NULL \n  - youtube_trailer (varchar) NULL \n  - episode_run_time (varchar) NULL \n  - last_modified (int) NULL \n  - backdrop_paths (longtext) NULL \n\nTable: series_details_raw\n  - id (bigint) NOT NULL [PRI]\n  - series_id (int) NOT NULL [MUL]\n  - file_name (varchar) NOT NULL \n  - payload (longtext) NOT NULL \n  - internal_series_id (int) NOT NULL \n  - provider_series_id (int) NOT NULL \n  - provider (varchar) NOT NULL [MUL]\n  - raw_run_json (longtext) NOT NULL \n  - raw_provider_json (longtext) NULL \n  - parsed (tinyint) NOT NULL [MUL]\n  - parse_error (text) NULL \n  - payload_bytes (int) NULL \n  - ingest_duration_ms (int) NULL \n  - created_at (datetime) NOT NULL [MUL]\n  - parsed_at (datetime) NULL \n\nTable: series_episodes\n  - id (int) NOT NULL [PRI]\n  - series_id (int) NOT NULL [MUL]\n  - season_number (int) NOT NULL \n  - provider_episode_id (int) NOT NULL \n  - episode_number (int) NULL \n  - stream_id (int) NULL \n  - container (varchar) NULL \n  - title (varchar) NULL \n  - container_extension (varchar) NULL \n  - duration_secs (int) NULL \n  - rating (decimal) NULL \n  - plot (text) NULL \n  - thumbnail_url (text) NULL \n  - created_at (timestamp) NOT NULL \n  - stream_url (varchar) NULL \n  - resolved_at (datetime) NULL \n\nTable: series_genres_normalized\n  - series_id (int) NULL \n  - genre (varchar) NULL \n\nTable: series_ingest_status\n  - series_id (int) NOT NULL [PRI]\n  - raw_series (tinyint) NOT NULL \n  - series_ext (tinyint) NOT NULL \n  - seasons (tinyint) NOT NULL \n  - season_ext (tinyint) NOT NULL \n  - episodes (tinyint) NOT NULL \n  - last_file (varchar) NULL \n  - updated_at (datetime) NOT NULL \n\nTable: series_metadata_ext\n  - id (int) NOT NULL [PRI]\n  - series_id (int) NOT NULL [UNI]\n  - cast (text) NULL \n  - director (varchar) NULL \n  - plot (text) NULL \n  - overview (text) NULL \n  - backdrop_paths (longtext) NULL \n  - youtube_trailer (varchar) NULL \n  - episode_run_time (varchar) NULL \n  - last_modified (int) NULL \n  - source_provider (varchar) NULL \n  - extracted_at (datetime) NULL \n\nTable: series_seasons\n  - id (int) NOT NULL [PRI]\n  - series_id (int) NOT NULL [MUL]\n  - season_number (int) NOT NULL \n  - name (varchar) NULL \n  - air_date (date) NULL \n  - episode_count (int) NULL \n  - cover_url (text) NULL \n  - created_at (timestamp) NOT NULL \n  - external_season_id (int) NULL \n  - overview (text) NULL \n  - cover_big (text) NULL \n\nTable: series_season_metadata_ext\n  - id (int) NOT NULL [PRI]\n  - series_id (int) NOT NULL [MUL]\n  - season_number (int) NOT NULL \n  - overview (text) NULL \n  - cover_big (text) NULL \n  - external_season_id (int) NULL \n  - extracted_at (datetime) NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL [MUL]\n  - intent (varchar) NULL [MUL]\n  - requested_at (datetime) NULL \n  - routed_to_sps (longtext) NULL \n  - results_returned (int) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n  - fallback_query (text) NULL \n  - created_at (datetime) NULL \n\nTable: vod\n  - vod_id (int) NOT NULL [PRI]\n  - provider (varchar) NOT NULL [MUL]\n  - provider_vod_id (int) NOT NULL \n  - category_id (int) NULL [MUL]\n  - title (varchar) NULL \n  - poster_url (text) NULL \n  - cover_url (text) NULL \n  - plot (text) NULL \n  - rating (decimal) NULL \n  - release_year (int) NULL \n  - duration (int) NULL \n  - added_at (datetime) NULL \n  - updated_at (timestamp) NOT NULL \n\nTable: vod_categories\n  - id (int) NOT NULL [PRI]\n  - provider (varchar) NOT NULL [MUL]\n  - provider_category_id (int) NOT NULL \n  - name (varchar) NULL \n  - parent_id (int) NULL \n  - updated_at (timestamp) NOT NULL \n\nTable: vod_files\n  - vod_file_id (int) NOT NULL [PRI]\n  - vod_id (int) NOT NULL [MUL]\n  - stream_id (int) NOT NULL \n  - container (varchar) NULL \n  - bitrate (int) NULL \n\nTable: vw_series_ingest_status\n  - series_id (int) NOT NULL \n  - series_name (varchar) NOT NULL \n  - provider (varchar) NOT NULL \n  - details_ingested (tinyint) NOT NULL \n  - details_ingested_at (datetime) NULL \n  - is_dirty (tinyint) NOT NULL \n  - raw_payloads (bigint) NOT NULL \n  - has_details (bigint) NOT NULL \n  - seasons_count (bigint) NOT NULL \n  - episodes_count (bigint) NOT NULL \n  - resolved_episodes (bigint) NOT NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:14:33'),
(3, 'xpdgxfsp_callosum_matrix', 'Database: xpdgxfsp_callosum_matrix\nSchema published: 2026-01-30 23:05:13\n\n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: cm_context_summaries\n  - summary_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - summary_type (varchar) NULL \n  - markdown_content (longtext) NOT NULL \n  - version (int) NULL \n  - created_at (datetime) NULL \n  - last_updated (datetime) NULL \n  - authority (varchar) NULL \n  - location_original (varchar) NULL \n  - file_hash (varchar) NULL \n\nTable: cm_documents\n  - document_id (int) NOT NULL [PRI]\n  - document_type (varchar) NOT NULL [MUL]\n  - audience (varchar) NOT NULL \n  - purpose (varchar) NOT NULL \n  - scope (varchar) NULL \n  - source_system (varchar) NULL \n  - source_actor (varchar) NULL \n  - body (text) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cm_document_types\n  - document_type (varchar) NOT NULL [PRI]\n  - description (text) NOT NULL \n  - active (tinyint) NULL \n\nTable: cm_matrix_reports\n  - report_id (int) NOT NULL [PRI]\n  - title (varchar) NULL \n  - derived_from (text) NULL \n  - body (text) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cm_requests\n  - request_id (int) NOT NULL [PRI]\n  - routine_id (int) NOT NULL [MUL]\n  - requested_by (varchar) NULL \n  - request_document_id (int) NULL [MUL]\n  - status (varchar) NULL \n  - created_at (datetime) NULL \n\nTable: cm_routines\n  - routine_id (int) NOT NULL [PRI]\n  - target_db (varchar) NOT NULL \n  - routine_name (varchar) NOT NULL \n  - description (text) NULL \n  - output_document_type (varchar) NULL \n  - active (tinyint) NULL \n  - created_at (datetime) NULL \n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NOT NULL \n\nTable: cm_system_context_snapshots_llm_reasoning\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - reasoning_type (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - interpretation_notes (longtext) NULL \n  - created_at (datetime) NULL \n\nTable: cvi_carousel\n  - id (bigint) NOT NULL [PRI]\n  - component (varchar) NOT NULL \n  - payload_type (varchar) NOT NULL \n  - payload (longtext) NOT NULL \n  - source_actor (varchar) NULL \n  - source_system (varchar) NULL \n  - signature (varchar) NULL \n  - created_at (datetime) NOT NULL \n  - processed (tinyint) NOT NULL \n  - processed_at (datetime) NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL [MUL]\n  - intent (varchar) NULL [MUL]\n  - requested_at (datetime) NULL \n  - routed_to_sps (longtext) NULL \n  - results_returned (int) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n  - fallback_query (text) NULL \n  - created_at (datetime) NULL \n\nTable: vw_cm_documents_read\n  - document_id (int) NOT NULL \n  - document_type (varchar) NOT NULL \n  - audience (varchar) NOT NULL \n  - purpose (varchar) NOT NULL \n  - scope (varchar) NULL \n  - source_system (varchar) NULL \n  - source_actor (varchar) NULL \n  - created_at (datetime) NULL \n  - body (text) NOT NULL \n\nTable: vw_cm_document_input\n  - document_id (binary) NULL \n  - document_type (varchar) NOT NULL \n  - audience (varchar) NOT NULL \n  - purpose (varchar) NOT NULL \n  - scope (varchar) NULL \n  - body (text) NOT NULL \n\nTable: vw_cm_document_types\n  - document_type (varchar) NOT NULL \n  - description (text) NOT NULL \n\nTable: vw_cm_matrix_reports_read\n  - report_id (int) NOT NULL \n  - title (varchar) NULL \n  - derived_from (text) NULL \n  - created_at (datetime) NULL \n  - body (text) NOT NULL \n\nTable: vw_cm_pending_requests\n  - request_id (int) NOT NULL \n  - target_db (varchar) NOT NULL \n  - routine_name (varchar) NOT NULL \n  - description (text) NULL \n  - requested_by (varchar) NULL \n  - status (varchar) NULL \n  - created_at (datetime) NULL \n\nTable: vw_cm_routines_catalog\n  - routine_id (int) NOT NULL \n  - target_db (varchar) NOT NULL \n  - routine_name (varchar) NOT NULL \n  - description (text) NULL \n  - output_document_type (varchar) NULL \n  - active (tinyint) NULL \n  - created_at (datetime) NULL \n\nTable: vw_focus_coordination\n  - focus_name (varchar) NOT NULL \n  - source_component (varchar) NOT NULL \n  - record_time (datetime) NOT NULL \n  - reports_total (bigint) NOT NULL \n  - stale_reports (decimal) NULL \n  - coherence_score (decimal) NULL \n\nTable: vw_focus_cvi\n  - focus_name (varchar) NOT NULL \n  - source_component (varchar) NOT NULL \n  - record_time (datetime) NULL \n  - routine_name (varchar) NOT NULL \n  - requested_by (varchar) NULL \n  - status (varchar) NULL \n  - age_seconds (bigint) NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:14:33'),
(4, 'xpdgxfsp_lake_knowledge', 'Database: xpdgxfsp_lake_knowledge\nSchema published: 2026-01-30 23:05:13\n\n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: ai_events\n  - id (bigint) NOT NULL [PRI]\n  - event_type (varchar) NOT NULL \n  - item_type (enum) NOT NULL \n  - item_id (bigint) NOT NULL \n  - model (varchar) NULL \n  - status (enum) NOT NULL \n  - detail (text) NULL \n  - created_at (datetime) NOT NULL \n\nTable: artifact_topics\n  - artifact_id (bigint) NOT NULL [PRI]\n  - topic_id (bigint) NOT NULL [PRI]\n  - confidence (decimal) NOT NULL \n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NULL \n\nTable: doc_sections\n  - id (bigint) NOT NULL [PRI]\n  - doc_id (bigint) NOT NULL [MUL]\n  - section_type (enum) NOT NULL \n  - title (varchar) NULL \n  - content (longtext) NOT NULL \n  - order_index (int) NOT NULL \n  - created_at (datetime) NOT NULL \n  - pinned (tinyint) NULL \n\nTable: extracted_docs\n  - id (bigint) NOT NULL [PRI]\n  - source (enum) NOT NULL [MUL]\n  - source_ref (varchar) NOT NULL \n  - doc_type (enum) NOT NULL [MUL]\n  - title (varchar) NULL \n  - content (mediumtext) NOT NULL \n  - conversation_id (varchar) NULL [MUL]\n  - message_index (int) NULL \n  - created_at (datetime) NOT NULL \n\nTable: knowledge_links\n  - id (bigint) NOT NULL [PRI]\n  - conversation_id (varchar) NULL [MUL]\n  - artifact_id (bigint) NULL [MUL]\n  - link_type (varchar) NOT NULL [MUL]\n  - confidence (decimal) NULL \n  - rationale (varchar) NULL \n  - created_at (datetime) NULL \n\nTable: knowledge_units\n  - id (bigint) NOT NULL [PRI]\n  - conversation_id (varchar) NULL [MUL]\n  - start_message_id (bigint) NULL [MUL]\n  - end_message_id (bigint) NULL \n  - unit_type (varchar) NOT NULL \n  - authoritative (tinyint) NULL \n  - priority (float) NULL \n  - summary (text) NOT NULL \n  - confidence (decimal) NULL \n  - created_at (datetime) NULL \n  - effective_at (datetime) NULL \n  - topic (varchar) NULL \n  - intent (varchar) NULL \n\nTable: lake_signals\n  - id (bigint) NOT NULL [PRI]\n  - signal_ts (datetime) NOT NULL \n  - domain (varchar) NOT NULL [MUL]\n  - signal_name (varchar) NOT NULL [MUL]\n  - magnitude (int) NULL \n  - confidence (enum) NULL \n  - worker (varchar) NULL \n  - stage (varchar) NULL \n  - series_id (int) NULL [MUL]\n  - payload (longtext) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: priority_signals\n  - item_type (enum) NOT NULL [PRI]\n  - item_id (bigint) NOT NULL [PRI]\n  - reason (varchar) NULL \n  - weight (decimal) NOT NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: raw_artifacts\n  - id (bigint) NOT NULL [PRI]\n  - source (varchar) NOT NULL [MUL]\n  - artifact_type (varchar) NOT NULL [MUL]\n  - artifact_key (varchar) NULL \n  - content (mediumtext) NOT NULL \n  - content_len (int) NOT NULL \n  - metadata (longtext) NULL \n  - created_at (datetime) NULL \n  - inferred_type (varchar) NULL \n  - inferred_topic (varchar) NULL \n\nTable: raw_conversations\n  - id (bigint) NOT NULL [PRI]\n  - source (varchar) NOT NULL \n  - conversation_id (varchar) NOT NULL [MUL]\n  - message_index (int) NOT NULL \n  - role (enum) NOT NULL [MUL]\n  - content (longtext) NOT NULL \n  - created_at (datetime) NULL \n  - ingested_at (datetime) NOT NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL [MUL]\n  - intent (varchar) NULL [MUL]\n  - requested_at (datetime) NULL \n  - routed_to_sps (longtext) NULL \n  - results_returned (int) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n  - fallback_query (text) NULL \n  - created_at (datetime) NULL \n\nTable: topics\n  - id (bigint) NOT NULL [PRI]\n  - topic (varchar) NOT NULL [UNI]\n  - created_at (datetime) NOT NULL \n\nTable: unit_topics\n  - unit_id (bigint) NOT NULL [PRI]\n  - topic_id (bigint) NOT NULL [PRI]\n  - confidence (decimal) NOT NULL \n\nTable: v_artifact_candidates\n  - id (bigint) NOT NULL \n  - artifact_key (varchar) NULL \n  - artifact_type (varchar) NOT NULL \n  - inferred_type (varchar) NULL \n  - preview (varchar) NOT NULL \n  - metadata (longtext) NULL \n  - created_at (datetime) NULL \n\nTable: v_unit_text\n  - unit_id (bigint) NOT NULL \n  - conversation_id (varchar) NULL \n  - full_text (mediumtext) NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:14:33'),
(5, 'xpdgxfsp_ip', 'Database: xpdgxfsp_ip\nSchema published: 2026-01-30 23:05:13\n\n\nTable: account_profile\n  - admin_id (int) NOT NULL [PRI]\n  - name (varchar) NULL \n  - email (varchar) NULL \n  - phone (varchar) NULL \n\nTable: activation_codes\n  - id (int) NOT NULL [PRI]\n  - code (varchar) NOT NULL [UNI]\n  - mac_address (varchar) NULL \n  - m3u_link (text) NULL \n  - user_id (int) NULL \n  - expire_date (date) NULL \n  - status (varchar) NULL \n  - created_at (timestamp) NULL \n  - dns (text) NULL \n  - username (text) NULL \n  - password (text) NULL \n  - plan_name (text) NULL \n\nTable: admins\n  - id (int) NOT NULL [PRI]\n  - username (varchar) NOT NULL [UNI]\n  - password (varchar) NOT NULL \n  - role (varchar) NULL \n  - created_at (timestamp) NULL \n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: ai_memory_index\n  - id (int) NOT NULL [PRI]\n  - source_db (varchar) NOT NULL \n  - source_table (varchar) NOT NULL \n  - record_id (int) NOT NULL \n  - domain (varchar) NOT NULL \n  - topic (varchar) NULL \n  - unit_type (varchar) NOT NULL \n  - summary (text) NOT NULL \n  - content_ref (text) NOT NULL \n  - confidence (float) NULL \n  - priority_weight (float) NULL \n  - active (tinyint) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cvi_carousel\n  - id (bigint) NOT NULL [PRI]\n  - component (varchar) NOT NULL \n  - payload_type (varchar) NOT NULL \n  - payload (longtext) NOT NULL \n  - source_actor (varchar) NULL \n  - source_system (varchar) NULL \n  - signature (varchar) NULL \n  - created_at (datetime) NOT NULL \n  - processed (tinyint) NOT NULL \n  - processed_at (datetime) NULL \n\nTable: device_tokens\n  - id (int) NOT NULL [PRI]\n  - code (varchar) NULL \n  - mac_address (varchar) NULL \n  - device_id (varchar) NULL [UNI]\n  - fcm_token (text) NOT NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: dns_list\n  - id (int) NOT NULL [PRI]\n  - title (varchar) NOT NULL \n  - url (varchar) NOT NULL \n  - created_at (timestamp) NULL \n\nTable: mac_users\n  - id (int) NOT NULL [PRI]\n  - name (varchar) NULL \n  - mac_address (varchar) NOT NULL [UNI]\n  - m3u_link (text) NULL \n  - status (varchar) NULL \n  - expire_date (date) NULL \n  - created_at (timestamp) NULL \n  - device_model (varchar) NULL \n  - os_version (varchar) NULL \n  - protect_playlist (int) NULL \n  - server_name (text) NULL \n  - dns (text) NULL \n  - username (text) NULL \n  - password (text) NULL \n\nTable: notifications\n  - id (int) NOT NULL [PRI]\n  - title (varchar) NOT NULL \n  - message (text) NOT NULL \n  - created_at (timestamp) NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: settings\n  - id (int) NOT NULL [PRI]\n  - key_name (varchar) NOT NULL [UNI]\n  - key_value (text) NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL [MUL]\n  - intent (varchar) NULL [MUL]\n  - requested_at (datetime) NULL \n  - routed_to_sps (longtext) NULL \n  - results_returned (int) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n  - fallback_query (text) NULL \n  - created_at (datetime) NULL \n\nTable: vpn_servers\n  - id (int) NOT NULL [PRI]\n  - title (varchar) NOT NULL \n  - host (varchar) NOT NULL \n  - port (varchar) NULL \n  - protocol (varchar) NULL \n  - username (varchar) NULL \n  - password (varchar) NULL \n  - note (text) NULL \n  - active (tinyint) NULL \n  - created_at (timestamp) NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:14:33'),
(6, 'xpdgxfsp_lake_vector', 'Database: xpdgxfsp_lake_vector\nSchema published: 2026-01-30 23:05:13\n\n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: ai_events\n  - id (bigint) NOT NULL [PRI]\n  - event_type (varchar) NOT NULL \n  - item_type (enum) NOT NULL \n  - item_id (bigint) NOT NULL \n  - model (varchar) NULL \n  - status (enum) NOT NULL \n  - detail (text) NULL \n  - created_at (datetime) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: ai_memory_index\n  - id (int) NOT NULL [PRI]\n  - source_db (varchar) NOT NULL \n  - source_table (varchar) NOT NULL \n  - record_id (int) NOT NULL \n  - domain (varchar) NOT NULL \n  - topic (varchar) NULL \n  - unit_type (varchar) NOT NULL \n  - summary (text) NOT NULL \n  - content_ref (text) NOT NULL \n  - confidence (float) NULL \n  - priority_weight (float) NULL \n  - active (tinyint) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: artifact_topics\n  - artifact_id (bigint) NOT NULL [PRI]\n  - topic_id (bigint) NOT NULL [PRI]\n  - confidence (decimal) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cm_system_context_snapshots_neuronet_signals\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - signal_type (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - delta_metrics (longtext) NULL \n  - confidence_score (decimal) NULL \n  - created_at (datetime) NULL \n\nTable: cvi_carousel\n  - id (bigint) NOT NULL [PRI]\n  - component (varchar) NOT NULL \n  - payload_type (varchar) NOT NULL \n  - payload (longtext) NOT NULL \n  - source_actor (varchar) NULL \n  - source_system (varchar) NULL \n  - signature (varchar) NULL \n  - created_at (datetime) NOT NULL \n  - processed (tinyint) NOT NULL \n  - processed_at (datetime) NULL \n\nTable: doc_sections\n  - id (bigint) NOT NULL [PRI]\n  - doc_id (bigint) NOT NULL [MUL]\n  - section_type (enum) NOT NULL \n  - title (varchar) NULL \n  - content (longtext) NOT NULL \n  - order_index (int) NOT NULL \n  - created_at (datetime) NOT NULL \n  - pinned (tinyint) NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: embeddings\n  - id (bigint) NOT NULL [PRI]\n  - item_type (enum) NOT NULL [MUL]\n  - item_id (bigint) NOT NULL \n  - model (varchar) NOT NULL \n  - dims (int) NOT NULL \n  - embedding_json (longtext) NOT NULL \n  - created_at (datetime) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: embedding_queue\n  - id (bigint) NOT NULL [PRI]\n  - item_type (enum) NOT NULL [MUL]\n  - item_id (bigint) NOT NULL \n  - status (enum) NOT NULL [MUL]\n  - error (text) NULL \n  - created_at (datetime) NOT NULL \n  - updated_at (datetime) NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: extracted_docs\n  - id (bigint) NOT NULL [PRI]\n  - source (enum) NOT NULL [MUL]\n  - source_ref (varchar) NOT NULL \n  - doc_type (enum) NOT NULL [MUL]\n  - title (varchar) NULL \n  - content (mediumtext) NOT NULL \n  - conversation_id (varchar) NULL [MUL]\n  - message_index (int) NULL \n  - created_at (datetime) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: knowledge_links\n  - id (bigint) NOT NULL [PRI]\n  - conversation_id (varchar) NULL [MUL]\n  - artifact_id (bigint) NULL [MUL]\n  - link_type (varchar) NOT NULL [MUL]\n  - confidence (decimal) NULL \n  - rationale (varchar) NULL \n  - created_at (datetime) NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: knowledge_units\n  - id (bigint) NOT NULL [PRI]\n  - conversation_id (varchar) NOT NULL [MUL]\n  - start_message_id (bigint) NOT NULL [MUL]\n  - end_message_id (bigint) NOT NULL \n  - unit_type (enum) NOT NULL \n  - priority (float) NULL \n  - summary (text) NOT NULL \n  - confidence (decimal) NULL \n  - created_at (datetime) NULL \n  - topic (varchar) NULL \n  - intent (varchar) NULL \n  - embedding_status (enum) NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n\nTable: priority_signals\n  - item_type (enum) NOT NULL [PRI]\n  - item_id (bigint) NOT NULL [PRI]\n  - reason (varchar) NULL \n  - weight (decimal) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: raw_artifacts\n  - id (bigint) NOT NULL [PRI]\n  - source (varchar) NOT NULL [MUL]\n  - artifact_type (varchar) NOT NULL [MUL]\n  - artifact_key (varchar) NULL \n  - content (mediumtext) NOT NULL \n  - content_len (int) NOT NULL \n  - metadata (longtext) NULL \n  - created_at (datetime) NULL \n  - inferred_type (varchar) NULL \n  - inferred_topic (varchar) NULL \n  - embedding_status (enum) NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n\nTable: raw_conversations\n  - id (bigint) NOT NULL [PRI]\n  - source (varchar) NOT NULL \n  - conversation_id (varchar) NOT NULL [MUL]\n  - message_index (int) NOT NULL \n  - role (enum) NOT NULL [MUL]\n  - content (longtext) NOT NULL \n  - created_at (datetime) NULL \n  - ingested_at (datetime) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: semantic_vector_store\n  - vector_id (bigint) NOT NULL [PRI]\n  - content_type (varchar) NULL [MUL]\n  - source_id (bigint) NULL \n  - source_table (varchar) NULL [MUL]\n  - content_text (longtext) NULL \n  - embedding_vector (longtext) NULL \n  - vector_model (varchar) NULL \n  - embedding_timestamp (datetime) NULL \n  - confidence (decimal) NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL [MUL]\n  - intent (varchar) NULL [MUL]\n  - requested_at (datetime) NULL \n  - routed_to_sps (longtext) NULL \n  - results_returned (int) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n  - fallback_query (text) NULL \n  - created_at (datetime) NULL \n\nTable: topics\n  - id (bigint) NOT NULL [PRI]\n  - topic (varchar) NOT NULL [UNI]\n  - created_at (datetime) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: unit_topics\n  - unit_id (bigint) NOT NULL [PRI]\n  - topic_id (bigint) NOT NULL [PRI]\n  - confidence (decimal) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: vector_embedding_metadata\n  - metadata_id (bigint) NOT NULL [PRI]\n  - vector_id (bigint) NULL [MUL]\n  - metadata_key (varchar) NULL \n  - metadata_value (text) NULL \n\nTable: v_artifact_candidates\n  - id (bigint) NOT NULL \n  - artifact_key (varchar) NULL \n  - artifact_type (varchar) NOT NULL \n  - inferred_type (varchar) NULL \n  - preview (varchar) NOT NULL \n  - metadata (longtext) NULL \n  - created_at (datetime) NULL \n\nTable: v_unit_text\n  - unit_id (bigint) NOT NULL \n  - conversation_id (varchar) NULL \n  - full_text (mediumtext) NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:14:33');
INSERT INTO `consumed_db_introductions` (`id`, `source_database`, `introduction_body`, `published_at`, `consumed_at`) VALUES
(7, 'xpdgxfsp_inhibitor_govenor_matrix', 'Database: xpdgxfsp_inhibitor_govenor_matrix\nSchema published: 2026-01-30 23:05:13\n\n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cvi_carousel\n  - id (bigint) NOT NULL [PRI]\n  - component (varchar) NOT NULL \n  - payload_type (varchar) NOT NULL \n  - payload (longtext) NOT NULL \n  - source_actor (varchar) NULL \n  - source_system (varchar) NULL \n  - signature (varchar) NULL \n  - created_at (datetime) NOT NULL \n  - processed (tinyint) NOT NULL \n  - processed_at (datetime) NULL \n\nTable: igm_attestations\n  - id (bigint) NOT NULL [PRI]\n  - attested_ts (datetime) NOT NULL \n  - rule_id (varchar) NOT NULL [MUL]\n  - rule_scope (varchar) NULL \n  - rule_state (varchar) NULL \n  - rule_effect (varchar) NULL \n  - worker (varchar) NULL \n  - stage (varchar) NULL \n  - series_id (int) NULL [MUL]\n  - payload (text) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: igm_attestation_ledger\n  - attestation_id (bigint) NOT NULL [PRI]\n  - evaluation_id (bigint) NOT NULL [MUL]\n  - attested_by (enum) NOT NULL \n  - confidence (decimal) NULL \n  - evidence_hash (char) NULL \n  - attested_at (timestamp) NOT NULL \n  - truth_verified (tinyint) NULL \n  - verification_basis (enum) NOT NULL \n\nTable: igm_candidate_rules\n  - candidate_id (int) NOT NULL [PRI]\n  - inferred_rule (text) NOT NULL \n  - source_events (longtext) NOT NULL \n  - confidence_score (decimal) NULL \n  - status (enum) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: igm_governance_examples\n  - example_id (bigint) NOT NULL [PRI]\n  - component_id (varchar) NOT NULL \n  - action_attempted (varchar) NOT NULL \n  - decision (enum) NOT NULL \n  - rationale (text) NOT NULL \n  - actor (enum) NOT NULL \n  - occurred_at (timestamp) NOT NULL \n\nTable: igm_raw_governance_events\n  - event_id (bigint) NOT NULL [PRI]\n  - component_id (varchar) NOT NULL \n  - action_taken (varchar) NOT NULL \n  - rationale (text) NULL \n  - actor (enum) NOT NULL \n  - occurred_at (timestamp) NOT NULL \n\nTable: igm_rules\n  - rule_id (int) NOT NULL [PRI]\n  - rule_code (varchar) NOT NULL [UNI]\n  - rule_name (varchar) NOT NULL \n  - rule_description (text) NOT NULL \n  - togaf_phase (varchar) NULL \n  - rule_type (enum) NOT NULL \n  - severity (enum) NOT NULL \n  - applies_to (longtext) NOT NULL \n  - active (tinyint) NULL \n  - version (int) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: igm_rule_evaluations\n  - evaluation_id (bigint) NOT NULL [PRI]\n  - rule_id (int) NOT NULL [MUL]\n  - rule_version (int) NOT NULL \n  - component_id (varchar) NOT NULL \n  - action_context (varchar) NOT NULL \n  - decision (enum) NOT NULL \n  - evaluated_at (timestamp) NOT NULL \n  - correlation_id (char) NOT NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL [MUL]\n  - intent (varchar) NULL [MUL]\n  - requested_at (datetime) NULL \n  - routed_to_sps (longtext) NULL \n  - results_returned (int) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n  - fallback_query (text) NULL \n  - created_at (datetime) NULL \n\nTable: v_togaf_directive_compliance\n  - rule_code (varchar) NOT NULL \n  - rule_name (varchar) NOT NULL \n  - times_verified (bigint) NOT NULL \n  - last_verified (timestamp) NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:14:33'),
(8, 'xpdgxfsp_i_m_g_vector_context', 'Database: xpdgxfsp_i_m_g_vector_context\nSchema published: 2026-01-30 23:05:13\n\n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: cm_context_summaries\n  - summary_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - summary_type (varchar) NULL \n  - markdown_content (longtext) NOT NULL \n  - version (int) NULL \n  - created_at (datetime) NULL \n  - last_updated (datetime) NULL \n  - authority (varchar) NULL \n  - location_original (varchar) NULL \n  - file_hash (varchar) NULL \n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cm_system_context_snapshots_genai_insights\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - insight_type (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - candidate_rules (longtext) NULL \n  - confidence_level (varchar) NULL \n  - created_at (datetime) NULL \n\nTable: igm_attestation_ledger\n  - attestation_id (bigint) NOT NULL [PRI]\n  - evaluation_id (bigint) NOT NULL [MUL]\n  - attested_by (enum) NOT NULL \n  - confidence (decimal) NULL \n  - evidence_hash (char) NULL \n  - attested_at (timestamp) NOT NULL \n  - truth_verified (tinyint) NULL \n  - verification_basis (enum) NOT NULL \n\nTable: igm_candidate_rules\n  - candidate_id (int) NOT NULL [PRI]\n  - inferred_rule (text) NOT NULL \n  - source_events (longtext) NOT NULL \n  - confidence_score (decimal) NULL \n  - status (enum) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: igm_governance_examples\n  - example_id (bigint) NOT NULL [PRI]\n  - component_id (varchar) NOT NULL \n  - action_attempted (varchar) NOT NULL \n  - decision (enum) NOT NULL \n  - rationale (text) NOT NULL \n  - actor (enum) NOT NULL \n  - occurred_at (timestamp) NOT NULL \n\nTable: igm_raw_governance_events\n  - event_id (bigint) NOT NULL [PRI]\n  - component_id (varchar) NOT NULL \n  - action_taken (varchar) NOT NULL \n  - rationale (text) NULL \n  - actor (enum) NOT NULL \n  - occurred_at (timestamp) NOT NULL \n\nTable: igm_rules\n  - rule_id (int) NOT NULL [PRI]\n  - rule_code (varchar) NOT NULL [UNI]\n  - rule_name (varchar) NOT NULL \n  - rule_description (text) NOT NULL \n  - togaf_phase (varchar) NULL \n  - rule_type (enum) NOT NULL \n  - severity (enum) NOT NULL \n  - applies_to (longtext) NOT NULL \n  - active (tinyint) NULL \n  - version (int) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: igm_rule_evaluations\n  - evaluation_id (bigint) NOT NULL [PRI]\n  - rule_id (int) NOT NULL [MUL]\n  - rule_version (int) NOT NULL \n  - component_id (varchar) NOT NULL \n  - action_context (varchar) NOT NULL \n  - decision (enum) NOT NULL \n  - evaluated_at (timestamp) NOT NULL \n  - correlation_id (char) NOT NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: semantic_vector_store\n  - vector_id (bigint) NOT NULL [PRI]\n  - content_type (varchar) NULL [MUL]\n  - source_id (bigint) NULL \n  - source_table (varchar) NULL [MUL]\n  - content_text (longtext) NULL \n  - embedding_vector (longtext) NULL \n  - vector_model (varchar) NULL \n  - embedding_timestamp (datetime) NULL \n  - confidence (decimal) NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL [MUL]\n  - intent (varchar) NULL [MUL]\n  - requested_at (datetime) NULL \n  - routed_to_sps (longtext) NULL \n  - results_returned (int) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n  - fallback_query (text) NULL \n  - created_at (datetime) NULL \n\nTable: vector_embedding_metadata\n  - metadata_id (bigint) NOT NULL [PRI]\n  - vector_id (bigint) NULL [MUL]\n  - metadata_key (varchar) NULL \n  - metadata_value (text) NULL \n\nTable: v_togaf_directive_compliance\n  - rule_code (varchar) NOT NULL \n  - rule_name (varchar) NOT NULL \n  - times_verified (bigint) NOT NULL \n  - last_verified (timestamp) NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:14:33');

-- --------------------------------------------------------

--
-- Table structure for table `consumed_db_schemas`
--

CREATE TABLE `consumed_db_schemas` (
  `id` int(11) NOT NULL,
  `source_database` varchar(64) NOT NULL,
  `schema_body` text NOT NULL,
  `published_at` datetime NOT NULL,
  `consumed_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

--
-- Dumping data for table `consumed_db_schemas`
--

INSERT INTO `consumed_db_schemas` (`id`, `source_database`, `schema_body`, `published_at`, `consumed_at`) VALUES
(1, 'xpdgxfsp_ops', 'Database: xpdgxfsp_ops\nSchema published: 2026-01-30 23:05:13\n\n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: ai_memory_index\n  - id (int) NOT NULL [PRI]\n  - source_db (varchar) NOT NULL \n  - source_table (varchar) NOT NULL \n  - record_id (int) NOT NULL \n  - domain (varchar) NOT NULL \n  - topic (varchar) NULL \n  - unit_type (varchar) NOT NULL \n  - summary (text) NOT NULL \n  - content_ref (text) NOT NULL \n  - confidence (float) NULL \n  - priority_weight (float) NULL \n  - active (tinyint) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: ai_telemetry\n  - id (bigint) NOT NULL [PRI]\n  - created_at (datetime) NOT NULL [MUL]\n  - task (varchar) NOT NULL [MUL]\n  - source (varchar) NOT NULL \n  - time_flexibility (varchar) NOT NULL \n  - route (varchar) NOT NULL [MUL]\n  - route_reason (varchar) NOT NULL \n  - forced (tinyint) NOT NULL \n  - provider (varchar) NOT NULL [MUL]\n  - latency_ms (int) NOT NULL \n  - confidence (decimal) NULL \n  - job_run_id (bigint) NULL [MUL]\n  - job_name (varchar) NULL \n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cm_system_context_snapshots_ml_forecasts\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - forecast_type (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - forecast_metrics (longtext) NULL \n  - risk_score (decimal) NULL \n  - created_at (datetime) NULL \n\nTable: cvi_carousel\n  - id (bigint) NOT NULL [PRI]\n  - component (varchar) NOT NULL \n  - payload_type (varchar) NOT NULL \n  - payload (longtext) NOT NULL \n  - source_actor (varchar) NULL \n  - source_system (varchar) NULL \n  - signature (varchar) NULL \n  - created_at (datetime) NOT NULL \n  - processed (tinyint) NOT NULL \n  - processed_at (datetime) NULL \n\nTable: job_checkpoints\n  - job_key (varchar) NOT NULL [PRI]\n  - environment (enum) NOT NULL [PRI]\n  - checkpoint_key (varchar) NOT NULL [PRI]\n  - checkpoint_val (varchar) NULL \n  - updated_at (datetime) NOT NULL \n\nTable: job_definitions\n  - job_key (varchar) NOT NULL [PRI]\n  - description (varchar) NULL \n  - job_class (enum) NOT NULL \n  - enabled (tinyint) NOT NULL \n  - created_at (datetime) NOT NULL \n\nTable: job_events\n  - event_id (bigint) NOT NULL [PRI]\n  - run_id (bigint) NOT NULL [MUL]\n  - job_key (varchar) NOT NULL \n  - environment (enum) NOT NULL \n  - event_type (varchar) NOT NULL \n  - event_detail (varchar) NULL \n  - created_at (datetime) NOT NULL \n\nTable: job_failures\n  - failure_id (bigint) NOT NULL [PRI]\n  - run_id (bigint) NOT NULL \n  - job_key (varchar) NOT NULL [MUL]\n  - environment (enum) NOT NULL \n  - phase (varchar) NULL \n  - error_type (varchar) NOT NULL \n  - error_summary (varchar) NOT NULL \n  - occurred_at (datetime) NOT NULL \n\nTable: job_locks\n  - job_key (varchar) NOT NULL [PRI]\n  - environment (enum) NOT NULL [PRI]\n  - locked_at (datetime) NOT NULL \n  - expires_at (datetime) NOT NULL [MUL]\n  - host (varchar) NULL \n  - pid (int) NULL \n  - run_id (bigint) NULL \n\nTable: job_runs\n  - run_id (bigint) NOT NULL [PRI]\n  - job_key (varchar) NOT NULL [MUL]\n  - environment (enum) NOT NULL \n  - started_at (datetime) NOT NULL \n  - finished_at (datetime) NULL \n  - status (enum) NOT NULL \n  - exit_code (int) NULL \n  - summary (varchar) NULL \n  - host (varchar) NULL \n  - pid (int) NULL \n  - created_at (datetime) NOT NULL \n\nTable: mc_perspective_records\n  - perspective_id (char) NOT NULL [PRI]\n  - focus (longtext) NOT NULL \n  - views (longtext) NOT NULL \n  - time_from (datetime) NOT NULL \n  - time_to (datetime) NOT NULL \n  - constraints (longtext) NOT NULL \n  - authorized_by (varchar) NOT NULL \n  - created_at (datetime) NOT NULL \n\nTable: ops_events\n  - id (bigint) NOT NULL [PRI]\n  - event_ts (datetime) NOT NULL [MUL]\n  - worker (varchar) NOT NULL [MUL]\n  - stage (varchar) NOT NULL \n  - series_id (int) NULL [MUL]\n  - event_type (varchar) NOT NULL \n  - payload (text) NOT NULL \n  - run_id (varchar) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL \n  - intent (varchar) NULL \n  - requested_at (datetime) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n\nTable: vw_focus_ops\n  - focus_name (varchar) NOT NULL \n  - source_component (varchar) NOT NULL \n  - record_time (datetime) NOT NULL \n  - total_runs (bigint) NOT NULL \n  - active_runs (decimal) NULL \n  - failed_runs (decimal) NULL \n  - capacity_score (decimal) NULL \n  - latest_run_time (datetime) NULL \n\nTable: vw_focus_system\n  - focus_name (varchar) NOT NULL \n  - source_component (varchar) NOT NULL \n  - record_time (datetime) NOT NULL \n  - job_key (varchar) NOT NULL \n  - status (enum) NOT NULL \n  - started_at (datetime) NOT NULL \n  - finished_at (datetime) NULL \n  - duration_sec (bigint) NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:08:02'),
(2, 'xpdgxfsp_content', 'Database: xpdgxfsp_content\nSchema published: 2026-01-30 23:05:13\n\n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: ai_memory_index\n  - id (int) NOT NULL [PRI]\n  - source_db (varchar) NOT NULL \n  - source_table (varchar) NOT NULL \n  - record_id (int) NOT NULL \n  - domain (varchar) NOT NULL \n  - topic (varchar) NULL \n  - unit_type (varchar) NOT NULL \n  - summary (text) NOT NULL \n  - content_ref (text) NOT NULL \n  - confidence (float) NULL \n  - priority_weight (float) NULL \n  - active (tinyint) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: category_concepts\n  - id (int) NOT NULL [PRI]\n  - concept_key (varchar) NOT NULL [UNI]\n  - display_name (varchar) NOT NULL \n\nTable: category_concept_i18n\n  - concept_id (int) NOT NULL [PRI]\n  - lang (char) NOT NULL [PRI]\n  - display_name (varchar) NOT NULL \n\nTable: category_concept_map\n  - category_id (int) NOT NULL [PRI]\n  - concept_id (int) NOT NULL [PRI]\n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cvi_carousel\n  - id (bigint) NOT NULL [PRI]\n  - component (varchar) NOT NULL \n  - payload_type (varchar) NOT NULL \n  - payload (longtext) NOT NULL \n  - source_actor (varchar) NULL \n  - source_system (varchar) NULL \n  - signature (varchar) NULL \n  - created_at (datetime) NOT NULL \n  - processed (tinyint) NOT NULL \n  - processed_at (datetime) NULL \n\nTable: epg_programmes\n  - id (bigint) NOT NULL [PRI]\n  - provider (varchar) NOT NULL [MUL]\n  - channel (varchar) NOT NULL \n  - start_time (char) NOT NULL \n  - end_time (char) NULL \n  - title (text) NULL \n  - description (text) NULL \n\nTable: epg_programs\n  - id (bigint) NOT NULL [PRI]\n  - channel_id (int) NOT NULL [MUL]\n  - epg_channel_id (varchar) NOT NULL [MUL]\n  - title (varchar) NULL \n  - description (text) NULL \n  - start_time (datetime) NOT NULL [MUL]\n  - end_time (datetime) NOT NULL \n  - catchup (tinyint) NULL \n  - provider (varchar) NULL [MUL]\n  - created_at (timestamp) NOT NULL \n  - provider_channel_id (int) NOT NULL [MUL]\n\nTable: live_categories\n  - id (int) NOT NULL [PRI]\n  - provider_category_id (int) NOT NULL \n  - provider (varchar) NOT NULL [MUL]\n  - name (varchar) NOT NULL [MUL]\n  - created_at (timestamp) NOT NULL \n  - updated_at (timestamp) NOT NULL \n\nTable: live_channels\n  - id (int) NOT NULL [PRI]\n  - provider_stream_id (int) NOT NULL \n  - provider (varchar) NOT NULL [MUL]\n  - is_active (tinyint) NULL \n  - updated_at (timestamp) NOT NULL \n  - name (varchar) NOT NULL [MUL]\n  - category_id (int) NULL [MUL]\n  - logo_url (text) NULL \n  - stream_type (varchar) NULL \n  - epg_channel_id (varchar) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: series\n  - id (int) NOT NULL [PRI]\n  - provider_series_id (int) NOT NULL \n  - provider (varchar) NOT NULL [MUL]\n  - name (varchar) NOT NULL [MUL]\n  - plot (text) NULL \n  - genre (varchar) NULL \n  - release_date (date) NULL \n  - rating (decimal) NULL \n  - cover_url (text) NULL \n  - backdrop_url (text) NULL \n  - category_id (int) NULL [MUL]\n  - last_modified (int) NULL \n  - last_provider_update (int) NULL \n  - last_ingest_at (datetime) NOT NULL [MUL]\n  - ingest_hash (char) NULL \n  - is_dirty (tinyint) NOT NULL [MUL]\n  - dirty_reason (varchar) NULL \n  - created_at (timestamp) NOT NULL \n  - updated_at (timestamp) NOT NULL \n  - details_ingested (tinyint) NOT NULL [MUL]\n  - details_ingested_at (datetime) NULL \n  - details_state (varchar) NOT NULL \n  - details_worker (varchar) NULL \n  - details_locked_at (datetime) NULL \n  - details_last_attempt_at (datetime) NULL \n  - details_attempt_count (int) NOT NULL \n  - details_error_code (varchar) NULL \n  - details_error_msg (varchar) NULL \n\nTable: series_ai_metadata\n  - series_id (int) NOT NULL \n  - plot (text) NULL \n  - genre (varchar) NULL \n  - rating (decimal) NULL \n  - release_date (date) NULL \n  - cover_url (text) NULL \n  - backdrop_url (text) NULL \n\nTable: series_categories\n  - id (int) NOT NULL [PRI]\n  - name (varchar) NOT NULL [UNI]\n  - provider (varchar) NULL \n  - provider_category_id (int) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: series_category_map\n  - series_id (int) NOT NULL [PRI]\n  - category_id (int) NOT NULL [PRI]\n  - created_at (timestamp) NOT NULL \n\nTable: series_details\n  - id (int) NOT NULL [PRI]\n  - series_id (int) NOT NULL [UNI]\n  - name (varchar) NULL \n  - plot (text) NULL \n  - genre (varchar) NULL \n  - rating (varchar) NULL \n  - category_id (int) NULL \n  - released (varchar) NULL \n  - raw_json (longtext) NOT NULL \n  - created_at (datetime) NOT NULL \n  - updated_at (datetime) NULL \n  - cast (text) NULL \n  - director (varchar) NULL \n  - youtube_trailer (varchar) NULL \n  - episode_run_time (varchar) NULL \n  - last_modified (int) NULL \n  - backdrop_paths (longtext) NULL \n\nTable: series_details_raw\n  - id (bigint) NOT NULL [PRI]\n  - series_id (int) NOT NULL [MUL]\n  - file_name (varchar) NOT NULL \n  - payload (longtext) NOT NULL \n  - internal_series_id (int) NOT NULL \n  - provider_series_id (int) NOT NULL \n  - provider (varchar) NOT NULL [MUL]\n  - raw_run_json (longtext) NOT NULL \n  - raw_provider_json (longtext) NULL \n  - parsed (tinyint) NOT NULL [MUL]\n  - parse_error (text) NULL \n  - payload_bytes (int) NULL \n  - ingest_duration_ms (int) NULL \n  - created_at (datetime) NOT NULL [MUL]\n  - parsed_at (datetime) NULL \n\nTable: series_episodes\n  - id (int) NOT NULL [PRI]\n  - series_id (int) NOT NULL [MUL]\n  - season_number (int) NOT NULL \n  - provider_episode_id (int) NOT NULL \n  - episode_number (int) NULL \n  - stream_id (int) NULL \n  - container (varchar) NULL \n  - title (varchar) NULL \n  - container_extension (varchar) NULL \n  - duration_secs (int) NULL \n  - rating (decimal) NULL \n  - plot (text) NULL \n  - thumbnail_url (text) NULL \n  - created_at (timestamp) NOT NULL \n  - stream_url (varchar) NULL \n  - resolved_at (datetime) NULL \n\nTable: series_genres_normalized\n  - series_id (int) NULL \n  - genre (varchar) NULL \n\nTable: series_ingest_status\n  - series_id (int) NOT NULL [PRI]\n  - raw_series (tinyint) NOT NULL \n  - series_ext (tinyint) NOT NULL \n  - seasons (tinyint) NOT NULL \n  - season_ext (tinyint) NOT NULL \n  - episodes (tinyint) NOT NULL \n  - last_file (varchar) NULL \n  - updated_at (datetime) NOT NULL \n\nTable: series_metadata_ext\n  - id (int) NOT NULL [PRI]\n  - series_id (int) NOT NULL [UNI]\n  - cast (text) NULL \n  - director (varchar) NULL \n  - plot (text) NULL \n  - overview (text) NULL \n  - backdrop_paths (longtext) NULL \n  - youtube_trailer (varchar) NULL \n  - episode_run_time (varchar) NULL \n  - last_modified (int) NULL \n  - source_provider (varchar) NULL \n  - extracted_at (datetime) NULL \n\nTable: series_seasons\n  - id (int) NOT NULL [PRI]\n  - series_id (int) NOT NULL [MUL]\n  - season_number (int) NOT NULL \n  - name (varchar) NULL \n  - air_date (date) NULL \n  - episode_count (int) NULL \n  - cover_url (text) NULL \n  - created_at (timestamp) NOT NULL \n  - external_season_id (int) NULL \n  - overview (text) NULL \n  - cover_big (text) NULL \n\nTable: series_season_metadata_ext\n  - id (int) NOT NULL [PRI]\n  - series_id (int) NOT NULL [MUL]\n  - season_number (int) NOT NULL \n  - overview (text) NULL \n  - cover_big (text) NULL \n  - external_season_id (int) NULL \n  - extracted_at (datetime) NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL [MUL]\n  - intent (varchar) NULL [MUL]\n  - requested_at (datetime) NULL \n  - routed_to_sps (longtext) NULL \n  - results_returned (int) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n  - fallback_query (text) NULL \n  - created_at (datetime) NULL \n\nTable: vod\n  - vod_id (int) NOT NULL [PRI]\n  - provider (varchar) NOT NULL [MUL]\n  - provider_vod_id (int) NOT NULL \n  - category_id (int) NULL [MUL]\n  - title (varchar) NULL \n  - poster_url (text) NULL \n  - cover_url (text) NULL \n  - plot (text) NULL \n  - rating (decimal) NULL \n  - release_year (int) NULL \n  - duration (int) NULL \n  - added_at (datetime) NULL \n  - updated_at (timestamp) NOT NULL \n\nTable: vod_categories\n  - id (int) NOT NULL [PRI]\n  - provider (varchar) NOT NULL [MUL]\n  - provider_category_id (int) NOT NULL \n  - name (varchar) NULL \n  - parent_id (int) NULL \n  - updated_at (timestamp) NOT NULL \n\nTable: vod_files\n  - vod_file_id (int) NOT NULL [PRI]\n  - vod_id (int) NOT NULL [MUL]\n  - stream_id (int) NOT NULL \n  - container (varchar) NULL \n  - bitrate (int) NULL \n\nTable: vw_series_ingest_status\n  - series_id (int) NOT NULL \n  - series_name (varchar) NOT NULL \n  - provider (varchar) NOT NULL \n  - details_ingested (tinyint) NOT NULL \n  - details_ingested_at (datetime) NULL \n  - is_dirty (tinyint) NOT NULL \n  - raw_payloads (bigint) NOT NULL \n  - has_details (bigint) NOT NULL \n  - seasons_count (bigint) NOT NULL \n  - episodes_count (bigint) NOT NULL \n  - resolved_episodes (bigint) NOT NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:08:02'),
(3, 'xpdgxfsp_callosum_matrix', 'Database: xpdgxfsp_callosum_matrix\nSchema published: 2026-01-30 23:05:13\n\n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: cm_context_summaries\n  - summary_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - summary_type (varchar) NULL \n  - markdown_content (longtext) NOT NULL \n  - version (int) NULL \n  - created_at (datetime) NULL \n  - last_updated (datetime) NULL \n  - authority (varchar) NULL \n  - location_original (varchar) NULL \n  - file_hash (varchar) NULL \n\nTable: cm_documents\n  - document_id (int) NOT NULL [PRI]\n  - document_type (varchar) NOT NULL [MUL]\n  - audience (varchar) NOT NULL \n  - purpose (varchar) NOT NULL \n  - scope (varchar) NULL \n  - source_system (varchar) NULL \n  - source_actor (varchar) NULL \n  - body (text) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cm_document_types\n  - document_type (varchar) NOT NULL [PRI]\n  - description (text) NOT NULL \n  - active (tinyint) NULL \n\nTable: cm_matrix_reports\n  - report_id (int) NOT NULL [PRI]\n  - title (varchar) NULL \n  - derived_from (text) NULL \n  - body (text) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cm_requests\n  - request_id (int) NOT NULL [PRI]\n  - routine_id (int) NOT NULL [MUL]\n  - requested_by (varchar) NULL \n  - request_document_id (int) NULL [MUL]\n  - status (varchar) NULL \n  - created_at (datetime) NULL \n\nTable: cm_routines\n  - routine_id (int) NOT NULL [PRI]\n  - target_db (varchar) NOT NULL \n  - routine_name (varchar) NOT NULL \n  - description (text) NULL \n  - output_document_type (varchar) NULL \n  - active (tinyint) NULL \n  - created_at (datetime) NULL \n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NOT NULL \n\nTable: cm_system_context_snapshots_llm_reasoning\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - reasoning_type (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - interpretation_notes (longtext) NULL \n  - created_at (datetime) NULL \n\nTable: cvi_carousel\n  - id (bigint) NOT NULL [PRI]\n  - component (varchar) NOT NULL \n  - payload_type (varchar) NOT NULL \n  - payload (longtext) NOT NULL \n  - source_actor (varchar) NULL \n  - source_system (varchar) NULL \n  - signature (varchar) NULL \n  - created_at (datetime) NOT NULL \n  - processed (tinyint) NOT NULL \n  - processed_at (datetime) NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL [MUL]\n  - intent (varchar) NULL [MUL]\n  - requested_at (datetime) NULL \n  - routed_to_sps (longtext) NULL \n  - results_returned (int) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n  - fallback_query (text) NULL \n  - created_at (datetime) NULL \n\nTable: vw_cm_documents_read\n  - document_id (int) NOT NULL \n  - document_type (varchar) NOT NULL \n  - audience (varchar) NOT NULL \n  - purpose (varchar) NOT NULL \n  - scope (varchar) NULL \n  - source_system (varchar) NULL \n  - source_actor (varchar) NULL \n  - created_at (datetime) NULL \n  - body (text) NOT NULL \n\nTable: vw_cm_document_input\n  - document_id (binary) NULL \n  - document_type (varchar) NOT NULL \n  - audience (varchar) NOT NULL \n  - purpose (varchar) NOT NULL \n  - scope (varchar) NULL \n  - body (text) NOT NULL \n\nTable: vw_cm_document_types\n  - document_type (varchar) NOT NULL \n  - description (text) NOT NULL \n\nTable: vw_cm_matrix_reports_read\n  - report_id (int) NOT NULL \n  - title (varchar) NULL \n  - derived_from (text) NULL \n  - created_at (datetime) NULL \n  - body (text) NOT NULL \n\nTable: vw_cm_pending_requests\n  - request_id (int) NOT NULL \n  - target_db (varchar) NOT NULL \n  - routine_name (varchar) NOT NULL \n  - description (text) NULL \n  - requested_by (varchar) NULL \n  - status (varchar) NULL \n  - created_at (datetime) NULL \n\nTable: vw_cm_routines_catalog\n  - routine_id (int) NOT NULL \n  - target_db (varchar) NOT NULL \n  - routine_name (varchar) NOT NULL \n  - description (text) NULL \n  - output_document_type (varchar) NULL \n  - active (tinyint) NULL \n  - created_at (datetime) NULL \n\nTable: vw_focus_coordination\n  - focus_name (varchar) NOT NULL \n  - source_component (varchar) NOT NULL \n  - record_time (datetime) NOT NULL \n  - reports_total (bigint) NOT NULL \n  - stale_reports (decimal) NULL \n  - coherence_score (decimal) NULL \n\nTable: vw_focus_cvi\n  - focus_name (varchar) NOT NULL \n  - source_component (varchar) NOT NULL \n  - record_time (datetime) NULL \n  - routine_name (varchar) NOT NULL \n  - requested_by (varchar) NULL \n  - status (varchar) NULL \n  - age_seconds (bigint) NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:08:02'),
(4, 'xpdgxfsp_lake_knowledge', 'Database: xpdgxfsp_lake_knowledge\nSchema published: 2026-01-30 23:05:13\n\n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: ai_events\n  - id (bigint) NOT NULL [PRI]\n  - event_type (varchar) NOT NULL \n  - item_type (enum) NOT NULL \n  - item_id (bigint) NOT NULL \n  - model (varchar) NULL \n  - status (enum) NOT NULL \n  - detail (text) NULL \n  - created_at (datetime) NOT NULL \n\nTable: artifact_topics\n  - artifact_id (bigint) NOT NULL [PRI]\n  - topic_id (bigint) NOT NULL [PRI]\n  - confidence (decimal) NOT NULL \n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NULL \n\nTable: doc_sections\n  - id (bigint) NOT NULL [PRI]\n  - doc_id (bigint) NOT NULL [MUL]\n  - section_type (enum) NOT NULL \n  - title (varchar) NULL \n  - content (longtext) NOT NULL \n  - order_index (int) NOT NULL \n  - created_at (datetime) NOT NULL \n  - pinned (tinyint) NULL \n\nTable: extracted_docs\n  - id (bigint) NOT NULL [PRI]\n  - source (enum) NOT NULL [MUL]\n  - source_ref (varchar) NOT NULL \n  - doc_type (enum) NOT NULL [MUL]\n  - title (varchar) NULL \n  - content (mediumtext) NOT NULL \n  - conversation_id (varchar) NULL [MUL]\n  - message_index (int) NULL \n  - created_at (datetime) NOT NULL \n\nTable: knowledge_links\n  - id (bigint) NOT NULL [PRI]\n  - conversation_id (varchar) NULL [MUL]\n  - artifact_id (bigint) NULL [MUL]\n  - link_type (varchar) NOT NULL [MUL]\n  - confidence (decimal) NULL \n  - rationale (varchar) NULL \n  - created_at (datetime) NULL \n\nTable: knowledge_units\n  - id (bigint) NOT NULL [PRI]\n  - conversation_id (varchar) NULL [MUL]\n  - start_message_id (bigint) NULL [MUL]\n  - end_message_id (bigint) NULL \n  - unit_type (varchar) NOT NULL \n  - authoritative (tinyint) NULL \n  - priority (float) NULL \n  - summary (text) NOT NULL \n  - confidence (decimal) NULL \n  - created_at (datetime) NULL \n  - effective_at (datetime) NULL \n  - topic (varchar) NULL \n  - intent (varchar) NULL \n\nTable: lake_signals\n  - id (bigint) NOT NULL [PRI]\n  - signal_ts (datetime) NOT NULL \n  - domain (varchar) NOT NULL [MUL]\n  - signal_name (varchar) NOT NULL [MUL]\n  - magnitude (int) NULL \n  - confidence (enum) NULL \n  - worker (varchar) NULL \n  - stage (varchar) NULL \n  - series_id (int) NULL [MUL]\n  - payload (longtext) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: priority_signals\n  - item_type (enum) NOT NULL [PRI]\n  - item_id (bigint) NOT NULL [PRI]\n  - reason (varchar) NULL \n  - weight (decimal) NOT NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: raw_artifacts\n  - id (bigint) NOT NULL [PRI]\n  - source (varchar) NOT NULL [MUL]\n  - artifact_type (varchar) NOT NULL [MUL]\n  - artifact_key (varchar) NULL \n  - content (mediumtext) NOT NULL \n  - content_len (int) NOT NULL \n  - metadata (longtext) NULL \n  - created_at (datetime) NULL \n  - inferred_type (varchar) NULL \n  - inferred_topic (varchar) NULL \n\nTable: raw_conversations\n  - id (bigint) NOT NULL [PRI]\n  - source (varchar) NOT NULL \n  - conversation_id (varchar) NOT NULL [MUL]\n  - message_index (int) NOT NULL \n  - role (enum) NOT NULL [MUL]\n  - content (longtext) NOT NULL \n  - created_at (datetime) NULL \n  - ingested_at (datetime) NOT NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL [MUL]\n  - intent (varchar) NULL [MUL]\n  - requested_at (datetime) NULL \n  - routed_to_sps (longtext) NULL \n  - results_returned (int) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n  - fallback_query (text) NULL \n  - created_at (datetime) NULL \n\nTable: topics\n  - id (bigint) NOT NULL [PRI]\n  - topic (varchar) NOT NULL [UNI]\n  - created_at (datetime) NOT NULL \n\nTable: unit_topics\n  - unit_id (bigint) NOT NULL [PRI]\n  - topic_id (bigint) NOT NULL [PRI]\n  - confidence (decimal) NOT NULL \n\nTable: v_artifact_candidates\n  - id (bigint) NOT NULL \n  - artifact_key (varchar) NULL \n  - artifact_type (varchar) NOT NULL \n  - inferred_type (varchar) NULL \n  - preview (varchar) NOT NULL \n  - metadata (longtext) NULL \n  - created_at (datetime) NULL \n\nTable: v_unit_text\n  - unit_id (bigint) NOT NULL \n  - conversation_id (varchar) NULL \n  - full_text (mediumtext) NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:08:02'),
(5, 'xpdgxfsp_ip', 'Database: xpdgxfsp_ip\nSchema published: 2026-01-30 23:05:13\n\n\nTable: account_profile\n  - admin_id (int) NOT NULL [PRI]\n  - name (varchar) NULL \n  - email (varchar) NULL \n  - phone (varchar) NULL \n\nTable: activation_codes\n  - id (int) NOT NULL [PRI]\n  - code (varchar) NOT NULL [UNI]\n  - mac_address (varchar) NULL \n  - m3u_link (text) NULL \n  - user_id (int) NULL \n  - expire_date (date) NULL \n  - status (varchar) NULL \n  - created_at (timestamp) NULL \n  - dns (text) NULL \n  - username (text) NULL \n  - password (text) NULL \n  - plan_name (text) NULL \n\nTable: admins\n  - id (int) NOT NULL [PRI]\n  - username (varchar) NOT NULL [UNI]\n  - password (varchar) NOT NULL \n  - role (varchar) NULL \n  - created_at (timestamp) NULL \n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: ai_memory_index\n  - id (int) NOT NULL [PRI]\n  - source_db (varchar) NOT NULL \n  - source_table (varchar) NOT NULL \n  - record_id (int) NOT NULL \n  - domain (varchar) NOT NULL \n  - topic (varchar) NULL \n  - unit_type (varchar) NOT NULL \n  - summary (text) NOT NULL \n  - content_ref (text) NOT NULL \n  - confidence (float) NULL \n  - priority_weight (float) NULL \n  - active (tinyint) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cvi_carousel\n  - id (bigint) NOT NULL [PRI]\n  - component (varchar) NOT NULL \n  - payload_type (varchar) NOT NULL \n  - payload (longtext) NOT NULL \n  - source_actor (varchar) NULL \n  - source_system (varchar) NULL \n  - signature (varchar) NULL \n  - created_at (datetime) NOT NULL \n  - processed (tinyint) NOT NULL \n  - processed_at (datetime) NULL \n\nTable: device_tokens\n  - id (int) NOT NULL [PRI]\n  - code (varchar) NULL \n  - mac_address (varchar) NULL \n  - device_id (varchar) NULL [UNI]\n  - fcm_token (text) NOT NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: dns_list\n  - id (int) NOT NULL [PRI]\n  - title (varchar) NOT NULL \n  - url (varchar) NOT NULL \n  - created_at (timestamp) NULL \n\nTable: mac_users\n  - id (int) NOT NULL [PRI]\n  - name (varchar) NULL \n  - mac_address (varchar) NOT NULL [UNI]\n  - m3u_link (text) NULL \n  - status (varchar) NULL \n  - expire_date (date) NULL \n  - created_at (timestamp) NULL \n  - device_model (varchar) NULL \n  - os_version (varchar) NULL \n  - protect_playlist (int) NULL \n  - server_name (text) NULL \n  - dns (text) NULL \n  - username (text) NULL \n  - password (text) NULL \n\nTable: notifications\n  - id (int) NOT NULL [PRI]\n  - title (varchar) NOT NULL \n  - message (text) NOT NULL \n  - created_at (timestamp) NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: settings\n  - id (int) NOT NULL [PRI]\n  - key_name (varchar) NOT NULL [UNI]\n  - key_value (text) NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL [MUL]\n  - intent (varchar) NULL [MUL]\n  - requested_at (datetime) NULL \n  - routed_to_sps (longtext) NULL \n  - results_returned (int) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n  - fallback_query (text) NULL \n  - created_at (datetime) NULL \n\nTable: vpn_servers\n  - id (int) NOT NULL [PRI]\n  - title (varchar) NOT NULL \n  - host (varchar) NOT NULL \n  - port (varchar) NULL \n  - protocol (varchar) NULL \n  - username (varchar) NULL \n  - password (varchar) NULL \n  - note (text) NULL \n  - active (tinyint) NULL \n  - created_at (timestamp) NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:08:02'),
(6, 'xpdgxfsp_lake_vector', 'Database: xpdgxfsp_lake_vector\nSchema published: 2026-01-30 23:05:13\n\n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: ai_events\n  - id (bigint) NOT NULL [PRI]\n  - event_type (varchar) NOT NULL \n  - item_type (enum) NOT NULL \n  - item_id (bigint) NOT NULL \n  - model (varchar) NULL \n  - status (enum) NOT NULL \n  - detail (text) NULL \n  - created_at (datetime) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: ai_memory_index\n  - id (int) NOT NULL [PRI]\n  - source_db (varchar) NOT NULL \n  - source_table (varchar) NOT NULL \n  - record_id (int) NOT NULL \n  - domain (varchar) NOT NULL \n  - topic (varchar) NULL \n  - unit_type (varchar) NOT NULL \n  - summary (text) NOT NULL \n  - content_ref (text) NOT NULL \n  - confidence (float) NULL \n  - priority_weight (float) NULL \n  - active (tinyint) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: artifact_topics\n  - artifact_id (bigint) NOT NULL [PRI]\n  - topic_id (bigint) NOT NULL [PRI]\n  - confidence (decimal) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cm_system_context_snapshots_neuronet_signals\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - signal_type (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - delta_metrics (longtext) NULL \n  - confidence_score (decimal) NULL \n  - created_at (datetime) NULL \n\nTable: cvi_carousel\n  - id (bigint) NOT NULL [PRI]\n  - component (varchar) NOT NULL \n  - payload_type (varchar) NOT NULL \n  - payload (longtext) NOT NULL \n  - source_actor (varchar) NULL \n  - source_system (varchar) NULL \n  - signature (varchar) NULL \n  - created_at (datetime) NOT NULL \n  - processed (tinyint) NOT NULL \n  - processed_at (datetime) NULL \n\nTable: doc_sections\n  - id (bigint) NOT NULL [PRI]\n  - doc_id (bigint) NOT NULL [MUL]\n  - section_type (enum) NOT NULL \n  - title (varchar) NULL \n  - content (longtext) NOT NULL \n  - order_index (int) NOT NULL \n  - created_at (datetime) NOT NULL \n  - pinned (tinyint) NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: embeddings\n  - id (bigint) NOT NULL [PRI]\n  - item_type (enum) NOT NULL [MUL]\n  - item_id (bigint) NOT NULL \n  - model (varchar) NOT NULL \n  - dims (int) NOT NULL \n  - embedding_json (longtext) NOT NULL \n  - created_at (datetime) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: embedding_queue\n  - id (bigint) NOT NULL [PRI]\n  - item_type (enum) NOT NULL [MUL]\n  - item_id (bigint) NOT NULL \n  - status (enum) NOT NULL [MUL]\n  - error (text) NULL \n  - created_at (datetime) NOT NULL \n  - updated_at (datetime) NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: extracted_docs\n  - id (bigint) NOT NULL [PRI]\n  - source (enum) NOT NULL [MUL]\n  - source_ref (varchar) NOT NULL \n  - doc_type (enum) NOT NULL [MUL]\n  - title (varchar) NULL \n  - content (mediumtext) NOT NULL \n  - conversation_id (varchar) NULL [MUL]\n  - message_index (int) NULL \n  - created_at (datetime) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: knowledge_links\n  - id (bigint) NOT NULL [PRI]\n  - conversation_id (varchar) NULL [MUL]\n  - artifact_id (bigint) NULL [MUL]\n  - link_type (varchar) NOT NULL [MUL]\n  - confidence (decimal) NULL \n  - rationale (varchar) NULL \n  - created_at (datetime) NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: knowledge_units\n  - id (bigint) NOT NULL [PRI]\n  - conversation_id (varchar) NOT NULL [MUL]\n  - start_message_id (bigint) NOT NULL [MUL]\n  - end_message_id (bigint) NOT NULL \n  - unit_type (enum) NOT NULL \n  - priority (float) NULL \n  - summary (text) NOT NULL \n  - confidence (decimal) NULL \n  - created_at (datetime) NULL \n  - topic (varchar) NULL \n  - intent (varchar) NULL \n  - embedding_status (enum) NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n\nTable: priority_signals\n  - item_type (enum) NOT NULL [PRI]\n  - item_id (bigint) NOT NULL [PRI]\n  - reason (varchar) NULL \n  - weight (decimal) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: raw_artifacts\n  - id (bigint) NOT NULL [PRI]\n  - source (varchar) NOT NULL [MUL]\n  - artifact_type (varchar) NOT NULL [MUL]\n  - artifact_key (varchar) NULL \n  - content (mediumtext) NOT NULL \n  - content_len (int) NOT NULL \n  - metadata (longtext) NULL \n  - created_at (datetime) NULL \n  - inferred_type (varchar) NULL \n  - inferred_topic (varchar) NULL \n  - embedding_status (enum) NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n\nTable: raw_conversations\n  - id (bigint) NOT NULL [PRI]\n  - source (varchar) NOT NULL \n  - conversation_id (varchar) NOT NULL [MUL]\n  - message_index (int) NOT NULL \n  - role (enum) NOT NULL [MUL]\n  - content (longtext) NOT NULL \n  - created_at (datetime) NULL \n  - ingested_at (datetime) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: semantic_vector_store\n  - vector_id (bigint) NOT NULL [PRI]\n  - content_type (varchar) NULL [MUL]\n  - source_id (bigint) NULL \n  - source_table (varchar) NULL [MUL]\n  - content_text (longtext) NULL \n  - embedding_vector (longtext) NULL \n  - vector_model (varchar) NULL \n  - embedding_timestamp (datetime) NULL \n  - confidence (decimal) NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL [MUL]\n  - intent (varchar) NULL [MUL]\n  - requested_at (datetime) NULL \n  - routed_to_sps (longtext) NULL \n  - results_returned (int) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n  - fallback_query (text) NULL \n  - created_at (datetime) NULL \n\nTable: topics\n  - id (bigint) NOT NULL [PRI]\n  - topic (varchar) NOT NULL [UNI]\n  - created_at (datetime) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: unit_topics\n  - unit_id (bigint) NOT NULL [PRI]\n  - topic_id (bigint) NOT NULL [PRI]\n  - confidence (decimal) NOT NULL \n  - embedding_vector (blob) NULL \n  - embedding_model (varchar) NULL \n  - vector_updated_at (datetime) NULL \n  - embedding_status (enum) NOT NULL \n\nTable: vector_embedding_metadata\n  - metadata_id (bigint) NOT NULL [PRI]\n  - vector_id (bigint) NULL [MUL]\n  - metadata_key (varchar) NULL \n  - metadata_value (text) NULL \n\nTable: v_artifact_candidates\n  - id (bigint) NOT NULL \n  - artifact_key (varchar) NULL \n  - artifact_type (varchar) NOT NULL \n  - inferred_type (varchar) NULL \n  - preview (varchar) NOT NULL \n  - metadata (longtext) NULL \n  - created_at (datetime) NULL \n\nTable: v_unit_text\n  - unit_id (bigint) NOT NULL \n  - conversation_id (varchar) NULL \n  - full_text (mediumtext) NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:08:02');
INSERT INTO `consumed_db_schemas` (`id`, `source_database`, `schema_body`, `published_at`, `consumed_at`) VALUES
(7, 'xpdgxfsp_inhibitor_govenor_matrix', 'Database: xpdgxfsp_inhibitor_govenor_matrix\nSchema published: 2026-01-30 23:05:13\n\n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cvi_carousel\n  - id (bigint) NOT NULL [PRI]\n  - component (varchar) NOT NULL \n  - payload_type (varchar) NOT NULL \n  - payload (longtext) NOT NULL \n  - source_actor (varchar) NULL \n  - source_system (varchar) NULL \n  - signature (varchar) NULL \n  - created_at (datetime) NOT NULL \n  - processed (tinyint) NOT NULL \n  - processed_at (datetime) NULL \n\nTable: igm_attestations\n  - id (bigint) NOT NULL [PRI]\n  - attested_ts (datetime) NOT NULL \n  - rule_id (varchar) NOT NULL [MUL]\n  - rule_scope (varchar) NULL \n  - rule_state (varchar) NULL \n  - rule_effect (varchar) NULL \n  - worker (varchar) NULL \n  - stage (varchar) NULL \n  - series_id (int) NULL [MUL]\n  - payload (text) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: igm_attestation_ledger\n  - attestation_id (bigint) NOT NULL [PRI]\n  - evaluation_id (bigint) NOT NULL [MUL]\n  - attested_by (enum) NOT NULL \n  - confidence (decimal) NULL \n  - evidence_hash (char) NULL \n  - attested_at (timestamp) NOT NULL \n  - truth_verified (tinyint) NULL \n  - verification_basis (enum) NOT NULL \n\nTable: igm_candidate_rules\n  - candidate_id (int) NOT NULL [PRI]\n  - inferred_rule (text) NOT NULL \n  - source_events (longtext) NOT NULL \n  - confidence_score (decimal) NULL \n  - status (enum) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: igm_governance_examples\n  - example_id (bigint) NOT NULL [PRI]\n  - component_id (varchar) NOT NULL \n  - action_attempted (varchar) NOT NULL \n  - decision (enum) NOT NULL \n  - rationale (text) NOT NULL \n  - actor (enum) NOT NULL \n  - occurred_at (timestamp) NOT NULL \n\nTable: igm_raw_governance_events\n  - event_id (bigint) NOT NULL [PRI]\n  - component_id (varchar) NOT NULL \n  - action_taken (varchar) NOT NULL \n  - rationale (text) NULL \n  - actor (enum) NOT NULL \n  - occurred_at (timestamp) NOT NULL \n\nTable: igm_rules\n  - rule_id (int) NOT NULL [PRI]\n  - rule_code (varchar) NOT NULL [UNI]\n  - rule_name (varchar) NOT NULL \n  - rule_description (text) NOT NULL \n  - togaf_phase (varchar) NULL \n  - rule_type (enum) NOT NULL \n  - severity (enum) NOT NULL \n  - applies_to (longtext) NOT NULL \n  - active (tinyint) NULL \n  - version (int) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: igm_rule_evaluations\n  - evaluation_id (bigint) NOT NULL [PRI]\n  - rule_id (int) NOT NULL [MUL]\n  - rule_version (int) NOT NULL \n  - component_id (varchar) NOT NULL \n  - action_context (varchar) NOT NULL \n  - decision (enum) NOT NULL \n  - evaluated_at (timestamp) NOT NULL \n  - correlation_id (char) NOT NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL [MUL]\n  - intent (varchar) NULL [MUL]\n  - requested_at (datetime) NULL \n  - routed_to_sps (longtext) NULL \n  - results_returned (int) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n  - fallback_query (text) NULL \n  - created_at (datetime) NULL \n\nTable: v_togaf_directive_compliance\n  - rule_code (varchar) NOT NULL \n  - rule_name (varchar) NOT NULL \n  - times_verified (bigint) NOT NULL \n  - last_verified (timestamp) NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:08:02'),
(8, 'xpdgxfsp_i_m_g_vector_context', 'Database: xpdgxfsp_i_m_g_vector_context\nSchema published: 2026-01-30 23:05:13\n\n\nTable: ai_component_learning_log\n  - learning_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL \n  - learning_phase (varchar) NULL \n  - milestone (text) NULL \n  - confidence (decimal) NULL \n  - learned_at (datetime) NULL \n\nTable: ai_component_registry\n  - component_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [UNI]\n  - component_type (varchar) NULL \n  - status (varchar) NULL \n  - home_database (varchar) NULL \n  - description (text) NULL \n  - created_at (datetime) NULL \n\nTable: ai_context_access_log\n  - access_id (bigint) NOT NULL [PRI]\n  - accessing_component (varchar) NOT NULL [MUL]\n  - accessed_component (varchar) NOT NULL [MUL]\n  - accessed_at (datetime) NULL \n  - accessed_from_db (varchar) NOT NULL \n  - query_type (varchar) NULL \n  - record_count (int) NULL \n  - flags (longtext) NULL \n\nTable: cm_context_summaries\n  - summary_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - summary_type (varchar) NULL \n  - markdown_content (longtext) NOT NULL \n  - version (int) NULL \n  - created_at (datetime) NULL \n  - last_updated (datetime) NULL \n  - authority (varchar) NULL \n  - location_original (varchar) NULL \n  - file_hash (varchar) NULL \n\nTable: cm_system_context_snapshots\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - confidence_level (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - created_at (datetime) NULL \n\nTable: cm_system_context_snapshots_genai_insights\n  - snapshot_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NOT NULL [MUL]\n  - snapshot_date (date) NOT NULL \n  - insight_type (varchar) NULL \n  - context_snapshot (longtext) NOT NULL \n  - candidate_rules (longtext) NULL \n  - confidence_level (varchar) NULL \n  - created_at (datetime) NULL \n\nTable: igm_attestation_ledger\n  - attestation_id (bigint) NOT NULL [PRI]\n  - evaluation_id (bigint) NOT NULL [MUL]\n  - attested_by (enum) NOT NULL \n  - confidence (decimal) NULL \n  - evidence_hash (char) NULL \n  - attested_at (timestamp) NOT NULL \n  - truth_verified (tinyint) NULL \n  - verification_basis (enum) NOT NULL \n\nTable: igm_candidate_rules\n  - candidate_id (int) NOT NULL [PRI]\n  - inferred_rule (text) NOT NULL \n  - source_events (longtext) NOT NULL \n  - confidence_score (decimal) NULL \n  - status (enum) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: igm_governance_examples\n  - example_id (bigint) NOT NULL [PRI]\n  - component_id (varchar) NOT NULL \n  - action_attempted (varchar) NOT NULL \n  - decision (enum) NOT NULL \n  - rationale (text) NOT NULL \n  - actor (enum) NOT NULL \n  - occurred_at (timestamp) NOT NULL \n\nTable: igm_raw_governance_events\n  - event_id (bigint) NOT NULL [PRI]\n  - component_id (varchar) NOT NULL \n  - action_taken (varchar) NOT NULL \n  - rationale (text) NULL \n  - actor (enum) NOT NULL \n  - occurred_at (timestamp) NOT NULL \n\nTable: igm_rules\n  - rule_id (int) NOT NULL [PRI]\n  - rule_code (varchar) NOT NULL [UNI]\n  - rule_name (varchar) NOT NULL \n  - rule_description (text) NOT NULL \n  - togaf_phase (varchar) NULL \n  - rule_type (enum) NOT NULL \n  - severity (enum) NOT NULL \n  - applies_to (longtext) NOT NULL \n  - active (tinyint) NULL \n  - version (int) NULL \n  - created_at (timestamp) NOT NULL \n\nTable: igm_rule_evaluations\n  - evaluation_id (bigint) NOT NULL [PRI]\n  - rule_id (int) NOT NULL [MUL]\n  - rule_version (int) NOT NULL \n  - component_id (varchar) NOT NULL \n  - action_context (varchar) NOT NULL \n  - decision (enum) NOT NULL \n  - evaluated_at (timestamp) NOT NULL \n  - correlation_id (char) NOT NULL \n\nTable: published_context_reports\n  - report_id (bigint) NOT NULL [PRI]\n  - component_name (varchar) NULL [MUL]\n  - report_type (varchar) NULL \n  - report_status (varchar) NULL [MUL]\n  - report_content (longtext) NULL \n  - report_version (int) NULL \n  - published_at (datetime) NULL [MUL]\n  - published_by (varchar) NULL \n  - created_at (datetime) NULL \n  - updated_at (datetime) NULL \n\nTable: semantic_vector_store\n  - vector_id (bigint) NOT NULL [PRI]\n  - content_type (varchar) NULL [MUL]\n  - source_id (bigint) NULL \n  - source_table (varchar) NULL [MUL]\n  - content_text (longtext) NULL \n  - embedding_vector (longtext) NULL \n  - vector_model (varchar) NULL \n  - embedding_timestamp (datetime) NULL \n  - confidence (decimal) NULL \n\nTable: sp_component_conversation_log\n  - conversation_id (bigint) NOT NULL [PRI]\n  - requesting_component (varchar) NULL [MUL]\n  - intent (varchar) NULL [MUL]\n  - requested_at (datetime) NULL \n  - routed_to_sps (longtext) NULL \n  - results_returned (int) NULL \n  - status (varchar) NULL \n\nTable: sp_intent_routing\n  - routing_id (bigint) NOT NULL [PRI]\n  - intent (varchar) NULL [UNI]\n  - intent_description (text) NULL \n  - required_sp_1 (varchar) NULL \n  - required_sp_2 (varchar) NULL \n  - required_sp_3 (varchar) NULL \n  - required_sp_4 (varchar) NULL \n  - fallback_query (text) NULL \n  - created_at (datetime) NULL \n\nTable: vector_embedding_metadata\n  - metadata_id (bigint) NOT NULL [PRI]\n  - vector_id (bigint) NULL [MUL]\n  - metadata_key (varchar) NULL \n  - metadata_value (text) NULL \n\nTable: v_togaf_directive_compliance\n  - rule_code (varchar) NOT NULL \n  - rule_name (varchar) NOT NULL \n  - times_verified (bigint) NOT NULL \n  - last_verified (timestamp) NULL \n', '2026-01-30 15:05:13', '2026-01-30 15:08:02');

-- --------------------------------------------------------

--
-- Table structure for table `cvi_carousel`
--

CREATE TABLE `cvi_carousel` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `component` varchar(128) NOT NULL,
  `payload_type` varchar(64) NOT NULL,
  `payload` longtext NOT NULL,
  `source_actor` varchar(128) DEFAULT NULL,
  `source_system` varchar(128) DEFAULT NULL,
  `signature` varchar(255) DEFAULT NULL,
  `created_at` datetime(6) NOT NULL DEFAULT current_timestamp(6),
  `processed` tinyint(1) NOT NULL DEFAULT 0,
  `processed_at` datetime(6) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `job_checkpoints`
--

CREATE TABLE `job_checkpoints` (
  `job_key` varchar(64) NOT NULL,
  `environment` enum('dev','stage','prod') NOT NULL,
  `checkpoint_key` varchar(64) NOT NULL,
  `checkpoint_val` varchar(255) DEFAULT NULL,
  `updated_at` datetime NOT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `job_definitions`
--

CREATE TABLE `job_definitions` (
  `job_key` varchar(64) NOT NULL,
  `description` varchar(255) DEFAULT NULL,
  `job_class` enum('SAFE','RISKY') NOT NULL,
  `enabled` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `job_events`
--

CREATE TABLE `job_events` (
  `event_id` bigint(20) NOT NULL,
  `run_id` bigint(20) NOT NULL,
  `job_key` varchar(64) NOT NULL,
  `environment` enum('dev','stage','prod') NOT NULL,
  `event_type` varchar(32) NOT NULL,
  `event_detail` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `job_failures`
--

CREATE TABLE `job_failures` (
  `failure_id` bigint(20) NOT NULL,
  `run_id` bigint(20) NOT NULL,
  `job_key` varchar(64) NOT NULL,
  `environment` enum('dev','stage','prod') NOT NULL,
  `phase` varchar(64) DEFAULT NULL,
  `error_type` varchar(64) NOT NULL,
  `error_summary` varchar(255) NOT NULL,
  `occurred_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `job_locks`
--

CREATE TABLE `job_locks` (
  `job_key` varchar(64) NOT NULL,
  `environment` enum('dev','stage','prod') NOT NULL,
  `locked_at` datetime NOT NULL,
  `expires_at` datetime NOT NULL,
  `host` varchar(128) DEFAULT NULL,
  `pid` int(11) DEFAULT NULL,
  `run_id` bigint(20) DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `job_runs`
--

CREATE TABLE `job_runs` (
  `run_id` bigint(20) NOT NULL,
  `job_key` varchar(64) NOT NULL,
  `environment` enum('dev','stage','prod') NOT NULL,
  `started_at` datetime NOT NULL,
  `finished_at` datetime DEFAULT NULL,
  `status` enum('running','success','failed','aborted','skipped') NOT NULL,
  `exit_code` int(11) DEFAULT NULL,
  `summary` varchar(255) DEFAULT NULL,
  `host` varchar(128) DEFAULT NULL,
  `pid` int(11) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `mc_perspective_records`
--

CREATE TABLE `mc_perspective_records` (
  `perspective_id` char(36) NOT NULL,
  `focus` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL CHECK (json_valid(`focus`)),
  `views` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL CHECK (json_valid(`views`)),
  `time_from` datetime NOT NULL,
  `time_to` datetime NOT NULL,
  `constraints` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL CHECK (json_valid(`constraints`)),
  `authorized_by` varchar(64) NOT NULL,
  `created_at` datetime NOT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

--
-- Dumping data for table `mc_perspective_records`
--

INSERT INTO `mc_perspective_records` (`perspective_id`, `focus`, `views`, `time_from`, `time_to`, `constraints`, `authorized_by`, `created_at`) VALUES
('47a3baea-fe27-11f0-a404-fa163e2e3c7c', '[\"ops\", \"system_health\"]', '[\"xpdgxfsp_ops.vw_focus_ops\", \"xpdgxfsp_ops.vw_focus_system_health\"]', '2026-01-28 00:00:00', '2026-01-30 23:59:59', '{\"mode\": \"explain_only\", \"actions_allowed\": []}', 'H-I-L', '2026-01-30 14:01:48');

-- --------------------------------------------------------

--
-- Table structure for table `ops_events`
--

CREATE TABLE `ops_events` (
  `id` bigint(20) NOT NULL,
  `event_ts` datetime(6) NOT NULL,
  `worker` varchar(64) NOT NULL,
  `stage` varchar(64) NOT NULL,
  `series_id` int(11) DEFAULT NULL,
  `event_type` varchar(64) NOT NULL,
  `payload` text NOT NULL,
  `run_id` varchar(64) DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp()
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

--
-- Dumping data for table `published_context_reports`
--

INSERT INTO `published_context_reports` (`report_id`, `component_name`, `report_type`, `report_status`, `report_content`, `report_version`, `published_at`, `published_by`, `created_at`, `updated_at`) VALUES
(1, 'Grinder / Ingest Pipeline', 'context_summary', 'published', '# CONTEXT REPORT: Grinder / Ingest Pipeline\n\n**Status**: Published\n**Date**: 2026-01-29\n**Version**: 1\n**Authority**: human_operator\n\n## Context Summary\nComponent: Grinder / Ingest Pipeline\nSnapshot Date: 2026-01-29\nConfidence Level: High on state, Low on downstream\n\n## Latest Context\n(Content follows from cm_system_context_snapshots)\n\n## Access Patterns\n(Tracked in ai_context_access_log)\n\n---\nGenerated: 2026-01-29 16:00:02 | Published By: human_operator', 1, '2026-01-29 16:00:02', 'human_operator', '2026-01-29 16:00:02', '2026-01-29 16:00:02');

-- --------------------------------------------------------

--
-- Table structure for table `sp_component_conversation_log`
--

CREATE TABLE `sp_component_conversation_log` (
  `conversation_id` bigint(20) NOT NULL,
  `requesting_component` varchar(255) DEFAULT NULL,
  `intent` varchar(255) DEFAULT NULL,
  `requested_at` datetime DEFAULT current_timestamp(),
  `status` varchar(50) DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `sp_intent_routing`
--

CREATE TABLE `sp_intent_routing` (
  `routing_id` bigint(20) NOT NULL,
  `intent` varchar(255) DEFAULT NULL,
  `intent_description` text DEFAULT NULL,
  `required_sp_1` varchar(255) DEFAULT NULL,
  `required_sp_2` varchar(255) DEFAULT NULL,
  `required_sp_3` varchar(255) DEFAULT NULL,
  `required_sp_4` varchar(255) DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

--
-- Dumping data for table `sp_intent_routing`
--

INSERT INTO `sp_intent_routing` (`routing_id`, `intent`, `intent_description`, `required_sp_1`, `required_sp_2`, `required_sp_3`, `required_sp_4`) VALUES
(1, 'check governance', 'Get governance rules and candidates', 'sp_get_global_governance_rules', 'sp_get_global_candidate_rules', 'sp_get_published_context_reports', NULL),
(2, 'system state', 'Full system awareness', 'sp_get_all_component_contexts', 'sp_get_global_job_status', NULL, NULL),
(3, 'coordination gaps', 'Who is reading what', 'sp_get_global_access_log', 'sp_get_all_component_contexts', NULL, NULL);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_focus_ops`
-- (See below for the actual view)
--
CREATE TABLE `vw_focus_ops` (
`focus_name` varchar(3)
,`source_component` varchar(12)
,`record_time` datetime /* mariadb-5.3 */
,`total_runs` bigint(21)
,`active_runs` decimal(22,0)
,`failed_runs` decimal(22,0)
,`capacity_score` decimal(27,4)
,`latest_run_time` datetime
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_focus_system`
-- (See below for the actual view)
--
CREATE TABLE `vw_focus_system` (
`focus_name` varchar(6)
,`source_component` varchar(12)
,`record_time` datetime
,`job_key` varchar(64)
,`status` enum('running','success','failed','aborted','skipped')
,`started_at` datetime
,`finished_at` datetime
,`duration_sec` bigint(21)
);

--
-- Indexes for dumped tables
--

--
-- Indexes for table `active_memory_registry_meta`
--
ALTER TABLE `active_memory_registry_meta`
  ADD PRIMARY KEY (`meta_key`);

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
-- Indexes for table `ai_telemetry`
--
ALTER TABLE `ai_telemetry`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_created_at` (`created_at`),
  ADD KEY `idx_route` (`route`),
  ADD KEY `idx_provider` (`provider`),
  ADD KEY `idx_task` (`task`),
  ADD KEY `idx_job_run_id` (`job_run_id`);

--
-- Indexes for table `cm_system_context_snapshots`
--
ALTER TABLE `cm_system_context_snapshots`
  ADD PRIMARY KEY (`snapshot_id`),
  ADD UNIQUE KEY `uk_comp_date` (`component_name`,`snapshot_date`);

--
-- Indexes for table `cm_system_context_snapshots_ml_forecasts`
--
ALTER TABLE `cm_system_context_snapshots_ml_forecasts`
  ADD PRIMARY KEY (`snapshot_id`),
  ADD UNIQUE KEY `uk_ml_context` (`component_name`,`snapshot_date`,`forecast_type`);

--
-- Indexes for table `consumed_db_introductions`
--
ALTER TABLE `consumed_db_introductions`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_source` (`source_database`);

--
-- Indexes for table `consumed_db_schemas`
--
ALTER TABLE `consumed_db_schemas`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_source` (`source_database`);

--
-- Indexes for table `cvi_carousel`
--
ALTER TABLE `cvi_carousel`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `job_checkpoints`
--
ALTER TABLE `job_checkpoints`
  ADD PRIMARY KEY (`job_key`,`environment`,`checkpoint_key`);

--
-- Indexes for table `job_definitions`
--
ALTER TABLE `job_definitions`
  ADD PRIMARY KEY (`job_key`);

--
-- Indexes for table `job_events`
--
ALTER TABLE `job_events`
  ADD PRIMARY KEY (`event_id`),
  ADD KEY `idx_run_event` (`run_id`,`created_at`);

--
-- Indexes for table `job_failures`
--
ALTER TABLE `job_failures`
  ADD PRIMARY KEY (`failure_id`),
  ADD KEY `idx_job_fail` (`job_key`,`occurred_at`);

--
-- Indexes for table `job_locks`
--
ALTER TABLE `job_locks`
  ADD PRIMARY KEY (`job_key`,`environment`),
  ADD KEY `idx_expires` (`expires_at`);

--
-- Indexes for table `job_runs`
--
ALTER TABLE `job_runs`
  ADD PRIMARY KEY (`run_id`),
  ADD KEY `idx_job_time` (`job_key`,`environment`,`started_at`);

--
-- Indexes for table `mc_perspective_records`
--
ALTER TABLE `mc_perspective_records`
  ADD PRIMARY KEY (`perspective_id`);

--
-- Indexes for table `ops_events`
--
ALTER TABLE `ops_events`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_series` (`series_id`),
  ADD KEY `idx_event_ts` (`event_ts`),
  ADD KEY `idx_worker_stage` (`worker`,`stage`);

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
  ADD PRIMARY KEY (`conversation_id`);

--
-- Indexes for table `sp_intent_routing`
--
ALTER TABLE `sp_intent_routing`
  ADD PRIMARY KEY (`routing_id`),
  ADD UNIQUE KEY `intent` (`intent`);

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
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=31;

--
-- AUTO_INCREMENT for table `ai_telemetry`
--
ALTER TABLE `ai_telemetry`
  MODIFY `id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `cm_system_context_snapshots`
--
ALTER TABLE `cm_system_context_snapshots`
  MODIFY `snapshot_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=8;

--
-- AUTO_INCREMENT for table `cm_system_context_snapshots_ml_forecasts`
--
ALTER TABLE `cm_system_context_snapshots_ml_forecasts`
  MODIFY `snapshot_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `consumed_db_introductions`
--
ALTER TABLE `consumed_db_introductions`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=9;

--
-- AUTO_INCREMENT for table `consumed_db_schemas`
--
ALTER TABLE `consumed_db_schemas`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=9;

--
-- AUTO_INCREMENT for table `cvi_carousel`
--
ALTER TABLE `cvi_carousel`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `job_events`
--
ALTER TABLE `job_events`
  MODIFY `event_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `job_failures`
--
ALTER TABLE `job_failures`
  MODIFY `failure_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `job_runs`
--
ALTER TABLE `job_runs`
  MODIFY `run_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `ops_events`
--
ALTER TABLE `ops_events`
  MODIFY `id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `published_context_reports`
--
ALTER TABLE `published_context_reports`
  MODIFY `report_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `sp_component_conversation_log`
--
ALTER TABLE `sp_component_conversation_log`
  MODIFY `conversation_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `sp_intent_routing`
--
ALTER TABLE `sp_intent_routing`
  MODIFY `routing_id` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=4;

-- --------------------------------------------------------

--
-- Structure for view `vw_focus_ops`
--
DROP TABLE IF EXISTS `vw_focus_ops`;

CREATE ALGORITHM=UNDEFINED DEFINER=`xpdgxfsp`@`localhost` SQL SECURITY DEFINER VIEW `vw_focus_ops`  AS SELECT 'ops' AS `focus_name`, 'xpdgxfsp_ops' AS `source_component`, current_timestamp() AS `record_time`, count(0) AS `total_runs`, sum(case when `job_runs`.`status` = 'running' then 1 else 0 end) AS `active_runs`, sum(case when `job_runs`.`status` = 'failed' then 1 else 0 end) AS `failed_runs`, 1 - sum(case when `job_runs`.`status` = 'failed' then 1 else 0 end) / nullif(count(0),0) AS `capacity_score`, max(`job_runs`.`created_at`) AS `latest_run_time` FROM `job_runs` WHERE `job_runs`.`created_at` >= current_timestamp() - interval 24 hour ;

-- --------------------------------------------------------

--
-- Structure for view `vw_focus_system`
--
DROP TABLE IF EXISTS `vw_focus_system`;

CREATE ALGORITHM=UNDEFINED DEFINER=`xpdgxfsp`@`localhost` SQL SECURITY DEFINER VIEW `vw_focus_system`  AS SELECT 'system' AS `focus_name`, 'xpdgxfsp_ops' AS `source_component`, `job_runs`.`created_at` AS `record_time`, `job_runs`.`job_key` AS `job_key`, `job_runs`.`status` AS `status`, `job_runs`.`started_at` AS `started_at`, `job_runs`.`finished_at` AS `finished_at`, timestampdiff(SECOND,`job_runs`.`started_at`,coalesce(`job_runs`.`finished_at`,current_timestamp())) AS `duration_sec` FROM `job_runs` ORDER BY `job_runs`.`created_at` DESC LIMIT 0, 1000 ;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
