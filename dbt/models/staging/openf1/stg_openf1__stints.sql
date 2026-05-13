-- One row per (session_key, driver_number, stint_number). Stateless poller
-- writes duplicates → dedupe via QUALIFY on the natural key.

with src as (
    select * from {{ source('openf1', 'openf1_stints') }}
)

select
    session_key,
    driver_number,
    stint_number,
    compound,
    lap_start,
    lap_end,
    lap_end - lap_start + 1                as total_laps,
    tyre_age_at_start,
    meeting_key
from src
where compound is not null
qualify row_number() over (
    partition by session_key, driver_number, stint_number
    order by lap_end desc nulls last
) = 1
