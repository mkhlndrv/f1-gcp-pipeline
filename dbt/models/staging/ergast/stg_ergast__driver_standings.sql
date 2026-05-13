-- One row per (season, driver). For each season, we keep the standings after the LATEST round only —
-- so this view always reflects "current championship state."

with flat as (
    select
        list.season                            as season,
        list.round                             as round,
        ds.Driver.driverId                     as driver_id,
        ds.Constructors[safe_offset(0)].constructorId as constructor_id,
        ds.position                            as position,
        ds.points                              as points,
        ds.wins                                as wins
    from {{ source('ergast', 'ergast_driverstandings') }} as page,
         unnest(page.StandingsTable.StandingsLists) as list,
         unnest(list.DriverStandings)          as ds
),
deduped as (
    select distinct * from flat
)

select *
from deduped
qualify row_number() over (partition by season, driver_id order by round desc) = 1
