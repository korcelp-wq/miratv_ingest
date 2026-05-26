-- phpMyAdmin SQL Dump
-- version 5.2.2
-- https://www.phpmyadmin.net/
--
-- Host: localhost:3306
-- Generation Time: Jan 28, 2026 at 09:08 AM
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

DELIMITER $$
--
-- Procedures
--
CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `report_callosum_alignment` ()   BEGIN
  SELECT
    COUNT(*)                                                    AS reports_total,
    SUM(TIMESTAMPDIFF(MINUTE, created_at, NOW()) > 15)         AS stale_reports,
    (1 - (
      SUM(TIMESTAMPDIFF(MINUTE, created_at, NOW()) > 15)
      / COUNT(*)
    ))                                                          AS coherence_score,
    NOW()                                                       AS as_of
  FROM cm_matrix_reports;
END$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_cm_execute_request` (IN `p_request_id` INT, IN `p_executor` VARCHAR(64))   BEGIN
    DECLARE v_routine_name VARCHAR(128);
    DECLARE v_target_db VARCHAR(64);
    DECLARE v_description TEXT;

    SELECT
        r.routine_name,
        r.target_db,
        r.description
    INTO
        v_routine_name,
        v_target_db,
        v_description
    FROM cm_requests req
    JOIN cm_routines r ON req.routine_id = r.routine_id
    WHERE req.request_id = p_request_id
      AND req.status = 'requested'
      AND r.active = 1;

    IF v_routine_name IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Request not executable';
    END IF;

    SET @exec_sql = CONCAT(
        'CALL ',
        v_target_db,
        '.',
        v_routine_name,
        '()'
    );

    PREPARE stmt FROM @exec_sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;

    INSERT INTO cm_documents (
        document_type,
        audience,
        purpose,
        scope,
        source_system,
        source_actor,
        body
    ) VALUES (
        'StatusReport',
        'All',
        'Inform',
        v_routine_name,
        CONCAT(v_target_db, '.', v_routine_name),
        p_executor,
        CONCAT(
            'Routine executed successfully\n',
            'Routine: ', v_routine_name
        )
    );

    UPDATE cm_requests
    SET status = 'executed'
    WHERE request_id = p_request_id;
END$$

CREATE DEFINER=`xpdgxfsp`@`localhost` PROCEDURE `sp_cm_insert_document` (IN `p_document_type` VARCHAR(64), IN `p_audience` VARCHAR(64), IN `p_purpose` VARCHAR(64), IN `p_scope` VARCHAR(128), IN `p_body` TEXT, IN `p_source_actor` VARCHAR(64), IN `p_source_system` VARCHAR(64))   BEGIN
    /* basic structural checks */
    IF p_document_type IS NULL OR p_audience IS NULL OR p_purpose IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Invalid document: required fields missing';
    END IF;

    INSERT INTO cm_documents (
        document_type,
        audience,
        purpose,
        scope,
        body,
        source_actor,
        source_system
    ) VALUES (
        p_document_type,
        p_audience,
        p_purpose,
        p_scope,
        p_body,
        p_source_actor,
        p_source_system
    );
END$$

DELIMITER ;

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

--
-- Dumping data for table `cm_documents`
--

INSERT INTO `cm_documents` (`document_id`, `document_type`, `audience`, `purpose`, `scope`, `source_system`, `source_actor`, `body`, `created_at`) VALUES
(1, 'Routine Request', 'ingest_db', 'Inform', 'Ingest Pipeline Health', 'ui', 'human', 'Request execution of sp_ingest_pipeline_health', '2026-01-16 10:54:35');

-- --------------------------------------------------------

--
-- Table structure for table `cm_document_types`
--

CREATE TABLE `cm_document_types` (
  `document_type` varchar(64) NOT NULL,
  `description` text NOT NULL,
  `active` tinyint(1) DEFAULT 1
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;

--
-- Dumping data for table `cm_document_types`
--

INSERT INTO `cm_document_types` (`document_type`, `description`, `active`) VALUES
('RoutineRequest', 'Request to execute a registered stored procedure', 1),
('StatusReport', 'Output or result of a stored procedure', 1),
('DecisionRecord', 'Human decision captured for visibility and memory', 1),
('Recommendation', 'Advisory output from neuronet', 1),
('MatrixReport', 'Callosum-level synthesized report', 1),
('Information', 'General informational document', 1),
('Constraint', 'Declared rule or limitation', 1);

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

--
-- Dumping data for table `cm_requests`
--

INSERT INTO `cm_requests` (`request_id`, `routine_id`, `requested_by`, `request_document_id`, `status`, `created_at`) VALUES
(1, 1, 'human', 1, 'requested', '2026-01-16 10:57:26');

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

--
-- Dumping data for table `cm_routines`
--

INSERT INTO `cm_routines` (`routine_id`, `target_db`, `routine_name`, `description`, `output_document_type`, `active`, `created_at`) VALUES
(1, 'ingest_db', 'sp_ingest_pipeline_health', 'Reports current ingest pipeline state', 'Status Report', 1, '2026-01-16 10:57:04');

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

--
-- Indexes for dumped tables
--

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
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `cm_documents`
--
ALTER TABLE `cm_documents`
  MODIFY `document_id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `cm_matrix_reports`
--
ALTER TABLE `cm_matrix_reports`
  MODIFY `report_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `cm_requests`
--
ALTER TABLE `cm_requests`
  MODIFY `request_id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `cm_routines`
--
ALTER TABLE `cm_routines`
  MODIFY `routine_id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

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
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
