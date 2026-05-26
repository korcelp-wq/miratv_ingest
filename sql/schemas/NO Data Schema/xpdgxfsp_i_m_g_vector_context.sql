-- phpMyAdmin SQL Dump
-- version 5.2.2
-- https://www.phpmyadmin.net/
--
-- Host: localhost:3306
-- Generation Time: Mar 16, 2026 at 11:55 AM
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
-- Database: `xpdgxfsp_i_m_g_vector_context`
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
-- Table structure for table `cm_context_summaries`
--

CREATE TABLE `cm_context_summaries` (
  `summary_id` bigint(20) UNSIGNED NOT NULL,
  `component_name` varchar(255) NOT NULL,
  `summary_type` varchar(100) DEFAULT 'system_context',
  `markdown_content` longtext NOT NULL,
  `version` int(11) DEFAULT 1,
  `created_at` datetime DEFAULT current_timestamp(),
  `last_updated` datetime DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `authority` varchar(100) DEFAULT 'human_operator',
  `location_original` varchar(255) DEFAULT NULL,
  `file_hash` varchar(64) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

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
-- Table structure for table `cm_system_context_snapshots_genai_insights`
--

CREATE TABLE `cm_system_context_snapshots_genai_insights` (
  `snapshot_id` bigint(20) UNSIGNED NOT NULL,
  `component_name` varchar(255) NOT NULL,
  `snapshot_date` date NOT NULL,
  `insight_type` varchar(100) DEFAULT NULL,
  `context_snapshot` longtext NOT NULL,
  `candidate_rules` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`candidate_rules`)),
  `confidence_level` varchar(50) DEFAULT NULL,
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

-- --------------------------------------------------------

--
-- Table structure for table `igm_attestation_ledger`
--

