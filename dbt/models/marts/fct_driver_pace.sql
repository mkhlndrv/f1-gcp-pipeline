-- Per-session, per-driver pace metric.
--
-- pace_ratio = driver's median (lap_time_ms / field_median_for_that_lap_number).
--   1.000 = exactly the field median that lap.
--   < 1.000 = faster than the field.
--   > 1.000 = slower than the field.
--
-- Defensible and explainable: no fudge factors, no fuel correction, no
-- clean-air heuristic. Tier 3 (Phase 13) replaces this with the full
-- clean-air model.

{{ config(materialized='table') }}

with per_lap as (
    select
        session_key,
        driver_number,
        lap_number,
        lap_time_ms,
        percentile_cont(lap_time_ms, 0.5)
            over (partition by session_key, lap_number) as field_median_ms
    from {{ ref('fct_lap') }}
)

select
    session_key,
    driver_number,
    count(*)                                                  as laps,
    approx_quantiles(lap_time_ms, 100)[offset(50)]            as median_lap_ms,
    approx_quantiles(lap_time_ms / field_median_ms, 100)[offset(50)]
                                                              as pace_ratio
from per_lap
where field_median_ms > 0
group by 1, 2
