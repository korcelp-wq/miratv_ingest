-- phpMyAdmin SQL Dump
-- version 5.2.2
-- https://www.phpmyadmin.net/
--
-- Host: localhost:3306
-- Generation Time: Jan 28, 2026 at 09:10 AM
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

--
-- Dumping data for table `igm_attestation_ledger`
--

INSERT INTO `igm_attestation_ledger` (`attestation_id`, `evaluation_id`, `attested_by`, `confidence`, `evidence_hash`, `attested_at`, `truth_verified`, `verification_basis`) VALUES
(1, 982144, 'system', 1.00, NULL, '2026-01-20 20:56:19', 1, 'deterministic_rule_match');

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

--
-- Dumping data for table `igm_governance_examples`
--

INSERT INTO `igm_governance_examples` (`example_id`, `component_id`, `action_attempted`, `decision`, `rationale`, `actor`, `occurred_at`) VALUES
(1, 'content_ingestion_pipeline', 'introduce tightly coupled parsing logic into ingestion worker', 'blocked', 'Action was blocked to preserve modularity and prevent downstream coupling across ingestion, normalization, and delivery layers.', 'human', '2026-01-20 20:45:42');

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
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `igm_attestation_ledger`
--
ALTER TABLE `igm_attestation_ledger`
  MODIFY `attestation_id` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `igm_candidate_rules`
--
ALTER TABLE `igm_candidate_rules`
  MODIFY `candidate_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `igm_governance_examples`
--
ALTER TABLE `igm_governance_examples`
  MODIFY `example_id` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

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
