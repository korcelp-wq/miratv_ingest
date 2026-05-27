@'
# MiraTV Materialization Queue Processor Handoff - 2026-05-27

## Completed Processor Checkpoint

Committed:

- `handoff/api_workers/process_series_metadata_queue.php`
- `handoff/api_workers/process_vod_metadata_queue.php`

Commit:

- `d55b08f feat: add scoped materialization queue processors`

## Live/Expected Endpoint Versions

### Series Metadata Queue Processor

Target server path:

`/home/xpdgxfsp/public_html/_workers/ai/api/process_series_metadata_queue.php`

Endpoint version:

`6B-5E6-2026-05-27-series-shelf-poster-completion`

Supported scoped lanes:

- `only_unmatched_local=1`
- `only_series_shelf_missing=1`

Important policy:

- `only_unmatched_local=1` can complete when useful metadata is written even if backdrop remains unavailable.
- `only_series_shelf_missing=1` can complete when poster artwork exists, even if requested backdrop remains unavailable.
- True no-match/no-art rows should move to retry/manual terminal handling.

### VOD Metadata Queue Processor

Target server path:

`/home/xpdgxfsp/public_html/_workers/ai/api/process_vod_metadata_queue.php`

Endpoint version:

`6B-5F1-2026-05-27-vod-preview-missing-queue`

Supported scoped lane:

- `only_preview_missing=1`

Important policy:

- Calls `materialize_vod_preview.php` with local `content_id` as `vod_id`.
- Completes when requested metadata fields are repaired.
- Partial-completes when useful metadata is written but non-critical fields remain unavailable.
- True no-match/event rows should move to manual terminal handling.

## Drained Queue Lanes

### Series unmatched local metadata

`series / metadata / unmatched_series_local_row_created`

Final known state:

- completed: 267
- needs_manual_match: 7
- queued: 0

### VOD preview missing metadata

`vod / metadata / preview_missing_fields`

Final known state:

- completed: 69
- needs_manual_match: 5
- queued: 0

### Series shelf missing images

`series / metadata / series_shelf_missing_images`

Final known state:

- completed: 17
- needs_manual_match: 7
- failed: 3
- queued: 0

## Remaining Queued Lanes

From the last queue summary:

- `series / metadata / series_port_900_image_repair`: queued 47
- `series / series_info / episode_lookup_missing`: queued 37
- `vod / metadata / manual_test`: queued 1

## Recommended Next Lane

Next safest lane:

`series / metadata / series_port_900_image_repair`

Do not start `episode_lookup_missing` yet. That lane touches series episode/provider identity and should be handled separately.

## Suggested Inspection Query

```sql
SELECT
    id,
    content_id,
    provider,
    provider_content_id,
    mac_user_id,
    missing_fields,
    trigger_reason,
    status,
    priority,
    attempt_count,
    max_attempts,
    created_at,
    updated_at,
    last_error
FROM content_materialization_queue
WHERE content_type = 'series'
  AND materialization_kind = 'metadata'
  AND trigger_reason = 'series_port_900_image_repair'
  AND status = 'queued'
  AND attempt_count < max_attempts
ORDER BY priority ASC, created_at ASC, id ASC
LIMIT 50;