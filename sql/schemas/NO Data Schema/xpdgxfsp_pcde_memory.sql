-- phpMyAdmin SQL Dump
-- version 5.2.2
-- https://www.phpmyadmin.net/
--
-- Host: localhost:3306
-- Generation Time: Mar 16, 2026 at 12:00 PM
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
-- Database: `xpdgxfsp_pcde_memory`
--

-- --------------------------------------------------------

--
-- Table structure for table `pcde_ai_learning_progress`
--

CREATE TABLE `pcde_ai_learning_progress` (
  `id` bigint(20) NOT NULL,
  `learning_cycle` int(11) NOT NULL,
  `success_rate` decimal(3,2) DEFAULT NULL,
  `procedures_used` int(11) DEFAULT 0,
  `errors_encountered` int(11) DEFAULT 0,
  `confidence_growth` decimal(3,2) DEFAULT NULL,
  `cycle_start` timestamp NOT NULL DEFAULT current_timestamp(),
  `cycle_end` timestamp NULL DEFAULT NULL,
  `notes` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_ai_memory`
--

CREATE TABLE `pcde_ai_memory` (
  `memory_id` bigint(20) NOT NULL,
  `agent_name` varchar(64) NOT NULL,
  `memory_type` enum('context','learning','decision','reflection') NOT NULL,
  `key_data` text NOT NULL,
  `embedding_vector` blob DEFAULT NULL,
  `confidence` decimal(3,2) DEFAULT NULL,
  `source_procedure_id` bigint(20) DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `last_accessed` timestamp NULL DEFAULT NULL,
  `access_count` int(11) DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_cognitive_instructions`
--

CREATE TABLE `pcde_cognitive_instructions` (
  `instruction_id` bigint(20) NOT NULL,
  `instruction_key` varchar(128) NOT NULL,
  `instruction_scope` enum('system','procedure','mentor','ai_agent','reconciliation') NOT NULL,
  `instruction_text` mediumtext NOT NULL,
  `authority_level` enum('hard','default','advisory') NOT NULL,
  `active` tinyint(1) DEFAULT 1,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `superseded_by` bigint(20) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_declarative_memory`
--

CREATE TABLE `pcde_declarative_memory` (
  `fact_id` bigint(20) NOT NULL,
  `fact_type` enum('semantic','episodic') NOT NULL,
  `domain` varchar(64) NOT NULL,
  `subject_type` varchar(64) NOT NULL,
  `subject_id` varchar(128) DEFAULT NULL,
  `provider_id` varchar(128) DEFAULT NULL,
  `canonical_id` bigint(20) DEFAULT NULL,
  `mapping_confidence` decimal(3,2) DEFAULT NULL,
  `raw_payload_ref` varchar(512) DEFAULT NULL,
  `verified_at` timestamp NULL DEFAULT NULL,
  `predicate` varchar(255) NOT NULL,
  `object_value` text NOT NULL,
  `confidence` decimal(3,2) DEFAULT 0.95,
  `source_system` varchar(64) DEFAULT NULL,
  `source_record_id` bigint(20) DEFAULT NULL,
  `observed_at` timestamp NULL DEFAULT NULL,
  `expires_at` timestamp NULL DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_declarative_procedure_links`
--

CREATE TABLE `pcde_declarative_procedure_links` (
  `link_id` bigint(20) NOT NULL,
  `fact_id` bigint(20) NOT NULL,
  `procedure_id` bigint(20) NOT NULL,
  `relationship` varchar(64) DEFAULT 'handles',
  `confidence` decimal(3,2) DEFAULT 1.00
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_id_mapping`
--

CREATE TABLE `pcde_id_mapping` (
  `mapping_id` bigint(20) NOT NULL,
  `provider_name` varchar(64) NOT NULL,
  `provider_id` varchar(128) NOT NULL,
  `content_type` enum('series','movie','channel','episode','season') NOT NULL,
  `canonical_id` bigint(20) NOT NULL,
  `mapping_confidence` decimal(3,2) DEFAULT 0.95,
  `verified` tinyint(1) DEFAULT 0,
  `verified_at` timestamp NULL DEFAULT NULL,
  `first_seen` timestamp NOT NULL DEFAULT current_timestamp(),
  `last_seen` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `raw_payload_ref` varchar(512) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_ingest_stage_docs`
--

CREATE TABLE `pcde_ingest_stage_docs` (
  `stage_id` bigint(20) NOT NULL,
  `source_name` varchar(255) NOT NULL,
  `source_path` varchar(512) DEFAULT NULL,
  `raw_text` longtext NOT NULL,
  `detected_type` enum('procedure','instruction','runbook','design','unknown') DEFAULT 'unknown',
  `detected_domain` varchar(128) DEFAULT NULL,
  `proposed_name` varchar(255) DEFAULT NULL,
  `status` enum('new','triaged','promoted','rejected') DEFAULT 'new',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_instruction_registry`
--

CREATE TABLE `pcde_instruction_registry` (
  `id` bigint(20) NOT NULL,
  `name` varchar(255) NOT NULL,
  `unit_type` varchar(64) NOT NULL DEFAULT 'instruction',
  `domain` varchar(128) NOT NULL,
  `topic` varchar(128) NOT NULL,
  `instruction` longtext NOT NULL,
  `source_system` varchar(255) DEFAULT NULL,
  `source_path` varchar(512) DEFAULT NULL,
  `provenance` text DEFAULT NULL,
  `status` varchar(64) NOT NULL DEFAULT 'active',
  `active` tinyint(1) NOT NULL DEFAULT 1,
  `error_count` int(11) NOT NULL DEFAULT 0,
  `vector_count` int(11) NOT NULL DEFAULT 0,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NULL DEFAULT NULL ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_mentor_escalation_queue`
--

CREATE TABLE `pcde_mentor_escalation_queue` (
  `escalation_id` bigint(20) NOT NULL,
  `procedure_id` bigint(20) NOT NULL,
  `reason` varchar(255) NOT NULL,
  `context_snapshot` mediumtext NOT NULL,
  `confidence_score` decimal(4,2) DEFAULT NULL,
  `blast_radius` varchar(32) DEFAULT NULL,
  `mirror_status` varchar(32) DEFAULT NULL,
  `status` enum('pending','in_review','resolved','rejected') DEFAULT 'pending',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `resolved_at` timestamp NULL DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_procedure_execution`
--

CREATE TABLE `pcde_procedure_execution` (
  `procedure_id` bigint(20) NOT NULL,
  `invocation_type` enum('manual','scheduled','event','chained','ai_requested') NOT NULL,
  `invoked_by` varchar(128) DEFAULT NULL,
  `expected_frequency` enum('adhoc','hourly','daily','burst','continuous') DEFAULT NULL,
  `required_inputs` mediumtext DEFAULT NULL,
  `preconditions` mediumtext DEFAULT NULL,
  `required_state` mediumtext DEFAULT NULL,
  `primary_outputs` mediumtext DEFAULT NULL,
  `side_effects` mediumtext DEFAULT NULL,
  `invalidates` mediumtext DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_procedure_failure`
--

CREATE TABLE `pcde_procedure_failure` (
  `procedure_id` bigint(20) NOT NULL,
  `failure_modes` mediumtext DEFAULT NULL,
  `retry_policy` enum('never','safe','conditional') NOT NULL,
  `blast_radius` enum('local','domain','system') NOT NULL,
  `last_error` mediumtext DEFAULT NULL,
  `last_error_at` timestamp NULL DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_procedure_igm_ref`
--

CREATE TABLE `pcde_procedure_igm_ref` (
  `procedure_id` bigint(20) NOT NULL,
  `igm_policy_key` varchar(255) DEFAULT NULL,
  `igm_gate_key` varchar(255) DEFAULT NULL,
  `igm_profile_ref` varchar(512) DEFAULT NULL,
  `notes` mediumtext DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NULL DEFAULT NULL ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_procedure_registry`
--

CREATE TABLE `pcde_procedure_registry` (
  `procedure_id` bigint(20) NOT NULL,
  `procedure_name` varchar(255) NOT NULL,
  `procedure_type` enum('stored_proc','view','pipeline','script','batch','api') NOT NULL,
  `domain` varchar(64) NOT NULL,
  `source_system` varchar(128) NOT NULL,
  `source_path` varchar(512) NOT NULL,
  `description` mediumtext NOT NULL,
  `why_it_exists` mediumtext NOT NULL,
  `active` tinyint(1) DEFAULT 1,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `id` varchar(128) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_procedure_relations`
--

CREATE TABLE `pcde_procedure_relations` (
  `relation_id` bigint(20) NOT NULL,
  `procedure_id` bigint(20) NOT NULL,
  `relation_type` enum('file','script','batch','config','table','view','endpoint','directory','external_service') NOT NULL,
  `relation_target` varchar(512) NOT NULL,
  `notes` mediumtext DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_procedure_state`
--

CREATE TABLE `pcde_procedure_state` (
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_registry_meta`
--

CREATE TABLE `pcde_registry_meta` (
  `meta_key` varchar(64) NOT NULL,
  `meta_value` mediumtext NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_working_memory`
--

CREATE TABLE `pcde_working_memory` (
  `session_id` varchar(64) NOT NULL,
  `slot_key` varchar(128) NOT NULL,
  `slot_value` text NOT NULL,
  `value_type` enum('string','number','json','reference') DEFAULT 'string',
  `confidence` decimal(3,2) DEFAULT 0.95,
  `source_procedure_id` bigint(20) DEFAULT NULL,
  `source_query` text DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `last_accessed` timestamp NULL DEFAULT NULL,
  `expires_at` timestamp NULL DEFAULT NULL,
  `access_count` int(11) DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_working_sessions`
--

CREATE TABLE `pcde_working_sessions` (
  `session_id` varchar(64) NOT NULL,
  `session_type` enum('ai_task','human_operation','pipeline_run') NOT NULL,
  `status` enum('active','completed','failed','expired') DEFAULT 'active',
  `started_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `last_activity` timestamp NOT NULL DEFAULT current_timestamp(),
  `expires_at` timestamp NULL DEFAULT NULL,
  `parent_session` varchar(64) DEFAULT NULL,
  `procedure_id` bigint(20) DEFAULT NULL,
  `notes` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Indexes for dumped tables
--

--
-- Indexes for table `pcde_ai_learning_progress`
--
ALTER TABLE `pcde_ai_learning_progress`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_cycle` (`learning_cycle`);

--
-- Indexes for table `pcde_ai_memory`
--
ALTER TABLE `pcde_ai_memory`
  ADD PRIMARY KEY (`memory_id`),
  ADD KEY `source_procedure_id` (`source_procedure_id`);

--
-- Indexes for table `pcde_cognitive_instructions`
--
ALTER TABLE `pcde_cognitive_instructions`
  ADD PRIMARY KEY (`instruction_id`),
  ADD UNIQUE KEY `instruction_key` (`instruction_key`),
  ADD KEY `idx_scope` (`instruction_scope`),
  ADD KEY `idx_active` (`active`);

--
-- Indexes for table `pcde_declarative_memory`
--
ALTER TABLE `pcde_declarative_memory`
  ADD PRIMARY KEY (`fact_id`),
  ADD KEY `idx_domain` (`domain`),
  ADD KEY `idx_subject` (`subject_type`,`subject_id`),
  ADD KEY `idx_predicate` (`predicate`),
  ADD KEY `idx_observed` (`observed_at`),
  ADD KEY `idx_provider` (`provider_id`),
  ADD KEY `idx_canonical` (`canonical_id`),
  ADD KEY `idx_mapping` (`provider_id`,`canonical_id`);
ALTER TABLE `pcde_declarative_memory` ADD FULLTEXT KEY `idx_search` (`object_value`);

--
-- Indexes for table `pcde_declarative_procedure_links`
--
ALTER TABLE `pcde_declarative_procedure_links`
  ADD PRIMARY KEY (`link_id`),
  ADD KEY `idx_fact` (`fact_id`),
  ADD KEY `idx_procedure` (`procedure_id`);

--
-- Indexes for table `pcde_id_mapping`
--
ALTER TABLE `pcde_id_mapping`
  ADD PRIMARY KEY (`mapping_id`),
  ADD UNIQUE KEY `unique_mapping` (`provider_name`,`provider_id`,`content_type`),
  ADD KEY `idx_canonical` (`canonical_id`),
  ADD KEY `idx_provider` (`provider_name`,`provider_id`);

--
-- Indexes for table `pcde_ingest_stage_docs`
--
ALTER TABLE `pcde_ingest_stage_docs`
  ADD PRIMARY KEY (`stage_id`),
  ADD KEY `idx_status` (`status`),
  ADD KEY `idx_type` (`detected_type`);

--
-- Indexes for table `pcde_instruction_registry`
--
ALTER TABLE `pcde_instruction_registry`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uniq_name_source` (`name`,`source_system`,`source_path`) USING HASH;

--
-- Indexes for table `pcde_mentor_escalation_queue`
--
ALTER TABLE `pcde_mentor_escalation_queue`
  ADD PRIMARY KEY (`escalation_id`),
  ADD KEY `idx_status` (`status`),
  ADD KEY `idx_proc` (`procedure_id`);

--
-- Indexes for table `pcde_procedure_execution`
--
ALTER TABLE `pcde_procedure_execution`
  ADD PRIMARY KEY (`procedure_id`);

--
-- Indexes for table `pcde_procedure_failure`
--
ALTER TABLE `pcde_procedure_failure`
  ADD PRIMARY KEY (`procedure_id`);

--
-- Indexes for table `pcde_procedure_igm_ref`
--
ALTER TABLE `pcde_procedure_igm_ref`
  ADD PRIMARY KEY (`procedure_id`),
  ADD KEY `idx_igm_policy_key` (`igm_policy_key`),
  ADD KEY `idx_igm_gate_key` (`igm_gate_key`);

--
-- Indexes for table `pcde_procedure_registry`
--
ALTER TABLE `pcde_procedure_registry`
  ADD PRIMARY KEY (`procedure_id`),
  ADD UNIQUE KEY `unique_procedure_path` (`procedure_name`(100),`source_path`(200)),
  ADD KEY `idx_domain_active` (`domain`,`active`),
  ADD KEY `idx_proc_name` (`procedure_name`);

--
-- Indexes for table `pcde_procedure_relations`
--
ALTER TABLE `pcde_procedure_relations`
  ADD PRIMARY KEY (`relation_id`),
  ADD KEY `idx_proc` (`procedure_id`),
  ADD KEY `idx_type` (`relation_type`);

--
-- Indexes for table `pcde_procedure_state`
--
ALTER TABLE `pcde_procedure_state`
  ADD PRIMARY KEY (`procedure_id`),
  ADD KEY `supersedes_id` (`supersedes_id`);

--
-- Indexes for table `pcde_registry_meta`
--
ALTER TABLE `pcde_registry_meta`
  ADD PRIMARY KEY (`meta_key`);

--
-- Indexes for table `pcde_working_memory`
--
ALTER TABLE `pcde_working_memory`
  ADD PRIMARY KEY (`session_id`,`slot_key`),
  ADD KEY `idx_expires` (`expires_at`),
  ADD KEY `idx_source` (`source_procedure_id`),
  ADD KEY `idx_accessed` (`last_accessed`);

--
-- Indexes for table `pcde_working_sessions`
--
ALTER TABLE `pcde_working_sessions`
  ADD PRIMARY KEY (`session_id`),
  ADD KEY `idx_status` (`status`),
  ADD KEY `idx_expires` (`expires_at`),
  ADD KEY `idx_parent` (`parent_session`),
  ADD KEY `idx_procedure` (`procedure_id`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `pcde_ai_learning_progress`
--
ALTER TABLE `pcde_ai_learning_progress`
  MODIFY `id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `pcde_ai_memory`
--
ALTER TABLE `pcde_ai_memory`
  MODIFY `memory_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `pcde_cognitive_instructions`
--
ALTER TABLE `pcde_cognitive_instructions`
  MODIFY `instruction_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `pcde_declarative_memory`
--
ALTER TABLE `pcde_declarative_memory`
  MODIFY `fact_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `pcde_declarative_procedure_links`
--
ALTER TABLE `pcde_declarative_procedure_links`
  MODIFY `link_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `pcde_id_mapping`
--
ALTER TABLE `pcde_id_mapping`
  MODIFY `mapping_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `pcde_ingest_stage_docs`
--
ALTER TABLE `pcde_ingest_stage_docs`
  MODIFY `stage_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `pcde_instruction_registry`
--
ALTER TABLE `pcde_instruction_registry`
  MODIFY `id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `pcde_mentor_escalation_queue`
--
ALTER TABLE `pcde_mentor_escalation_queue`
  MODIFY `escalation_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `pcde_procedure_registry`
--
ALTER TABLE `pcde_procedure_registry`
  MODIFY `procedure_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `pcde_procedure_relations`
--
ALTER TABLE `pcde_procedure_relations`
  MODIFY `relation_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- Constraints for dumped tables
--

--
-- Constraints for table `pcde_ai_memory`
--
ALTER TABLE `pcde_ai_memory`
  ADD CONSTRAINT `pcde_ai_memory_ibfk_1` FOREIGN KEY (`source_procedure_id`) REFERENCES `pcde_procedure_registry` (`procedure_id`);

--
-- Constraints for table `pcde_procedure_execution`
--
ALTER TABLE `pcde_procedure_execution`
  ADD CONSTRAINT `fk_exec_proc` FOREIGN KEY (`procedure_id`) REFERENCES `pcde_procedure_registry` (`procedure_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `pcde_procedure_failure`
--
ALTER TABLE `pcde_procedure_failure`
  ADD CONSTRAINT `fk_fail_proc` FOREIGN KEY (`procedure_id`) REFERENCES `pcde_procedure_registry` (`procedure_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `pcde_procedure_igm_ref`
--
ALTER TABLE `pcde_procedure_igm_ref`
  ADD CONSTRAINT `fk_igmref_proc` FOREIGN KEY (`procedure_id`) REFERENCES `pcde_procedure_registry` (`procedure_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `pcde_procedure_relations`
--
ALTER TABLE `pcde_procedure_relations`
  ADD CONSTRAINT `fk_rel_proc` FOREIGN KEY (`procedure_id`) REFERENCES `pcde_procedure_registry` (`procedure_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `pcde_procedure_state`
--
ALTER TABLE `pcde_procedure_state`
  ADD CONSTRAINT `fk_state_proc` FOREIGN KEY (`procedure_id`) REFERENCES `pcde_procedure_registry` (`procedure_id`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Constraints for table `pcde_working_memory`
--
ALTER TABLE `pcde_working_memory`
  ADD CONSTRAINT `pcde_working_memory_ibfk_1` FOREIGN KEY (`source_procedure_id`) REFERENCES `pcde_procedure_registry` (`procedure_id`) ON DELETE SET NULL;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
