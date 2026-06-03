-- EPG DB objects confirmed/created on 2026-06-02
-- Raw import table: xpdgxfsp_content.epg_programmes
-- Canonical app table: xpdgxfsp_content.epg_programs
-- Bridge: raw XMLTV-shaped rows -> app-ready DATETIME rows

DROP PROCEDURE IF EXISTS xpdgxfsp_content.sp_apply_epg_programmes_to_epg_programs;

DELIMITER $$

CREATE PROCEDURE xpdgxfsp_content.sp_apply_epg_programmes_to_epg_programs()
BEGIN
  INSERT INTO xpdgxfsp_content.epg_programs (
    epg_channel_id,
    title,
    description,
    start_time,
    end_time,
    catchup,
    provider,
    channel,
    provider_channel_id,
    canonical_channel
  )
  SELECT
    r.channel AS epg_channel_id,
    LEFT(r.title, 255) AS title,
    r.description,
    STR_TO_DATE(r.start_time, '%Y%m%d%H%i%s') AS start_time,
    STR_TO_DATE(r.end_time, '%Y%m%d%H%i%s') AS end_time,
    0 AS catchup,
    r.provider,
    LEFT(r.channel, 128) AS channel,
    0 AS provider_channel_id,
    r.channel AS canonical_channel
  FROM xpdgxfsp_content.epg_programmes r
  LEFT JOIN xpdgxfsp_content.epg_programs p
    ON p.epg_channel_id = r.channel
   AND p.start_time = STR_TO_DATE(r.start_time, '%Y%m%d%H%i%s')
   AND p.end_time = STR_TO_DATE(r.end_time, '%Y%m%d%H%i%s')
   AND COALESCE(p.title, '') = COALESCE(LEFT(r.title, 255), '')
  WHERE r.start_time REGEXP '^[0-9]{14}$'
    AND r.end_time REGEXP '^[0-9]{14}$'
    AND p.id IS NULL;
END$$

DELIMITER ;
