-- =====================================================================
--  auth_v2.sql — run AFTER schema.sql in Supabase → SQL Editor
--
--  Upgrades the auth RPCs to support the finalized Login / Signup screens:
--   * register_student now takes Full Name, and email is optional
--     (the user may type either a Student ID or an INTI email).
--   * login accepts an email OR a Student ID (unified student/admin login).
--   * Every failure raises a stable error CODE so the app can show the
--     right inline message under the right field:
--
--     INT01  Student ID not found in INTI eligibility roster.
--     INT02  Student record inactive
--     INT03  Account already registered. Please log in.
--     INT04  Email does not match the roster record
--     INT05  Password length invalid (8–72 chars; bcrypt ignores bytes > 72)
--     INT06  Full name missing / invalid
--     INT10  Account does not exist.
--     INT11  Incorrect password.
--     INT12  Student record inactive (at login)
--
--  Note: separate "does not exist" / "incorrect password" messages were
--  requested for usability. They do reveal whether an account exists; that is
--  an accepted trade-off here because the roster IDs are not secret anyway.
-- =====================================================================

-- Parameter names change, so the old versions must be dropped first.
drop function if exists public.login(text, text);
drop function if exists public.register_student(text, text, text);

-- ---------------------------------------------------------------------
-- register_student  (POST /rest/v1/rpc/register_student)
-- ---------------------------------------------------------------------
create or replace function public.register_student(
    p_full_name  text,
    p_student_id text,
    p_password   text,
    p_email      text default null
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_name   text := nullif(regexp_replace(trim(coalesce(p_full_name, '')), '\s+', ' ', 'g'), '');
    v_roster public.inti_roster;
    v_user   public.users;
begin
    if v_name is null or length(v_name) < 2 or length(v_name) > 100 then
        raise exception 'Please enter your full name.' using errcode = 'INT06';
    end if;

    select * into v_roster
    from public.inti_roster
    where student_id = upper(trim(coalesce(p_student_id, '')));

    if v_roster.id is null then
        raise exception 'Student ID not found in INTI eligibility roster.' using errcode = 'INT01';
    end if;

    if not v_roster.is_active then
        raise exception 'This student record is no longer active.' using errcode = 'INT02';
    end if;

    if p_email is not null and lower(trim(p_email)) <> lower(v_roster.inti_email) then
        raise exception 'Email does not match the INTI record for this Student ID.' using errcode = 'INT04';
    end if;

    if length(coalesce(p_password, '')) < 8 or octet_length(p_password) > 72 then
        raise exception 'Password must be 8 to 72 characters.' using errcode = 'INT05';
    end if;

    if exists (
        select 1 from public.users
        where student_id = v_roster.student_id
           or lower(email) = lower(v_roster.inti_email)
    ) then
        raise exception 'Account already registered. Please log in.' using errcode = 'INT03';
    end if;

    begin
        insert into public.users (student_id, name, email, password_hash, role)
        values (v_roster.student_id, v_name, lower(v_roster.inti_email),
                crypt(p_password, gen_salt('bf', 10)), 'student')
        returning * into v_user;
    exception when unique_violation then
        -- two signups racing for the same ID
        raise exception 'Account already registered. Please log in.' using errcode = 'INT03';
    end;

    return json_build_object(
        'id', v_user.id, 'student_id', v_user.student_id, 'name', v_user.name,
        'email', v_user.email, 'role', v_user.role, 'created_at', v_user.created_at
    );
end;
$$;

-- ---------------------------------------------------------------------
-- login  (POST /rest/v1/rpc/login) — email OR Student ID
-- ---------------------------------------------------------------------
create or replace function public.login(p_identifier text, p_password text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_ident text := trim(coalesce(p_identifier, ''));
    v_user  public.users;
    v_token text;
begin
    select * into v_user
    from public.users
    where lower(email) = lower(v_ident)
       or student_id   = upper(v_ident)
    limit 1;

    if v_user.id is null then
        raise exception 'Account does not exist.' using errcode = 'INT10';
    end if;

    if v_user.password_hash <> crypt(coalesce(p_password, ''), v_user.password_hash) then
        raise exception 'Incorrect password.' using errcode = 'INT11';
    end if;

    if v_user.role = 'student' and not exists (
        select 1 from public.inti_roster r
        where r.student_id = v_user.student_id and r.is_active
    ) then
        raise exception 'This student record is no longer active.' using errcode = 'INT12';
    end if;

    delete from public.user_sessions where user_id = v_user.id and expires_at <= now();

    v_token := encode(gen_random_bytes(32), 'hex');
    insert into public.user_sessions (token_hash, user_id)
    values (encode(digest(v_token, 'sha256'), 'hex'), v_user.id);

    return json_build_object(
        'token', v_token,
        'expires_at', now() + interval '7 days',
        'user', json_build_object(
            'id', v_user.id, 'student_id', v_user.student_id, 'name', v_user.name,
            'email', v_user.email, 'role', v_user.role, 'created_at', v_user.created_at
        )
    );
end;
$$;

-- New functions are executable by PUBLIC by default — lock down, then grant.
revoke execute on function public.register_student(text, text, text, text) from public, anon, authenticated;
revoke execute on function public.login(text, text)                         from public, anon, authenticated;

grant execute on function public.register_student(text, text, text, text) to anon;
grant execute on function public.login(text, text)                         to anon;

notify pgrst, 'reload schema';
