{{ config(materialized='view') }}

-- Dashboard-facing view for the page-2 race deep-dive. One row per
-- (session, driver, lap), enriched with display labels, the joined-in
-- pace_ratio, lap-time in seconds (Looker Studio displays seconds nicely),
-- and an outlier flag so the lap-time line chart can hide safety-car / in-laps.
--
-- HARDCODED LABEL CASE-WHENS are an explicit Tier-2 shortcut. Tier 3 should
-- replace these with proper joins to a dim_driver_xref + dim_session built on
-- /drivers and /sessions OpenF1 endpoints. Documented in CLAUDE.md.

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

    -- Hardcoded label maps; Tier 3 replacement target.
    case l.driver_number
        when  1 then 'VER'  when  4 then 'NOR'  when  5 then 'BOR'
        when  6 then 'HAD'  when  7 then 'DOO'  when 10 then 'GAS'
        when 11 then 'PER'  when 12 then 'ANT'  when 14 then 'ALO'
        when 16 then 'LEC'  when 18 then 'STR'  when 20 then 'MAG'
        when 22 then 'TSU'  when 23 then 'ALB'  when 24 then 'ZHO'
        when 27 then 'HUL'  when 30 then 'LAW'  when 31 then 'OCO'
        when 43 then 'COL'  when 44 then 'HAM'  when 55 then 'SAI'
        when 63 then 'RUS'  when 77 then 'BOT'  when 81 then 'PIA'
        when 87 then 'BEA'
        else concat('#', cast(l.driver_number as string))
    end                                                    as driver_label,

    case l.session_key
        when  9839 then '2025 Abu Dhabi GP'
        when 11234 then '2026 Australian GP'
        when 11240 then '2026 Chinese GP — Sprint'
        when 11245 then '2026 Chinese GP'
        when 11253 then '2026 Japanese GP'
        when 11261 then '2026 Bahrain GP'
        when 11269 then '2026 Saudi Arabian GP'
        when 11275 then '2026 Miami GP — Sprint'
        when 11280 then '2026 Miami GP'
        else concat('Session #', cast(l.session_key as string))
    end                                                    as session_label

from laps l
left join session_medians sm  using (session_key)
left join pace p              on p.session_key = l.session_key
                             and p.driver_number = l.driver_number
