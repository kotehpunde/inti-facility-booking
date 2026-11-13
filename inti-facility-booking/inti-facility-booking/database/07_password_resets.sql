-- =====================================================================
--  password_resets.sql — run in Supabase → SQL Editor (after schema.sql
--  and auth_v2.sql)
--
--  "Digital admin ticket" password reset:
--    1. Student:  request_password_reset(student_id, email)  → ticket R-1234
--    2. Admin:    checks the student's ID card at the counter, then
--                 admin_approve_reset(...) → one-time passcode, e.g. K7P3QX
--    3. Student:  complete_password_reset(ticket, student_id, passcode, new pw)
--
--  Security:
--    - Same model as the rest of the app: the table is locked; only these
--      SECURITY DEFINER functions can read or change it.
--    - The passcode is stored only as a bcrypt hash (like a password).
--      The admin sees it once, when approving.
--    - Passcode: 6 random characters from 31 easy-to-read symbols
--      (~887 million combinations), valid for 60 minutes, max 5 wrong tries.
--    - A successful reset logs the student out on every device.
--  Safe to re-run.
-- =====================================================================

create table if not exists public.password_resets (
    id               uuid        primary key default gen_random_uuid(),
    ticket_no        text        not null check (ticket_no ~ '^R-[0-9]{4}$'),
    user_id          uuid        not null references public.users (id) on delete cascade,
    status           text        not null default 'pending'
                     check (status in ('pending', 'approved', 'rejected', 'completed', 'expired')),
    passcode_hash    text,                     -- bcrypt hash of the temporary passcode
    failed_attempts  int         not null default 0,
    requested_at     timestamptz not null default now(),
    approved_at      timestamptz,
    approved_by      uuid        references public.users (id),
    expires_at       timestamptz,              -- set on approval (60 minutes)
    rejected_at      timestamptz,
    completed_at     timestamptz
);

-- One open ticket number at a time, and one open ticket per student.
create unique index if not exists password_resets_open_ticket_no
    on public.password_resets (ticket_no) where status in ('pending', 'approved');
create unique index if not exists password_resets_one_open_per_user
    on public.password_resets (user_id) where status in ('pending', 'approved');

alter table public.password_resets enable row level security;
revoke all on public.password_resets from anon, authenticated;
-- No policies: only the functions below can touch this table.

-- ---------------------------------------------------------------------
-- Helper: close tickets that have run out of time
--   approved → expired after 60 min; pending → expired after 7 days
-- ---------------------------------------------------------------------
create or replace function public.expire_old_reset_tickets()
returns void
language sql
security definer
set search_path = public
as $$
    update public.password_resets
       set status = 'expired'
     where (status = 'approved' and expires_at <= now())
        or (status = 'pending'  and requested_at < now() - interval '7 days');
$$;

