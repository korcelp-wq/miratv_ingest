-- phpMyAdmin SQL Dump
-- version 5.2.2
-- https://www.phpmyadmin.net/
--
-- Host: localhost:3306
-- Generation Time: Mar 16, 2026 at 11:53 AM
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
  MODIFY `component_id` bigint(20) NOT NULL AUTO_INCREMENT;

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
  MODIFY `snapshot_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

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
  MODIFY `mode_id` bigint(20) NOT NULL AUTO_INCREMENT;

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
  MODIFY `policy_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `gov_policy_rules`
--
ALTER TABLE `gov_policy_rules`
  MODIFY `rule_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `ingest_files`
--
ALTER TABLE `ingest_files`
  MODIFY `file_id` bigint(20) NOT NULL AUTO_INCREMENT;

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
  MODIFY `exchange_id` bigint(20) NOT NULL AUTO_INCREMENT;

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
  MODIFY `routing_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `telemetry_component_runs`
--
ALTER TABLE `telemetry_component_runs`
  MODIFY `id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `telemetry_upload_events`
--
ALTER TABLE `telemetry_upload_events`
  MODIFY `id` bigint(20) NOT NULL AUTO_INCREMENT;

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
