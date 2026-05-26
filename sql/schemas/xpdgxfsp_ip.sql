-- phpMyAdmin SQL Dump
-- version 5.2.2
-- https://www.phpmyadmin.net/
--
-- Host: localhost:3306
-- Generation Time: Jan 28, 2026 at 09:09 AM
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

--
-- Dumping data for table `activation_codes`
--

INSERT INTO `activation_codes` (`id`, `code`, `mac_address`, `m3u_link`, `user_id`, `expire_date`, `status`, `created_at`, `dns`, `username`, `password`, `plan_name`) VALUES
(2, 'JR55KCDB', '', 'http://uxurwymd.eldervpn.xyz/get.php?username=Marina2025&password=3KY586YR&type=m3u_plus&output=mpegts', NULL, '2026-10-05', 'unused', '2025-12-18 17:21:33', 'uxurwymd.eldervpn.xyz', 'Marina2025', '3KY586YR', NULL);

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

--
-- Dumping data for table `admins`
--

INSERT INTO `admins` (`id`, `username`, `password`, `role`, `created_at`) VALUES
(1, 'admin', '$2y$10$6y/mCNJHwFFXXN1j63id/uRn/hGYT0wrO1uk6F3VYUR3AJMW54mym', 'super', '2025-12-15 03:41:54');

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

--
-- Dumping data for table `mac_users`
--

INSERT INTO `mac_users` (`id`, `name`, `mac_address`, `m3u_link`, `status`, `expire_date`, `created_at`, `device_model`, `os_version`, `protect_playlist`, `server_name`, `dns`, `username`, `password`) VALUES
(2, '', '06:75:33:16:50:33', 'http://uxurwymd.eldervpn.xyz/get.php?username=Marina2025&password=3KY586YR&type=m3u_plus&output=mpegts', 'active', NULL, '2025-12-18 17:24:29', NULL, NULL, 1, 'uxurwymd.eldervpn.xyz', 'uxurwymd.eldervpn.xyz', 'Marina2025', '3KY586YR');

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
-- Table structure for table `settings`
--

CREATE TABLE `settings` (
  `id` int(11) NOT NULL,
  `key_name` varchar(120) NOT NULL,
  `key_value` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `settings`
--

INSERT INTO `settings` (`id`, `key_name`, `key_value`) VALUES
(1, 'api_key', 'CHANGE-ME-API-KEY'),
(2, 'fcm_server_key', 'PASTE-YOUR-FCM-SERVER-KEY'),
(3, 'mac_length', '8');

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
-- Indexes for table `ai_memory_index`
--
ALTER TABLE `ai_memory_index`
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
-- Indexes for table `settings`
--
ALTER TABLE `settings`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `key_name` (`key_name`);

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
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- AUTO_INCREMENT for table `admins`
--
ALTER TABLE `admins`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `ai_memory_index`
--
ALTER TABLE `ai_memory_index`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

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
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- AUTO_INCREMENT for table `notifications`
--
ALTER TABLE `notifications`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `settings`
--
ALTER TABLE `settings`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=5;

--
-- AUTO_INCREMENT for table `vpn_servers`
--
ALTER TABLE `vpn_servers`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