-- ---------------------------------------------------------------------
-- 1. Student: request a ticket  (no login needed)
--    Error codes: INT30 no account · INT31 email mismatch · INT32 inactive
-- ---------------------------------------------------------------------
create or replace function public.request_password_reset(p_student_id text, p_email text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_user   public.users;
    v_active boolean;
    v_ticket text;
    v_status text;
    v_try    int := 0;
begin
    select u.* into v_user
      from public.users u
     where u.student_id = upper(trim(coalesce(p_student_id, '')))
       and u.role = 'student';

    select r.is_active into v_active
      from public.inti_roster r
     where r.student_id = v_user.student_id;

    if v_user.id is null then
        raise exception 'No account found for this Student ID. Please sign up first.'
            using errcode = 'INT30';
    end if;
    if lower(trim(coalesce(p_email, ''))) <> lower(v_user.email) then
        raise exception 'Email does not match the INTI record for this Student ID.'
            using errcode = 'INT31';
    end if;
    if not v_active then
        raise exception 'This student record is no longer active.' using errcode = 'INT32';
    end if;

    perform public.expire_old_reset_tickets();

    -- Already has an open ticket? Give back the same one (no duplicates).
    select ticket_no, status into v_ticket, v_status
      from public.password_resets
     where user_id = v_user.id and status in ('pending', 'approved');
    if v_ticket is not null then
        return json_build_object('ticket_no', v_ticket, 'status', v_status,
                                 'already_open', true);
    end if;

    -- New ticket "R-" + 4 random digits; retry if the number is in use.
    loop
        v_try := v_try + 1;
        v_ticket := 'R-' || lpad((floor(random() * 10000))::int::text, 4, '0');
        begin
            insert into public.password_resets (ticket_no, user_id)
            values (v_ticket, v_user.id);
            exit;
        exception when unique_violation then
            if v_try >= 30 then
                raise exception 'Could not create a ticket right now. Please try again.'
                    using errcode = 'INT39';
            end if;
        end;
    end loop;

    return json_build_object('ticket_no', v_ticket, 'status', 'pending',
                             'already_open', false);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Student: set a new password with ticket + passcode  (no login needed)
--    Wrong passcode is RETURNED (not raised) so the failed-attempt count
--    is saved: {"ok": false, "code": "INT33", "attempts_left": 3, ...}
--    Raised codes: INT34 not found · INT35 not approved yet · INT36 expired
--                  INT37 locked · INT05 password length
-- ---------------------------------------------------------------------
create or replace function public.complete_password_reset(
    p_ticket_no     text,
    p_student_id    text,
    p_passcode      text,
    p_new_password  text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    c_max_attempts constant int := 5;
    v_reset public.password_resets;
begin
    perform public.expire_old_reset_tickets();

    select pr.* into v_reset
      from public.password_resets pr
      join public.users u on u.id = pr.user_id
     where pr.ticket_no = upper(trim(coalesce(p_ticket_no, '')))
       and u.student_id = upper(trim(coalesce(p_student_id, '')))
     order by pr.requested_at desc
     limit 1;

    if v_reset.id is null then
        raise exception 'Ticket not found for this Student ID. Check both and try again.'
            using errcode = 'INT34';
    end if;
    if v_reset.status = 'pending' then
        raise exception 'This ticket has not been approved yet. Please visit the admin counter.'
            using errcode = 'INT35';
    end if;
    if v_reset.status = 'expired' and v_reset.failed_attempts >= c_max_attempts then
        raise exception 'Too many wrong passcodes. Please request a new ticket.'
            using errcode = 'INT37';
    end if;
    if v_reset.status <> 'approved' then
        raise exception 'This ticket is no longer valid (%). Please request a new one.', v_reset.status
            using errcode = 'INT36';
    end if;

    if length(coalesce(p_new_password, '')) < 8 or octet_length(p_new_password) > 72 then
        raise exception 'Password must be 8 to 72 characters.' using errcode = 'INT05';
    end if;

    -- Wrong passcode: count it, lock after 5, and RETURN so it is saved.
    if v_reset.passcode_hash <> crypt(upper(trim(coalesce(p_passcode, ''))), v_reset.passcode_hash) then
        update public.password_resets
           set failed_attempts = failed_attempts + 1,
               status = case when failed_attempts + 1 >= c_max_attempts
                             then 'expired' else status end
         where id = v_reset.id;
        return json_build_object(
            'ok', false,
            'code', case when v_reset.failed_attempts + 1 >= c_max_attempts
                         then 'INT37' else 'INT33' end,
            'message', case when v_reset.failed_attempts + 1 >= c_max_attempts
                            then 'Too many wrong passcodes. Please request a new ticket.'
                            else 'Incorrect temporary passcode.' end,
            'attempts_left', greatest(0, c_max_attempts - v_reset.failed_attempts - 1)
        );
    end if;

    -- Correct: set the new password (bcrypt), close the ticket, sign out everywhere.
    update public.users
       set password_hash = crypt(p_new_password, gen_salt('bf', 10))
     where id = v_reset.user_id;

    update public.password_resets
       set status = 'completed', completed_at = now()
     where id = v_reset.id;

    delete from public.user_sessions where user_id = v_reset.user_id;

    return json_build_object('ok', true,
        'student_id', upper(trim(p_student_id)));
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Admin: list open tickets  (admin token required)
-- ---------------------------------------------------------------------
create or replace function public.admin_list_reset_tickets(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    perform public.app_require_role(p_token, 'admin');
    perform public.expire_old_reset_tickets();

    return coalesce((
        select json_agg(t order by t.status desc, t.requested_at)   -- pending first
          from (
              select pr.id, pr.ticket_no, pr.status, pr.requested_at, pr.expires_at,
                     u.student_id, u.email, u.name
                from public.password_resets pr
                join public.users u on u.id = pr.user_id
               where pr.status in ('pending', 'approved')
          ) as t
    ), '[]'::json);
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Admin: approve → returns the passcode ONCE (only its hash is stored).
--    Also used for "New code" on an already-approved ticket.
-- ---------------------------------------------------------------------
create or replace function public.admin_approve_reset(p_token text, p_ticket_id uuid)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_admin    public.users := public.app_require_role(p_token, 'admin');
    v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';  -- no 0/O, 1/I/L
    v_bytes    bytea := gen_random_bytes(6);
    v_code     text := '';
    v_expires  timestamptz := now() + interval '60 minutes';
    v_ticket   text;
begin
    perform public.expire_old_reset_tickets();

    for i in 0..5 loop
        v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, i) % length(v_alphabet)) + 1, 1);
    end loop;

    update public.password_resets
       set status = 'approved',
           passcode_hash = crypt(v_code, gen_salt('bf', 8)),
           failed_attempts = 0,
           approved_at = now(),
           approved_by = v_admin.id,
           expires_at = v_expires
     where id = p_ticket_id
       and status in ('pending', 'approved')
    returning ticket_no into v_ticket;

    if v_ticket is null then
        raise exception 'This ticket is no longer open.' using errcode = 'INT38';
    end if;

    return json_build_object('ticket_no', v_ticket, 'passcode', v_code,
                             'expires_at', v_expires);
end;
$$;

create or replace function public.admin_reject_reset(p_token text, p_ticket_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    perform public.app_require_role(p_token, 'admin');

    update public.password_resets
       set status = 'rejected', rejected_at = now(), passcode_hash = null
     where id = p_ticket_id
       and status in ('pending', 'approved');

    if not found then
        raise exception 'This ticket is no longer open.' using errcode = 'INT38';
    end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
revoke execute on function public.expire_old_reset_tickets()                       from public, anon, authenticated;
revoke execute on function public.request_password_reset(text, text)               from public, anon, authenticated;
revoke execute on function public.complete_password_reset(text, text, text, text)  from public, anon, authenticated;
revoke execute on function public.admin_list_reset_tickets(text)                   from public, anon, authenticated;
revoke execute on function public.admin_approve_reset(text, uuid)                  from public, anon, authenticated;
revoke execute on function public.admin_reject_reset(text, uuid)                   from public, anon, authenticated;

grant execute on function public.request_password_reset(text, text)                to anon;
grant execute on function public.complete_password_reset(text, text, text, text)   to anon;
grant execute on function public.admin_list_reset_tickets(text)                    to anon;  -- checks admin token inside
grant execute on function public.admin_approve_reset(text, uuid)                   to anon;  -- checks admin token inside
grant execute on function public.admin_reject_reset(text, uuid)                    to anon;  -- checks admin token inside

notify pgrst, 'reload schema';
