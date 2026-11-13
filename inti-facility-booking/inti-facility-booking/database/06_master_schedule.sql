-- =====================================================================
--  master_schedule.sql — run in Supabase → SQL Editor (after bookings.sql)
--
--  get_master_schedule: every confirmed booking from today up to 14 days
--  ahead, across all facilities, for any logged-in student.
--
--  Privacy: the join to `users` happens HERE, inside the database, and
--  only the FIRST NAME leaves it. Full names, emails and student IDs are
--  never sent to the app (they stay for the admin panel only).
--  Safe to re-run.
-- =====================================================================

create or replace function public.get_master_schedule(p_token text)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_user  public.users := public.app_require_role(p_token, null);
    v_today date         := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
    return coalesce((
        select json_agg(t order by t.booking_date, t.start_hour, t.facility_type, t.unit_name)
          from (
              select b.booking_ref,
                     b.facility_type,
                     b.unit_name,
                     b.booking_date,
                     min(extract(hour from b.start_time))::int as start_hour,
                     max(extract(hour from b.end_time))::int   as end_hour,
                     -- "Nur Aisyah binti Rahman" → "Nur"
                     split_part(regexp_replace(trim(u.name), '\s+', ' ', 'g'), ' ', 1)
                                                               as first_name,
                     bool_or(b.user_id = v_user.id)            as is_mine
                from public.bookings b
                join public.users u on u.id = b.user_id
               where b.status = 'confirmed'
                 and b.booking_date between v_today and v_today + 14
               group by b.booking_ref, b.facility_type, b.unit_name,
                        b.booking_date, u.name
          ) as t
    ), '[]'::json);
end;
$$;

revoke execute on function public.get_master_schedule(text) from public, anon, authenticated;
grant  execute on function public.get_master_schedule(text) to anon;

notify pgrst, 'reload schema';
