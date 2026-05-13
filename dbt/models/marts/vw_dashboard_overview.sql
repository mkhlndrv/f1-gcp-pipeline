{{ config(materialized='view') }}

-- Dashboard-facing flat view: one row per (race, driver) with everything Looker
-- Studio needs in a single source, including the windowed cumulative_points so
-- the chart doesn't need to compute running totals client-side.

select
    f.race_id,
    f.season,
    f.round,
    f.driver_id,
    f.constructor_id,
    f.grid,
    f.position,
    f.qualifying_position,
    f.points,
    f.status,
    f.laps,

    d.code           as driver_code,
    d.full_name,
    d.nationality,
    d.latest_constructor_id,

    r.race_name,
    r.race_date,
    r.country,
    r.circuit_name,

    case when f.position = 1   then 1 else 0 end as is_win,
    case when f.position <= 3  then 1 else 0 end as is_podium,
    f.grid - f.position                          as grid_to_finish,

    sum(f.points) over (
        partition by f.driver_id, f.season
        order by f.round
        rows between unbounded preceding and current row
    ) as cumulative_points

from {{ ref('fct_driver_race_summary') }} f
left join {{ ref('dim_driver') }} d on d.driver_id = f.driver_id
left join {{ ref('dim_race')   }} r on r.race_id   = f.race_id
