-- =====================================================================
--  my_bookings.sql — run in Supabase → SQL Editor (after bookings.sql)
--
--  get_my_bookings   the logged-in student's bookings, one row per booking
--                    (a 2-hour booking's two slots are merged into one)
--  cancel_booking    updated: cancels the WHOLE booking, and only if its
--                    first hour hasn't started yet
--  Safe to re-run.
-- =====================================================================

create or replace function public.get_my_bookings(p_token text)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_user public.users := public.app_require_role(p_token, null);
begin
    return coalesce((
        select json_agg(t order by t.booking_date desc, t.start_hour desc)
          from (
              select booking_ref,
                     facility_type,
                     unit_name,
                     booking_date,
                     min(extract(hour from start_time))::int as start_hour,
                     max(extract(hour from end_time))::int   as end_hour,
                     case when bool_or(status = 'confirmed')
                          then 'confirmed' else 'cancelled' end as status,
                     min(created_at)                          as created_at
                from public.bookings
               where user_id = v_user.id
                 -- keep the list short: everything upcoming + last 60 days
                 and booking_date >= (now() at time zone 'Asia/Kuala_Lumpur')::date - 60
               group by booking_ref, facility_type, unit_name, booking_date
          ) as t
    ), '[]'::json);
end;
$$;

create or replace function public.cancel_booking(p_token text, p_booking_ref uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_user  public.users := public.app_require_role(p_token, null);
    v_now   timestamp    := now() at time zone 'Asia/Kuala_Lumpur';
    v_start timestamp;
begin
    select min(booking_date + start_time)
      into v_start
      from public.bookings
     where booking_ref = p_booking_ref
       and user_id = v_user.id
       and status = 'confirmed';

    if v_start is null then
        raise exception 'This booking was not found or is already cancelled.'
            using errcode = 'INT24';
    end if;
    if v_start <= v_now then
        raise exception 'This booking has already started and can no longer be cancelled.'
            using errcode = 'INT24';
    end if;

    update public.bookings
       set status = 'cancelled', cancelled_at = now()
     where booking_ref = p_booking_ref
       and user_id = v_user.id
       and status = 'confirmed';
end;
$$;

revoke execute on function public.get_my_bookings(text)       from public, anon, authenticated;
revoke execute on function public.cancel_booking(text, uuid)  from public, anon, authenticated;
grant  execute on function public.get_my_bookings(text)       to anon;
grant  execute on function public.cancel_booking(text, uuid)  to anon;

notify pgrst, 'reload schema';
