-- One row per (session_key, driver_number, lap_number). The OpenF1 poller is
-- stateless and re-fetches each minute, so the same lap lands many times in
-- raw — we dedupe with QUALIFY on the natural key.
--
-- We also drop:
--   * laps with NULL lap_duration (in-progress / aborted)
--   * pit-out laps (not representative pace)

with src as (
    select * from {{ source('openf1', 'openf1_laps') }}
)

select
    session_key,
    driver_number,
    lap_number,
    cast(lap_duration * 1000 as int64)        as lap_time_ms,
    cast(duration_sector_1 * 1000 as int64)   as sector_1_ms,
    cast(duration_sector_2 * 1000 as int64)   as sector_2_ms,
    cast(duration_sector_3 * 1000 as int64)   as sector_3_ms,
    i1_speed,
    i2_speed,
    st_speed,
    date_start                                 as lap_started_at,
    meeting_key
from src
where lap_duration is not null
  and (is_pit_out_lap is null or is_pit_out_lap = false)
qualify row_number() over (
    partition by session_key, driver_number, lap_number
    order by date_start desc
) = 1
