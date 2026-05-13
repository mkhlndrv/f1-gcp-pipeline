{{ config(materialized='view') }}

-- Dashboard-facing view for the optional Tier-3 pace-by-compound page.
-- Flat row per (session, driver, compound) with display labels via the
-- driver_label / session_label macros.

select
    p.session_key,
    {{ session_label('p.session_key') }}     as session_label,
    p.driver_number,
    {{ driver_label('p.driver_number') }}    as driver_label,
    p.compound,
    p.clean_air_laps,
    p.median_corrected_ms,
    p.median_corrected_s,
    p.pace_ratio
from {{ ref('fct_clean_air_pace') }} p
