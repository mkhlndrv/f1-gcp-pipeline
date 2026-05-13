-- One row per (season, round, driver) qualifying entry.

with flat as (
    select
        race.season                       as season,
        race.round                        as round,
        qual.Driver.driverId              as driver_id,
        qual.Constructor.constructorId    as constructor_id,
        qual.position                     as qualifying_position,
        qual.Q1                           as q1_time,
        qual.Q2                           as q2_time,
        qual.Q3                           as q3_time
    from {{ source('ergast', 'ergast_qualifying') }} as page,
         unnest(page.RaceTable.Races)     as race,
         unnest(race.QualifyingResults)   as qual
)

select distinct *
from flat
where season is not null
  and round is not null
  and driver_id is not null
