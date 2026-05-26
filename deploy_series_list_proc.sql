DELIMITER $$

DROP PROCEDURE IF EXISTS sp_xtream_get_series_list$$
DELIMITER $$

DROP PROCEDURE IF EXISTS sp_xtream_get_series_list$$
CREATE PROCEDURE sp_xtream_get_series_list(
    IN p_username VARCHAR(255),
    IN p_password VARCHAR(255),
    IN p_category_id VARCHAR(50)  -- Optional filter
)
BEGIN
    IF p_category_id IS NULL OR p_category_id = '' THEN
        -- Return all series
        SELECT JSON_ARRAYAGG(
            JSON_OBJECT(
                'num', num,
                'name', name,
                'series_id', series_id,
                'cover', cover,
                'plot', plot,
                'cast', cast,
                'director', director,
                'genre', genre,
                'releaseDate', releaseDate,
                'last_modified', last_modified,
                'rating', rating,
                'rating_5based', rating_5based,
                'backdrop_path', backdrop_path,
                'youtube_trailer', youtube_trailer,
                'episode_run_time', episode_run_time,
                'category_id', category_id
            )
        ) AS json_result
        FROM series
        WHERE is_adult = 0 OR is_adult IS NULL
        ORDER BY name;
    ELSE
        -- Filter by category using mapping table
        SELECT JSON_ARRAYAGG(
            JSON_OBJECT(
                'num', s.num,
                'name', s.name,
                'series_id', s.series_id,
                'cover', s.cover,
                'plot', s.plot,
                'cast', s.cast,
                'director', s.director,
                'genre', s.genre,
                'releaseDate', s.releaseDate,
                'last_modified', s.last_modified,
                'rating', s.rating,
                'rating_5based', s.rating_5based,
                'backdrop_path', s.backdrop_path,
                'youtube_trailer', s.youtube_trailer,
                'episode_run_time', s.episode_run_time,
                'category_id', scm.category_id
            )
        ) AS json_result
        FROM series_category_map scm
        JOIN series s ON scm.series_id = s.id
        WHERE scm.category_id = p_category_id
          AND (s.is_adult = 0 OR s.is_adult IS NULL)
        ORDER BY s.name;
    END IF;
END$$

DELIMITER ;
END$$

DELIMITER ;
