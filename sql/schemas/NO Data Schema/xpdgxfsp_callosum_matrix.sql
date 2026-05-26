-- phpMyAdmin SQL Dump
-- version 5.2.2
-- https://www.phpmyadmin.net/
--
-- Host: localhost:3306
-- Generation Time: Mar 16, 2026 at 11:52 AM
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
-- Database: `xpdgxfsp_callosum_matrix`
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
-- Table structure for table `cm_documents`
--

CREATE TABLE `cm_documents` (
  `document_id` int(11) NOT NULL,
  `document_type` varchar(64) NOT NULL,
  `audience` varchar(64) NOT NULL,
  `purpose` varchar(64) NOT NULL,
  `scope` varchar(128) DEFAULT NULL,
  `source_system` varchar(64) DEFAULT NULL,
  `source_actor` varchar(64) DEFAULT NULL,
  `body` text NOT NULL,
  `created_at` datetime DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `cm_document_types`
--

CREATE TABLE `cm_document_types` (
  `document_type` varchar(64) NOT NULL,
  `description` text NOT NULL,
  `active` tinyint(1) DEFAULT 1
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `cm_matrix_reports`
--

CREATE TABLE `cm_matrix_reports` (
  `report_id` int(11) NOT NULL,
  `title` varchar(128) DEFAULT NULL,
  `derived_from` text DEFAULT NULL,
  `body` text NOT NULL,
  `created_at` datetime DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `cm_requests`
--

CREATE TABLE `cm_requests` (
  `request_id` int(11) NOT NULL,
  `routine_id` int(11) NOT NULL,
  `requested_by` varchar(64) DEFAULT NULL,
  `request_document_id` int(11) DEFAULT NULL,
  `status` varchar(32) DEFAULT 'requested',
  `created_at` datetime DEFAULT current_timestamp()
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `cm_routines`
--

CREATE TABLE `cm_routines` (
  `routine_id` int(11) NOT NULL,
  `target_db` varchar(64) NOT NULL,
  `routine_name` varchar(128) NOT NULL,
  `description` text DEFAULT NULL,
  `output_document_type` varchar(64) DEFAULT NULL,
  `active` tinyint(1) DEFAULT 1,
  `created_at` datetime DEFAULT current_timestamp()
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
  `created_at` datetime(6) NOT NULL DEFAULT current_timestamp(6)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `cm_system_context_snapshots_llm_reasoning`
--

CREATE TABLE `cm_system_context_snapshots_llm_reasoning` (
  `snapshot_id` bigint(20) UNSIGNED NOT NULL,
  `component_name` varchar(255) NOT NULL,
  `snapshot_date` date NOT NULL,
  `reasoning_type` varchar(100) DEFAULT NULL,
  `context_snapshot` longtext NOT NULL,
  `interpretation_notes` longtext DEFAULT NULL,
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
-- Stand-in structure for view `vw_cm_documents_read`
-- (See below for the actual view)
--
CREATE TABLE `vw_cm_documents_read` (
`document_id` int(11)
,`document_type` varchar(64)
,`audience` varchar(64)
,`purpose` varchar(64)
,`scope` varchar(128)
,`source_system` varchar(64)
,`source_actor` varchar(64)
,`created_at` datetime
,`body` text
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_cm_document_input`
-- (See below for the actual view)
--
CREATE TABLE `vw_cm_document_input` (
`document_id` binary(0)
,`document_type` varchar(64)
,`audience` varchar(64)
,`purpose` varchar(64)
,`scope` varchar(128)
,`body` text
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_cm_document_types`
-- (See below for the actual view)
--
CREATE TABLE `vw_cm_document_types` (
`document_type` varchar(64)
,`description` text
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_cm_matrix_reports_read`
-- (See below for the actual view)
--
CREATE TABLE `vw_cm_matrix_reports_read` (
`report_id` int(11)
,`title` varchar(128)
,`derived_from` text
,`created_at` datetime
,`body` text
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_cm_pending_requests`
-- (See below for the actual view)
--
CREATE TABLE `vw_cm_pending_requests` (
`request_id` int(11)
,`target_db` varchar(64)
,`routine_name` varchar(128)
,`description` text
,`requested_by` varchar(64)
,`status` varchar(32)
,`created_at` datetime
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_cm_routines_catalog`
-- (See below for the actual view)
--
CREATE TABLE `vw_cm_routines_catalog` (
`routine_id` int(11)
,`target_db` varchar(64)
,`routine_name` varchar(128)
,`description` text
,`output_document_type` varchar(64)
,`active` tinyint(1)
,`created_at` datetime
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_focus_coordination`
-- (See below for the actual view)
--
CREATE TABLE `vw_focus_coordination` (
`focus_name` varchar(12)
,`source_component` varchar(24)
,`record_time` datetime /* mariadb-5.3 */
,`reports_total` bigint(21)
,`stale_reports` decimal(22,0)
,`coherence_score` decimal(27,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_focus_cvi`
-- (See below for the actual view)
--
CREATE TABLE `vw_focus_cvi` (
`focus_name` varchar(3)
,`source_component` varchar(24)
,`record_time` datetime
,`routine_name` varchar(128)
,`requested_by` varchar(64)
,`status` varchar(32)
,`age_seconds` bigint(21)
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
-- Indexes for table `cm_documents`
--
ALTER TABLE `cm_documents`
  ADD PRIMARY KEY (`document_id`),
  ADD KEY `fk_cm_documents_type` (`document_type`);

--
-- Indexes for table `cm_document_types`
--
ALTER TABLE `cm_document_types`
  ADD PRIMARY KEY (`document_type`);

--
-- Indexes for table `cm_matrix_reports`
--
ALTER TABLE `cm_matrix_reports`
  ADD PRIMARY KEY (`report_id`);

--
-- Indexes for table `cm_requests`
--
ALTER TABLE `cm_requests`
  ADD PRIMARY KEY (`request_id`),
  ADD KEY `routine_id` (`routine_id`),
  ADD KEY `request_document_id` (`request_document_id`);

--
-- Indexes for table `cm_routines`
--
ALTER TABLE `cm_routines`
  ADD PRIMARY KEY (`routine_id`);

--
-- Indexes for table `cm_system_context_snapshots`
--
ALTER TABLE `cm_system_context_snapshots`
  ADD PRIMARY KEY (`snapshot_id`),
  ADD UNIQUE KEY `unique_component_date` (`component_name`,`snapshot_date`);

--
-- Indexes for table `cm_system_context_snapshots_llm_reasoning`
--
ALTER TABLE `cm_system_context_snapshots_llm_reasoning`
  ADD PRIMARY KEY (`snapshot_id`),
  ADD UNIQUE KEY `uk_llm_context` (`component_name`,`snapshot_date`,`reasoning_type`);

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
-- AUTO_INCREMENT for table `cm_documents`
--
ALTER TABLE `cm_documents`
  MODIFY `document_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `cm_matrix_reports`
--
ALTER TABLE `cm_matrix_reports`
  MODIFY `report_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `cm_requests`
--
ALTER TABLE `cm_requests`
  MODIFY `request_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `cm_routines`
--
ALTER TABLE `cm_routines`
  MODIFY `routine_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `cm_system_context_snapshots`
--
ALTER TABLE `cm_system_context_snapshots`
  MODIFY `snapshot_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `cm_system_context_snapshots_llm_reasoning`
--
ALTER TABLE `cm_system_context_snapshots_llm_reasoning`
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
-- AUTO_INCREMENT for table `cvi_carousel`
--
ALTER TABLE `cvi_carousel`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

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

-- --------------------------------------------------------

--
-- Structure for view `vw_cm_documents_read`
--
DROP TABLE IF EXISTS `vw_cm_documents_read`;

CREATE ALGORITHM=UNDEFINED DEFINER=`xpdgxfsp`@`localhost` SQL SECURITY DEFINER VIEW `vw_cm_documents_read`  AS SELECT `cm_documents`.`document_id` AS `document_id`, `cm_documents`.`document_type` AS `document_type`, `cm_documents`.`audience` AS `audience`, `cm_documents`.`purpose` AS `purpose`, `cm_documents`.`scope` AS `scope`, `cm_documents`.`source_system` AS `source_system`, `cm_documents`.`source_actor` AS `source_actor`, `cm_documents`.`created_at` AS `created_at`, `cm_documents`.`body` AS `body` FROM `cm_documents` ORDER BY `cm_documents`.`created_at` DESC ;

-- --------------------------------------------------------

--
-- Structure for view `vw_cm_document_input`
--
DROP TABLE IF EXISTS `vw_cm_document_input`;

CREATE ALGORITHM=UNDEFINED DEFINER=`xpdgxfsp`@`localhost` SQL SECURITY DEFINER VIEW `vw_cm_document_input`  AS SELECT NULL AS `document_id`, `cm_documents`.`document_type` AS `document_type`, `cm_documents`.`audience` AS `audience`, `cm_documents`.`purpose` AS `purpose`, `cm_documents`.`scope` AS `scope`, `cm_documents`.`body` AS `body` FROM `cm_documents` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_cm_document_types`
--
DROP TABLE IF EXISTS `vw_cm_document_types`;

CREATE ALGORITHM=UNDEFINED DEFINER=`xpdgxfsp`@`localhost` SQL SECURITY DEFINER VIEW `vw_cm_document_types`  AS SELECT `cm_document_types`.`document_type` AS `document_type`, `cm_document_types`.`description` AS `description` FROM `cm_document_types` WHERE `cm_document_types`.`active` = 1 ;

-- --------------------------------------------------------

--
-- Structure for view `vw_cm_matrix_reports_read`
--
DROP TABLE IF EXISTS `vw_cm_matrix_reports_read`;

CREATE ALGORITHM=UNDEFINED DEFINER=`xpdgxfsp`@`localhost` SQL SECURITY DEFINER VIEW `vw_cm_matrix_reports_read`  AS SELECT `cm_matrix_reports`.`report_id` AS `report_id`, `cm_matrix_reports`.`title` AS `title`, `cm_matrix_reports`.`derived_from` AS `derived_from`, `cm_matrix_reports`.`created_at` AS `created_at`, `cm_matrix_reports`.`body` AS `body` FROM `cm_matrix_reports` ORDER BY `cm_matrix_reports`.`created_at` DESC ;

-- --------------------------------------------------------

--
-- Structure for view `vw_cm_pending_requests`
--
DROP TABLE IF EXISTS `vw_cm_pending_requests`;

CREATE ALGORITHM=UNDEFINED DEFINER=`xpdgxfsp`@`localhost` SQL SECURITY DEFINER VIEW `vw_cm_pending_requests`  AS SELECT `req`.`request_id` AS `request_id`, `r`.`target_db` AS `target_db`, `r`.`routine_name` AS `routine_name`, `r`.`description` AS `description`, `req`.`requested_by` AS `requested_by`, `req`.`status` AS `status`, `req`.`created_at` AS `created_at` FROM (`cm_requests` `req` join `cm_routines` `r` on(`req`.`routine_id` = `r`.`routine_id`)) WHERE `req`.`status` = 'requested' ;

-- --------------------------------------------------------

--
-- Structure for view `vw_cm_routines_catalog`
--
DROP TABLE IF EXISTS `vw_cm_routines_catalog`;

CREATE ALGORITHM=UNDEFINED DEFINER=`xpdgxfsp`@`localhost` SQL SECURITY DEFINER VIEW `vw_cm_routines_catalog`  AS SELECT `cm_routines`.`routine_id` AS `routine_id`, `cm_routines`.`target_db` AS `target_db`, `cm_routines`.`routine_name` AS `routine_name`, `cm_routines`.`description` AS `description`, `cm_routines`.`output_document_type` AS `output_document_type`, `cm_routines`.`active` AS `active`, `cm_routines`.`created_at` AS `created_at` FROM `cm_routines` WHERE `cm_routines`.`active` = 1 ;

-- --------------------------------------------------------

--
-- Structure for view `vw_focus_coordination`
--
DROP TABLE IF EXISTS `vw_focus_coordination`;

CREATE ALGORITHM=UNDEFINED DEFINER=`xpdgxfsp`@`localhost` SQL SECURITY DEFINER VIEW `vw_focus_coordination`  AS SELECT 'coordination' AS `focus_name`, 'xpdgxfsp_callosum_matrix' AS `source_component`, current_timestamp() AS `record_time`, count(0) AS `reports_total`, sum(case when timestampdiff(MINUTE,`cm_matrix_reports`.`created_at`,current_timestamp()) > 15 then 1 else 0 end) AS `stale_reports`, 1 - sum(case when timestampdiff(MINUTE,`cm_matrix_reports`.`created_at`,current_timestamp()) > 15 then 1 else 0 end) / nullif(count(0),0) AS `coherence_score` FROM `cm_matrix_reports` WHERE `cm_matrix_reports`.`created_at` >= current_timestamp() - interval 24 hour ;

-- --------------------------------------------------------

--
-- Structure for view `vw_focus_cvi`
--
DROP TABLE IF EXISTS `vw_focus_cvi`;

CREATE ALGORITHM=UNDEFINED DEFINER=`xpdgxfsp`@`localhost` SQL SECURITY DEFINER VIEW `vw_focus_cvi`  AS SELECT 'cvi' AS `focus_name`, 'xpdgxfsp_callosum_matrix' AS `source_component`, `r`.`created_at` AS `record_time`, `rt`.`routine_name` AS `routine_name`, `r`.`requested_by` AS `requested_by`, `r`.`status` AS `status`, timestampdiff(SECOND,`r`.`created_at`,current_timestamp()) AS `age_seconds` FROM (`cm_requests` `r` join `cm_routines` `rt` on(`r`.`routine_id` = `rt`.`routine_id`)) ORDER BY `r`.`created_at` DESC LIMIT 0, 1000 ;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
