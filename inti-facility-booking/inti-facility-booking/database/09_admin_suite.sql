-- =====================================================================
--  admin_suite.sql — run in Supabase → SQL Editor
--  (after schema.sql, facilities.sql, bookings.sql, password_resets.sql)
--
--  Adds everything the Admin Console needs:
--    1. bookings: new status 'admin_cancelled' (+ who/why)
--    2. facilities.facility_type + is_active (maintenance switches)
--       and a trigger that blocks bookings on closed facilities/units
--    3. announcements table (students can read active ones)
--    4. Admin-only functions: stats, bookings, force-cancel,
--       announcements, maintenance
--
--  Every admin_* function starts with app_require_role(token, 'admin'),
--  so a student (or anyone with the public anon key) gets "Forbidden".
--  Safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Bookings: allow 'admin_cancelled'
-- ---------------------------------------------------------------------
alter table public.bookings drop constraint if exists bookings_status_check;
alter table public.bookings
    add constraint bookings_status_check
    check (status in ('confirmed', 'cancelled', 'admin_cancelled'));

alter table public.bookings add column if not exists cancelled_by  uuid references public.users (id);
alter table public.bookings add column if not exists cancel_reason text;

-- ---------------------------------------------------------------------
-- 2. Facilities: link to bookings.facility_type + maintenance switch
-- ---------------------------------------------------------------------
alter table public.facilities add column if not exists is_active boolean not null default true;
alter table public.facilities add column if not exists facility_type text;

update public.facilities set facility_type = 'music'   where id = 'music_room';
update public.facilities set facility_type = 'pool'    where id = 'pool_table';
update public.facilities set facility_type = 'library' where id = 'library_room';

