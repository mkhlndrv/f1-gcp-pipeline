{{ config(materialized='view') }}

-- Dashboard-facing view for the page-2 race deep-dive. One row per
-- (session, driver, lap), enriched with display labels, the joined-in
-- pace_ratio, lap-time in seconds (Looker Studio displays seconds nicely),
-- and an outlier flag so the lap-time line chart can hide safety-car / in-laps.
--
-- Labels come from dbt/macros/driver_label.sql (Tier-2 shortcut; replace with
-- proper dim_driver_xref + dim_session once the /drivers extractor lands).

with laps as (
    select * from {{ ref('fct_lap') }}
),
session_medians as (
    select session_key,
           approx_quantiles(lap_time_ms, 100)[offset(50)] as session_median_ms
    from laps
    group by 1
),
pace as (
    select * from {{ ref('fct_driver_pace') }}
)

select
    l.session_key,
    l.driver_number,
    l.lap_number,
    l.lap_time_ms,
    l.lap_time_ms / 1000.0                                 as lap_time_s,
    l.sector_1_ms / 1000.0                                 as sector_1_s,
    l.sector_2_ms / 1000.0                                 as sector_2_s,
    l.sector_3_ms / 1000.0                                 as sector_3_s,
    l.i1_speed,
    l.i2_speed,
    l.st_speed,
    l.lap_started_at,
    l.meeting_key,
    p.pace_ratio,
    p.median_lap_ms / 1000.0                               as driver_median_lap_s,

    -- Outlier flag (safety car, in/out laps, etc.) so charts can hide them.
    l.lap_time_ms > 1.25 * sm.session_median_ms            as is_outlier_lap,

    {{ driver_label('l.driver_number') }}    as driver_label,
    {{ session_label('l.session_key') }}     as session_label

from laps l
left join session_medians sm  using (session_key)
left join pace p              on p.session_key = l.session_key
                             and p.driver_number = l.driver_number
