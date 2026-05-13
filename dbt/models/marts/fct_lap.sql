-- Lap-grain fact. Tier 2 contract: this is the table downstream models and
-- the Phase 12 race deep-dive page join against. Pass-through from staging
-- today; explicit table so future telemetry joins (Phase 13) materialize once
-- per dbt run rather than re-computing on every read.

{{ config(materialized='table') }}

select
    session_key,
    driver_number,
    lap_number,
    lap_time_ms,
    sector_1_ms,
    sector_2_ms,
    sector_3_ms,
    i1_speed,
    i2_speed,
    st_speed,
    lap_started_at,
    meeting_key
from {{ ref('stg_openf1__laps') }}
