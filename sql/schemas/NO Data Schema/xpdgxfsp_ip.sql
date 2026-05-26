-- phpMyAdmin SQL Dump
-- version 5.2.2
-- https://www.phpmyadmin.net/
--
-- Host: localhost:3306
-- Generation Time: Mar 16, 2026 at 11:54 AM
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
-- Database: `xpdgxfsp_ip`
--

-- --------------------------------------------------------

--
-- Table structure for table `account_profile`
--

CREATE TABLE `account_profile` (
  `admin_id` int(11) NOT NULL,
  `name` varchar(120) DEFAULT NULL,
  `email` varchar(160) DEFAULT NULL,
  `phone` varchar(60) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `activation_codes`
--

CREATE TABLE `activation_codes` (
  `id` int(11) NOT NULL,
  `code` varchar(60) NOT NULL,
  `mac_address` varchar(40) DEFAULT NULL,
  `m3u_link` text DEFAULT NULL,
  `user_id` int(11) DEFAULT NULL,
  `expire_date` date DEFAULT NULL,
  `status` varchar(20) DEFAULT 'unused',
  `created_at` timestamp NULL DEFAULT current_timestamp(),
  `dns` text DEFAULT NULL,
  `username` text DEFAULT NULL,
  `password` text DEFAULT NULL,
  `plan_name` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `admins`
--

CREATE TABLE `admins` (
  `id` int(11) NOT NULL,
  `username` varchar(80) NOT NULL,
  `password` varchar(255) NOT NULL,
  `role` varchar(20) DEFAULT 'admin',
  `created_at` timestamp NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

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
-- Table structure for table `app_config`
--

CREATE TABLE `app_config` (
  `id` int(11) NOT NULL,
  `config_key` varchar(100) NOT NULL,
  `config_value` text DEFAULT NULL,
  `description` varchar(255) DEFAULT NULL,
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `created_at` timestamp NOT NULL DEFAULT current_timestamp()
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
-- Table structure for table `device_tokens`
--

CREATE TABLE `device_tokens` (
  `id` int(11) NOT NULL,
  `code` varchar(32) DEFAULT NULL,
  `mac_address` varchar(32) DEFAULT NULL,
  `device_id` varchar(64) DEFAULT NULL,
  `fcm_token` text NOT NULL,
  `created_at` datetime DEFAULT current_timestamp(),
  `updated_at` datetime DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

-- --------------------------------------------------------

--
-- Table structure for table `dns_list`
--

CREATE TABLE `dns_list` (
  `id` int(11) NOT NULL,
  `title` varchar(120) NOT NULL,
  `url` varchar(400) NOT NULL,
  `created_at` timestamp NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `mac_users`
--

CREATE TABLE `mac_users` (
  `id` int(11) NOT NULL,
  `name` varchar(120) DEFAULT NULL,
  `mac_address` varchar(40) NOT NULL,
  `m3u_link` text DEFAULT NULL,
  `status` varchar(20) DEFAULT 'active',
  `expire_date` date DEFAULT NULL,
  `created_at` timestamp NULL DEFAULT current_timestamp(),
  `device_model` varchar(120) DEFAULT NULL,
  `os_version` varchar(80) DEFAULT NULL,
  `protect_playlist` int(11) DEFAULT NULL,
  `server_name` text DEFAULT NULL,
  `dns` text DEFAULT NULL,
  `username` text DEFAULT NULL,
  `password` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `notifications`
--

CREATE TABLE `notifications` (
  `id` int(11) NOT NULL,
  `title` varchar(200) NOT NULL,
  `message` text NOT NULL,
  `created_at` timestamp NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `pcde_procedure_registry`
--

CREATE TABLE `pcde_procedure_registry` (
  `id` int(11) NOT NULL,
  `process_name` varchar(128) NOT NULL,
  `domain` varchar(64) NOT NULL,
  `topic` varchar(64) NOT NULL,
  `unit_type` varchar(64) NOT NULL,
  `instruction` text NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `admin_access` varchar(32) NOT NULL DEFAULT 'admin',
  `source_db` varchar(64) DEFAULT NULL,
  `source_table` varchar(64) DEFAULT NULL,
  `provenance` text DEFAULT NULL,
  `status` varchar(32) DEFAULT NULL,
  `error_count` int(11) DEFAULT NULL,
  `vector_count` int(11) DEFAULT NULL
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
-- Table structure for table `settings`
--

CREATE TABLE `settings` (
  `id` int(11) NOT NULL,
  `key_name` varchar(120) NOT NULL,
  `key_value` text DEFAULT NULL
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
-- Table structure for table `vpn_servers`
--

CREATE TABLE `vpn_servers` (
  `id` int(11) NOT NULL,
  `title` varchar(200) NOT NULL,
  `host` varchar(200) NOT NULL,
  `port` varchar(20) DEFAULT NULL,
  `protocol` varchar(40) DEFAULT NULL,
  `username` varchar(120) DEFAULT NULL,
  `password` varchar(200) DEFAULT NULL,
  `note` text DEFAULT NULL,
  `active` tinyint(1) DEFAULT 1,
  `created_at` timestamp NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Indexes for dumped tables
--

--
-- Indexes for table `account_profile`
--
ALTER TABLE `account_profile`
  ADD PRIMARY KEY (`admin_id`);

--
-- Indexes for table `activation_codes`
--
ALTER TABLE `activation_codes`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `code` (`code`),
  ADD KEY `idx_activation_codes_code` (`code`);

--
-- Indexes for table `admins`
--
ALTER TABLE `admins`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `username` (`username`);

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
-- Indexes for table `app_config`
--
ALTER TABLE `app_config`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `config_key` (`config_key`);

--
-- Indexes for table `cm_system_context_snapshots`
--
ALTER TABLE `cm_system_context_snapshots`
  ADD PRIMARY KEY (`snapshot_id`),
  ADD UNIQUE KEY `uk_comp_date` (`component_name`,`snapshot_date`);

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
-- Indexes for table `device_tokens`
--
ALTER TABLE `device_tokens`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `idx_device` (`device_id`);

--
-- Indexes for table `dns_list`
--
ALTER TABLE `dns_list`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `mac_users`
--
ALTER TABLE `mac_users`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `mac_address` (`mac_address`),
  ADD KEY `idx_mac_users_mac` (`mac_address`);

--
-- Indexes for table `notifications`
--
ALTER TABLE `notifications`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `pcde_procedure_registry`
--
ALTER TABLE `pcde_procedure_registry`
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
-- Indexes for table `settings`
--
ALTER TABLE `settings`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `key_name` (`key_name`);

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
-- Indexes for table `vpn_servers`
--
ALTER TABLE `vpn_servers`
  ADD PRIMARY KEY (`id`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `activation_codes`
--
ALTER TABLE `activation_codes`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `admins`
--
ALTER TABLE `admins`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

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
-- AUTO_INCREMENT for table `app_config`
--
ALTER TABLE `app_config`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `cm_system_context_snapshots`
--
ALTER TABLE `cm_system_context_snapshots`
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
-- AUTO_INCREMENT for table `device_tokens`
--
ALTER TABLE `device_tokens`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `dns_list`
--
ALTER TABLE `dns_list`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `mac_users`
--
ALTER TABLE `mac_users`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `notifications`
--
ALTER TABLE `notifications`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `pcde_procedure_registry`
--
ALTER TABLE `pcde_procedure_registry`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `published_context_reports`
--
ALTER TABLE `published_context_reports`
  MODIFY `report_id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `settings`
--
ALTER TABLE `settings`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

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
-- AUTO_INCREMENT for table `vpn_servers`
--
ALTER TABLE `vpn_servers`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