-- Students can now SEE closed facilities/units (shown as "Closed for
-- maintenance") instead of them silently disappearing. Still read-only.
drop policy if exists "App can view active facilities" on public.facilities;
drop policy if exists "App can view facilities" on public.facilities;
create policy "App can view facilities"
    on public.facilities for select to anon, authenticated using (true);

drop policy if exists "App can view active units" on public.facility_units;
drop policy if exists "App can view units" on public.facility_units;
create policy "App can view units"
    on public.facility_units for select to anon, authenticated using (true);

-- Block new bookings on anything closed for maintenance.
create or replace function public.enforce_facility_open()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    if exists (select 1 from public.facilities
                where facility_type = new.facility_type and not is_active) then
        raise exception 'This facility is closed for maintenance.' using errcode = 'INT25';
    end if;
    if exists (select 1 from public.facility_units
                where facility_type = new.facility_type
                  and unit_name = new.unit_name
                  and not is_active) then
        raise exception 'This room or table is closed for maintenance.' using errcode = 'INT25';
    end if;
    return new;
end;
$$;

drop trigger if exists bookings_facility_open on public.bookings;
create trigger bookings_facility_open
    before insert on public.bookings
    for each row execute function public.enforce_facility_open();

-- ---------------------------------------------------------------------
-- 3. Announcements
-- ---------------------------------------------------------------------
create table if not exists public.announcements (
    id            uuid        primary key default gen_random_uuid(),
    facility_type text        check (facility_type in ('music', 'pool', 'library')),  -- null = all
    headline      text        not null check (char_length(headline) between 3 and 80),
    body          text        not null check (char_length(body) between 3 and 300),
    is_active     boolean     not null default true,
    created_by    uuid        references public.users (id),
    created_at    timestamptz not null default now()
);

alter table public.announcements enable row level security;
revoke all on public.announcements from anon, authenticated;
grant select on public.announcements to anon, authenticated;

drop policy if exists "App can view active announcements" on public.announcements;
create policy "App can view active announcements"
    on public.announcements for select to anon, authenticated using (is_active);

-- ---------------------------------------------------------------------
-- 4a. Admin: dashboard numbers
--     bookings_today · pending_resets · closed_facilities
--     weekly: bookings per day, Monday → Sunday of this week
-- ---------------------------------------------------------------------
create or replace function public.admin_dashboard_stats(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
    v_monday date;
begin
    perform public.app_require_role(p_token, 'admin');
    v_monday := v_today - (extract(isodow from v_today)::int - 1);

    return json_build_object(
        'today', v_today,
        'week_start', v_monday,
        'bookings_today', (
            select count(distinct booking_ref) from public.bookings
             where booking_date = v_today and status = 'confirmed'),
        'pending_resets', (
            select count(*) from public.password_resets where status = 'pending'),
        'closed_facilities', (
            (select count(*) from public.facilities where not is_active)
          + (select count(*) from public.facility_units where not is_active)),
        'active_announcements', (
            select count(*) from public.announcements where is_active),
        'weekly', (
            select json_agg(coalesce(c.n, 0) order by d.day)
              from generate_series(v_monday, v_monday + 6, interval '1 day') as d(day)
              left join (
                  select booking_date, count(distinct booking_ref)::int as n
                    from public.bookings
                   where status = 'confirmed'
                     and booking_date between v_monday and v_monday + 6
                   group by booking_date
              ) c on c.booking_date = d.day::date)
    );
end;
$$;

-- ---------------------------------------------------------------------
-- 4b. Admin: bookings with full student details
--     p_scope: 'today' | 'upcoming' | 'cancelled'
-- ---------------------------------------------------------------------
create or replace function public.admin_list_bookings(p_token text, p_scope text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
    perform public.app_require_role(p_token, 'admin');

    return coalesce((
        select json_agg(t order by t.booking_date, t.start_hour, t.facility_type, t.unit_name)
          from (
              select b.booking_ref, b.facility_type, b.unit_name, b.booking_date,
                     min(extract(hour from b.start_time))::int as start_hour,
                     max(extract(hour from b.end_time))::int   as end_hour,
                     max(b.status)                             as status,
                     max(b.cancel_reason)                      as cancel_reason,
                     u.name as full_name, u.student_id, u.email
                from public.bookings b
                join public.users u on u.id = b.user_id
               where case p_scope
                       when 'today'     then b.booking_date = v_today
                                         and b.status = 'confirmed'
                       when 'upcoming'  then b.booking_date > v_today
                                         and b.status = 'confirmed'
                       when 'cancelled' then b.booking_date >= v_today - 30
                                         and b.status in ('cancelled', 'admin_cancelled')
                       else false
                     end
               group by b.booking_ref, b.facility_type, b.unit_name, b.booking_date,
                        u.name, u.student_id, u.email
          ) as t
    ), '[]'::json);
end;
$$;

-- ---------------------------------------------------------------------
-- 4c. Admin: force-cancel (frees the slot immediately)
--     Cancels every hour of the booking that hasn't finished yet.
-- ---------------------------------------------------------------------
create or replace function public.admin_force_cancel(
    p_token       text,
    p_booking_ref uuid,
    p_reason      text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_admin public.users := public.app_require_role(p_token, 'admin');
    v_now   timestamp    := now() at time zone 'Asia/Kuala_Lumpur';
begin
    update public.bookings
       set status = 'admin_cancelled',
           cancelled_at = now(),
           cancelled_by = v_admin.id,
           cancel_reason = nullif(trim(coalesce(p_reason, '')), '')
     where booking_ref = p_booking_ref
       and status = 'confirmed'
       and (booking_date + end_time) > v_now;

    if not found then
        raise exception 'This booking has already ended or was already cancelled.'
            using errcode = 'INT24';
    end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 4d. Admin: announcements
-- ---------------------------------------------------------------------
create or replace function public.admin_list_announcements(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    perform public.app_require_role(p_token, 'admin');
    return coalesce((
        select json_agg(a order by a.created_at desc)
          from (select id, facility_type, headline, body, is_active, created_at
                  from public.announcements) a
    ), '[]'::json);
end;
$$;

create or replace function public.admin_create_announcement(
    p_token         text,
    p_facility_type text,
    p_headline      text,
    p_body          text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_admin public.users := public.app_require_role(p_token, 'admin');
    v_row   public.announcements;
begin
    if char_length(trim(coalesce(p_headline, ''))) not between 3 and 80 then
        raise exception 'Headline must be 3 to 80 characters.' using errcode = 'INT50';
    end if;
    if char_length(trim(coalesce(p_body, ''))) not between 3 and 300 then
        raise exception 'Description must be 3 to 300 characters.' using errcode = 'INT51';
    end if;

    insert into public.announcements (facility_type, headline, body, created_by)
    values (nullif(p_facility_type, ''), trim(p_headline), trim(p_body), v_admin.id)
    returning * into v_row;

    return json_build_object('id', v_row.id, 'facility_type', v_row.facility_type,
        'headline', v_row.headline, 'body', v_row.body,
        'is_active', v_row.is_active, 'created_at', v_row.created_at);
end;
$$;

create or replace function public.admin_set_announcement_active(
    p_token text, p_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    perform public.app_require_role(p_token, 'admin');
    update public.announcements set is_active = p_active where id = p_id;
end;
$$;

create or replace function public.admin_delete_announcement(p_token text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    perform public.app_require_role(p_token, 'admin');
    delete from public.announcements where id = p_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 4e. Admin: maintenance switches
-- ---------------------------------------------------------------------
create or replace function public.admin_list_facilities(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
    perform public.app_require_role(p_token, 'admin');
    return coalesce((
        select json_agg(json_build_object(
                   'id', f.id,
                   'name', f.name,
                   'facility_type', f.facility_type,
                   'is_active', f.is_active,
                   'upcoming_bookings', (
                       select count(distinct b.booking_ref) from public.bookings b
                        where b.facility_type = f.facility_type
                          and b.status = 'confirmed'
                          and b.booking_date >= v_today),
                   'units', (
                       select coalesce(json_agg(json_build_object(
                                  'unit_name', u.unit_name,
                                  'capacity', u.capacity,
                                  'is_active', u.is_active)
                                order by u.sort_order), '[]'::json)
                         from public.facility_units u
                        where u.facility_type = f.facility_type))
               order by f.sort_order)
          from public.facilities f
    ), '[]'::json);
end;
$$;

create or replace function public.admin_set_facility_active(
    p_token text, p_facility_id text, p_active boolean)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    perform public.app_require_role(p_token, 'admin');
    update public.facilities set is_active = p_active where id = p_facility_id;
end;
$$;

create or replace function public.admin_set_unit_active(
    p_token text, p_facility_type text, p_unit_name text, p_active boolean)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    perform public.app_require_role(p_token, 'admin');
    update public.facility_units set is_active = p_active
     where facility_type = p_facility_type and unit_name = p_unit_name;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Permissions (the anon key may CALL these; each checks the admin token)
-- ---------------------------------------------------------------------
revoke execute on function public.enforce_facility_open()                                   from public, anon, authenticated;
revoke execute on function public.admin_dashboard_stats(text)                               from public, anon, authenticated;
revoke execute on function public.admin_list_bookings(text, text)                           from public, anon, authenticated;
revoke execute on function public.admin_force_cancel(text, uuid, text)                      from public, anon, authenticated;
revoke execute on function public.admin_list_announcements(text)                            from public, anon, authenticated;
revoke execute on function public.admin_create_announcement(text, text, text, text)         from public, anon, authenticated;
revoke execute on function public.admin_set_announcement_active(text, uuid, boolean)        from public, anon, authenticated;
revoke execute on function public.admin_delete_announcement(text, uuid)                     from public, anon, authenticated;
revoke execute on function public.admin_list_facilities(text)                               from public, anon, authenticated;
revoke execute on function public.admin_set_facility_active(text, text, boolean)            from public, anon, authenticated;
revoke execute on function public.admin_set_unit_active(text, text, text, boolean)          from public, anon, authenticated;

grant execute on function public.admin_dashboard_stats(text)                                to anon;
grant execute on function public.admin_list_bookings(text, text)                            to anon;
grant execute on function public.admin_force_cancel(text, uuid, text)                       to anon;
grant execute on function public.admin_list_announcements(text)                             to anon;
grant execute on function public.admin_create_announcement(text, text, text, text)          to anon;
grant execute on function public.admin_set_announcement_active(text, uuid, boolean)         to anon;
grant execute on function public.admin_delete_announcement(text, uuid)                      to anon;
grant execute on function public.admin_list_facilities(text)                                to anon;
grant execute on function public.admin_set_facility_active(text, text, boolean)             to anon;
grant execute on function public.admin_set_unit_active(text, text, text, boolean)           to anon;

notify pgrst, 'reload schema';
