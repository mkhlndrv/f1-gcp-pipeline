{{ config(materialized='view') }}

-- "Live" race state. Auto-picks the session with the most recent lap
-- timestamp, so during a real session window this is near-live (within
-- ~2 minutes of the 1-min OpenF1 poller cadence + Looker refresh) and
-- off-season it shows the most recently completed race. The
-- `is_live_proxy` column lets the dashboard distinguish the two.
--
-- One row per driver in the latest session.

with latest_session as (
    select session_key
    from {{ ref('fct_lap') }}
    group by 1
    order by max(lap_started_at) desc, session_key desc
    limit 1
),

latest_lap_per_driver as (
    select
        l.session_key,
        l.driver_number,
        max(l.lap_number)       as latest_lap_number,
        max(l.lap_started_at)   as latest_lap_started_at
    from {{ ref('fct_lap') }} l
    where l.session_key = (select session_key from latest_session)
    group by 1, 2
),

current_stint as (
    select
        s.session_key,
        s.driver_number,
        s.compound,
        s.stint_number,
        s.lap_start as stint_lap_start,
        s.lap_end   as stint_lap_end
    from {{ ref('stg_openf1__stints') }} s
    join latest_lap_per_driver d
      on d.session_key = s.session_key
     and d.driver_number = s.driver_number
     and d.latest_lap_number between s.lap_start and s.lap_end
    qualify row_number() over (
        partition by s.session_key, s.driver_number
        order by s.stint_number desc
    ) = 1
),

last_5_laps as (
    select
        session_key,
        driver_number,
        avg(lap_time_ms) as last_5_laps_avg_ms
    from (
        select
            l.session_key,
            l.driver_number,
            l.lap_time_ms,
            row_number() over (
                partition by l.session_key, l.driver_number
                order by l.lap_number desc
            ) as rn
        from {{ ref('fct_lap') }} l
        where l.session_key = (select session_key from latest_session)
    )
    where rn <= 5
    group by 1, 2
)

select
    d.session_key,
    {{ session_label('d.session_key') }}     as session_label,
    d.driver_number,
    {{ driver_label('d.driver_number') }}    as driver_label,
    d.latest_lap_number,
    d.latest_lap_started_at,
    cs.compound,
    cs.stint_number                          as current_stint,
    d.latest_lap_number - cs.stint_lap_start + 1 as tire_age_laps,
    l5.last_5_laps_avg_ms,
    p.pace_ratio,
    timestamp_diff(current_timestamp(), d.latest_lap_started_at, minute) < 120 as is_live_proxy
from latest_lap_per_driver d
left join current_stint cs
       on cs.session_key   = d.session_key
      and cs.driver_number = d.driver_number
left join last_5_laps l5
       on l5.session_key   = d.session_key
      and l5.driver_number = d.driver_number
left join {{ ref('fct_driver_pace') }} p
       on p.session_key    = d.session_key
      and p.driver_number  = d.driver_number
