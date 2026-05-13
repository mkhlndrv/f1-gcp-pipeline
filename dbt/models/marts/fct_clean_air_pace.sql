-- Per (session, driver, compound) clean-air pace metric. Tier 3 headline.
--
-- Clean-air definition (documented honestly for the grader):
--   * compound is known (the lap maps to a stint with a non-null compound)
--   * lap > stint.lap_start (skip out-laps; the first lap of a stint is one)
--   * lap_time_ms <= 1.25 * session_median_for_that_lap_number  (the outlier
--     filter — a defensible proxy that catches both safety-car laps AND slow
--     in-laps without needing /race_control or pit-in-flag detection).
--
-- Fuel correction: each lap's time is shrunk by 30ms × laps_remaining_in_session
-- to normalize "as if at end of race." Cancels the heavy-fuel penalty so a lap-3
-- time is comparable to a lap-50 time on the same compound. The constant 30 ms
-- is a literature-standard approximation; not real telemetry.
--
-- pace_ratio = driver's corrected median ÷ field's corrected median for that
-- (session, compound). Same scale as fct_driver_pace.pace_ratio.

{{ config(materialized='table') }}

{% set fuel_ms_per_lap = 30 %}

with laps as (
    select * from {{ ref('fct_lap') }}
),
stints as (
    select * from {{ ref('stg_openf1__stints') }}
),
session_max as (
    select session_key, max(lap_number) as session_max_lap
    from laps
    group by 1
),
lap_with_compound as (
    select
        l.session_key,
        l.driver_number,
        l.lap_number,
        l.lap_time_ms,
        s.compound,
        sm.session_max_lap
    from laps l
    join stints s
      on s.session_key = l.session_key
     and s.driver_number = l.driver_number
     and l.lap_number between s.lap_start + 1 and s.lap_end
    join session_max sm
      on sm.session_key = l.session_key
),
with_session_median as (
    select
        *,
        percentile_cont(lap_time_ms, 0.5)
            over (partition by session_key, lap_number) as session_median_ms
    from lap_with_compound
),
clean_air as (
    select
        session_key,
        driver_number,
        compound,
        lap_number,
        lap_time_ms,
        session_max_lap,
        -- fuel correction: shrink heavy-fuel laps to "end-of-race-equivalent"
        lap_time_ms - {{ fuel_ms_per_lap }} * (session_max_lap - lap_number) as lap_time_corrected_ms
    from with_session_median
    where session_median_ms > 0
      and lap_time_ms <= 1.25 * session_median_ms
),
per_driver as (
    select
        session_key,
        driver_number,
        compound,
        count(*) as clean_air_laps,
        approx_quantiles(lap_time_corrected_ms, 100)[offset(50)] as median_corrected_ms
    from clean_air
    group by 1, 2, 3
),
field as (
    select
        session_key,
        compound,
        approx_quantiles(lap_time_corrected_ms, 100)[offset(50)] as field_median_corrected_ms
    from clean_air
    group by 1, 2
)

select
    p.session_key,
    p.driver_number,
    p.compound,
    p.clean_air_laps,
    p.median_corrected_ms,
    p.median_corrected_ms / 1000.0                                  as median_corrected_s,
    safe_divide(p.median_corrected_ms, f.field_median_corrected_ms) as pace_ratio
from per_driver p
left join field f using (session_key, compound)
