-- MVP DB objects created/validated on 2026-06-02
-- Step 4: Canonical EPG join view
-- Step 5: Screen cache rehydrate stored procedure

CREATE OR REPLACE VIEW xpdgxfsp_content.v_live_epg_canonical_join AS
SELECT
  lc.id AS live_channel_id,
  lc.provider_stream_id,
  lc.provider,
  lc.name AS live_channel_name,
  lc.clean_search_name,
  lc.category_id,
  lc.logo_url,
  lc.stream_type,
  lc.live_content_type,
  lc.country_code,
  lc.region_group,
  lc.content_group,
  lc.sport_group,
  lc.canonical_channel AS live_canonical_channel,
  lc.epg_channel_id AS live_epg_channel_id,
  ep.id AS epg_program_id,
  ep.epg_channel_id AS epg_program_epg_channel_id,
  ep.channel AS epg_program_channel_field,
  ep.provider_channel_id,
  ep.provider AS epg_provider,
  ep.canonical_channel AS epg_canonical_channel,
  ep.title AS epg_title,
  ep.description AS epg_description,
  ep.start_time AS epg_start_time,
  ep.end_time AS epg_end_time,
  ep.catchup AS epg_catchup
FROM xpdgxfsp_content.live_channels lc
JOIN xpdgxfsp_content.epg_programs ep
  ON ep.epg_channel_id = lc.epg_channel_id
WHERE lc.epg_channel_id IS NOT NULL
  AND lc.epg_channel_id <> '';

DROP PROCEDURE IF EXISTS xpdgxfsp_content.sp_rehydrate_live_screen_cache;

DELIMITER $$

CREATE PROCEDURE xpdgxfsp_content.sp_rehydrate_live_screen_cache(
  IN p_mac_user_id INT,
  IN p_screen_type VARCHAR(64),
  IN p_expires_hours INT,
  IN p_reason VARCHAR(128)
)
BEGIN
  UPDATE xpdgxfsp_content.live_screen_cache
  SET
    refreshed_at = UTC_TIMESTAMP(),
    created_at = UTC_TIMESTAMP(),
    expires_at = DATE_ADD(UTC_TIMESTAMP(), INTERVAL p_expires_hours HOUR),
    problem_flags = CASE
      WHEN problem_flags IS NULL OR problem_flags = '' THEN p_reason
      WHEN problem_flags LIKE CONCAT('%', p_reason, '%') THEN problem_flags
      ELSE CONCAT(problem_flags, ',', p_reason)
    END
  WHERE mac_user_id = p_mac_user_id
    AND (
      p_screen_type = 'all'
      OR screen_type = p_screen_type
    );
END$$

DELIMITER ;