CREATE TABLE `igm_attestation_ledger` (
  `attestation_id` bigint(20) NOT NULL,
  `evaluation_id` bigint(20) NOT NULL,
  `attested_by` enum('system','human','ai') NOT NULL,
  `confidence` decimal(3,2) DEFAULT 1.00,
  `evidence_hash` char(64) DEFAULT NULL,
  `attested_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `truth_verified` tinyint(1) DEFAULT 0,
  `verification_basis` enum('deterministic_rule_match','manual_confirmation','ai_supported_human_confirmed') NOT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `igm_candidate_rules`
--

CREATE TABLE `igm_candidate_rules` (
  `candidate_id` int(11) NOT NULL,
  `inferred_rule` text NOT NULL,
  `source_events` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL CHECK (json_valid(`source_events`)),
  `confidence_score` decimal(3,2) DEFAULT NULL,
  `status` enum('draft','accepted','rejected') DEFAULT 'draft',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `igm_governance_examples`
--

CREATE TABLE `igm_governance_examples` (
  `example_id` bigint(20) NOT NULL,
  `component_id` varchar(128) NOT NULL,
  `action_attempted` varchar(255) NOT NULL,
  `decision` enum('allowed','blocked','modified') NOT NULL,
  `rationale` text NOT NULL,
  `actor` enum('human','ai','system') NOT NULL,
  `occurred_at` timestamp NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `igm_raw_governance_events`
--

CREATE TABLE `igm_raw_governance_events` (
  `event_id` bigint(20) NOT NULL,
  `component_id` varchar(128) NOT NULL,
  `action_taken` varchar(255) NOT NULL,
  `rationale` text DEFAULT NULL,
  `actor` enum('human','ai','system') NOT NULL,
  `occurred_at` timestamp NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `igm_rules`
--

CREATE TABLE `igm_rules` (
  `rule_id` int(11) NOT NULL,
  `rule_code` varchar(64) NOT NULL,
  `rule_name` varchar(255) NOT NULL,
  `rule_description` text NOT NULL,
  `togaf_phase` varchar(32) DEFAULT NULL,
  `rule_type` enum('principle','constraint','directive') NOT NULL,
  `severity` enum('hard','soft','advisory') NOT NULL,
  `applies_to` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL CHECK (json_valid(`applies_to`)),
  `active` tinyint(1) DEFAULT 1,
  `version` int(11) DEFAULT 1,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `igm_rule_evaluations`
--

CREATE TABLE `igm_rule_evaluations` (
  `evaluation_id` bigint(20) NOT NULL,
  `rule_id` int(11) NOT NULL,
  `rule_version` int(11) NOT NULL,
  `component_id` varchar(128) NOT NULL,
  `action_context` varchar(255) NOT NULL,
  `decision` enum('allowed','blocked','overridden') NOT NULL,
  `evaluated_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `correlation_id` char(36) NOT NULL
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
-- Table structure for table `semantic_vector_store`
--

CREATE TABLE `semantic_vector_store` (
  `vector_id` bigint(20) NOT NULL,
  `content_type` varchar(100) DEFAULT NULL,
  `source_id` bigint(20) DEFAULT NULL,
  `source_table` varchar(100) DEFAULT NULL,
  `content_text` longtext DEFAULT NULL,
  `embedding_vector` longtext DEFAULT NULL,
  `vector_model` varchar(100) DEFAULT NULL,
  `embedding_timestamp` datetime DEFAULT current_timestamp(),
  `confidence` decimal(5,2) DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

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
-- Table structure for table `vector_embedding_metadata`
--

CREATE TABLE `vector_embedding_metadata` (
  `metadata_id` bigint(20) NOT NULL,
  `vector_id` bigint(20) DEFAULT NULL,
  `metadata_key` varchar(255) DEFAULT NULL,
  `metadata_value` text DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Stand-in structure for view `v_togaf_directive_compliance`
-- (See below for the actual view)
--
CREATE TABLE `v_togaf_directive_compliance` (
`rule_code` varchar(64)
,`rule_name` varchar(255)
,`times_verified` bigint(21)
,`last_verified` timestamp
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
-- Indexes for table `cm_context_summaries`
--
ALTER TABLE `cm_context_summaries`
  ADD PRIMARY KEY (`summary_id`),
  ADD UNIQUE KEY `uk_component_version` (`component_name`,`version`);

--
-- Indexes for table `cm_system_context_snapshots`
--
ALTER TABLE `cm_system_context_snapshots`
  ADD PRIMARY KEY (`snapshot_id`),
  ADD UNIQUE KEY `uk_comp_date` (`component_name`,`snapshot_date`);

--
-- Indexes for table `cm_system_context_snapshots_genai_insights`
--
ALTER TABLE `cm_system_context_snapshots_genai_insights`
  ADD PRIMARY KEY (`snapshot_id`),
  ADD UNIQUE KEY `uk_genai_context` (`component_name`,`snapshot_date`,`insight_type`);

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
-- Indexes for table `igm_attestation_ledger`
--
ALTER TABLE `igm_attestation_ledger`
  ADD PRIMARY KEY (`attestation_id`),
  ADD KEY `evaluation_id` (`evaluation_id`);

--
-- Indexes for table `igm_candidate_rules`
--
ALTER TABLE `igm_candidate_rules`
  ADD PRIMARY KEY (`candidate_id`);

--
-- Indexes for table `igm_governance_examples`
--
ALTER TABLE `igm_governance_examples`
  ADD PRIMARY KEY (`example_id`);

--
-- Indexes for table `igm_raw_governance_events`
--
ALTER TABLE `igm_raw_governance_events`
  ADD PRIMARY KEY (`event_id`);

--
-- Indexes for table `igm_rules`
--
ALTER TABLE `igm_rules`
  ADD PRIMARY KEY (`rule_id`),
  ADD UNIQUE KEY `rule_code` (`rule_code`);

--
-- Indexes for table `igm_rule_evaluations`
--
ALTER TABLE `igm_rule_evaluations`
  ADD PRIMARY KEY (`evaluation_id`),
  ADD KEY `rule_id` (`rule_id`);

--
-- Indexes for table `published_context_reports`
--
ALTER TABLE `published_context_reports`
  ADD PRIMARY KEY (`report_id`),
  ADD KEY `idx_status` (`report_status`),
  ADD KEY `idx_component` (`component_name`),
  ADD KEY `idx_published_at` (`published_at`);

--
-- Indexes for table `semantic_vector_store`
--
ALTER TABLE `semantic_vector_store`
  ADD PRIMARY KEY (`vector_id`),
  ADD KEY `idx_content_type` (`content_type`),
  ADD KEY `idx_source` (`source_table`,`source_id`);

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
-- Indexes for table `vector_embedding_metadata`
--
ALTER TABLE `vector_embedding_metadata`
  ADD PRIMARY KEY (`metadata_id`),
  ADD KEY `idx_vector` (`vector_id`);

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
-- AUTO_INCREMENT for table `cm_context_summaries`
--
ALTER TABLE `cm_context_summaries`
  MODIFY `summary_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `cm_system_context_snapshots`
--
ALTER TABLE `cm_system_context_snapshots`
  MODIFY `snapshot_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `cm_system_context_snapshots_genai_insights`
--
ALTER TABLE `cm_system_context_snapshots_genai_insights`
  MODIFY `snapshot_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `consumed_db_introductions`
--
ALTER TABLE `consumed_db_introductions`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `consumed_db_schemas`
--
ALTER TABLE `consumed_db_schemas`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `igm_attestation_ledger`
--
ALTER TABLE `igm_attestation_ledger`
  MODIFY `attestation_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `igm_candidate_rules`
--
ALTER TABLE `igm_candidate_rules`
  MODIFY `candidate_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `igm_governance_examples`
--
ALTER TABLE `igm_governance_examples`
  MODIFY `example_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `igm_raw_governance_events`
--
ALTER TABLE `igm_raw_governance_events`
  MODIFY `event_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `igm_rules`
--
ALTER TABLE `igm_rules`
  MODIFY `rule_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `igm_rule_evaluations`
--
ALTER TABLE `igm_rule_evaluations`
  MODIFY `evaluation_id` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `published_context_reports`
--
ALTER TABLE `published_context_reports`
  MODIFY `report_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `semantic_vector_store`
--
ALTER TABLE `semantic_vector_store`
  MODIFY `vector_id` bigint(20) NOT NULL AUTO_INCREMENT;

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
-- AUTO_INCREMENT for table `vector_embedding_metadata`
--
ALTER TABLE `vector_embedding_metadata`
  MODIFY `metadata_id` bigint(20) NOT NULL AUTO_INCREMENT;

-- --------------------------------------------------------

--
-- Structure for view `v_togaf_directive_compliance`
--
DROP TABLE IF EXISTS `v_togaf_directive_compliance`;

CREATE ALGORITHM=UNDEFINED DEFINER=`xpdgxfsp`@`localhost` SQL SECURITY DEFINER VIEW `v_togaf_directive_compliance`  AS SELECT `r`.`rule_code` AS `rule_code`, `r`.`rule_name` AS `rule_name`, count(`a`.`attestation_id`) AS `times_verified`, max(`a`.`attested_at`) AS `last_verified` FROM ((`igm_rules` `r` join `igm_rule_evaluations` `e` on(`e`.`rule_id` = `r`.`rule_id`)) join `igm_attestation_ledger` `a` on(`a`.`evaluation_id` = `e`.`evaluation_id`)) WHERE `a`.`truth_verified` = 1 GROUP BY `r`.`rule_code`, `r`.`rule_name` ;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
