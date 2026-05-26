-- phpMyAdmin SQL Dump
-- version 5.2.2
-- https://www.phpmyadmin.net/
--
-- Host: localhost:3306
-- Generation Time: Jan 28, 2026 at 09:11 AM
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
CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `report_ops_capacity` ()   BEGIN
  SELECT
    COUNT(*)                                              AS total_runs,
    SUM(status = 'running')                               AS active_runs,
    SUM(status = 'failed')                                AS failed_runs,
    (1 - (SUM(status = 'failed') / COUNT(*)))             AS capacity_score,
    NOW()                                                  AS as_of
  FROM job_runs;
END$$

DELIMITER ;

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

--
-- Indexes for dumped tables
--

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
-- Indexes for table `ops_events`
--
ALTER TABLE `ops_events`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_series` (`series_id`),
  ADD KEY `idx_event_ts` (`event_ts`),
  ADD KEY `idx_worker_stage` (`worker`,`stage`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `ai_memory_index`
--
ALTER TABLE `ai_memory_index`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `ai_telemetry`
--
ALTER TABLE `ai_telemetry`
  MODIFY `id` bigint(20) NOT NULL AUTO_INCREMENT;

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
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
