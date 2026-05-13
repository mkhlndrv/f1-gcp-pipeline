-- Main fact for the dashboard. One row per (race, driver) with grid, finishing position, points,
-- status, laps, and qualifying position. Drives every Tier-1 chart.

with r as (
    select * from {{ ref('stg_ergast__results') }}
),
q as (
    select * from {{ ref('stg_ergast__qualifying') }}
)

select
    concat(cast(r.season as string), '-', cast(r.round as string)) as race_id,
    r.season,
    r.round,
    r.driver_id,
    r.constructor_id,
    r.grid,
    r.position,
    r.points,
    r.laps,
    r.status,
    q.qualifying_position
from r
left join q
       on q.season    = r.season
      and q.round     = r.round
      and q.driver_id = r.driver_id
