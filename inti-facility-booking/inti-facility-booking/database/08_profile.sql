-- =====================================================================
--  profile.sql — run in Supabase → SQL Editor (after schema.sql)
--
--  Adds a nickname (display_name) and a "my profile" update function.
--    - users.name (the official name) is never changed by these functions.
--    - Password changes need the current password (checked with bcrypt
--      inside the database) and sign out the student's OTHER devices.
--  Safe to re-run.
-- =====================================================================

alter table public.users add column if not exists display_name text;

-- Nickname: 1-30 characters, or null for "use my first name".
do $$
begin
    if not exists (
        select 1 from pg_constraint where conname = 'users_display_name_length'
    ) then
        alter table public.users
            add constraint users_display_name_length
            check (display_name is null or char_length(display_name) between 1 and 30);
    end if;
end $$;

-- ---------------------------------------------------------------------
-- me(): now also returns display_name, so the dashboard greeting can use it
-- ---------------------------------------------------------------------
create or replace function public.me(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_user public.users := public.app_require_role(p_token, null);
begin
    return json_build_object(
        'id', v_user.id, 'student_id', v_user.student_id, 'name', v_user.name,
        'display_name', v_user.display_name,
        'email', v_user.email, 'role', v_user.role, 'created_at', v_user.created_at
    );
end;
$$;

-- ---------------------------------------------------------------------
-- update_my_profile()
--   p_display_name   new nickname; '' or null clears it
--   p_current_password / p_new_password   both null = don't change password
--   Error codes: INT40 nickname too long · INT41 current password wrong
--                INT42 same as current · INT05 new password length
-- ---------------------------------------------------------------------
create or replace function public.update_my_profile(
    p_token            text,
    p_display_name     text,
    p_current_password text default null,
    p_new_password     text default null
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_user public.users := public.app_require_role(p_token, null);
    v_nick text := nullif(regexp_replace(trim(coalesce(p_display_name, '')), '\s+', ' ', 'g'), '');
    v_change_password boolean := coalesce(p_new_password, '') <> '';
begin
    if v_nick is not null and char_length(v_nick) > 30 then
        raise exception 'Nickname must be 30 characters or fewer.' using errcode = 'INT40';
    end if;

    if v_change_password then
        if v_user.password_hash <> crypt(coalesce(p_current_password, ''), v_user.password_hash) then
            raise exception 'Current password is incorrect.' using errcode = 'INT41';
        end if;
        if length(p_new_password) < 8 or octet_length(p_new_password) > 72 then
            raise exception 'Password must be 8 to 72 characters.' using errcode = 'INT05';
        end if;
        if p_new_password = p_current_password then
            raise exception 'New password must be different from your current password.'
                using errcode = 'INT42';
        end if;

        update public.users
           set password_hash = crypt(p_new_password, gen_salt('bf', 10))
         where id = v_user.id;

        -- Keep this phone signed in; sign out everywhere else.
        delete from public.user_sessions
         where user_id = v_user.id
           and token_hash <> encode(digest(p_token, 'sha256'), 'hex');
    end if;

    -- Only the nickname column is touched here: never `name`.
    update public.users
       set display_name = v_nick
     where id = v_user.id
    returning * into v_user;

    return json_build_object(
        'id', v_user.id, 'student_id', v_user.student_id, 'name', v_user.name,
        'display_name', v_user.display_name,
        'email', v_user.email, 'role', v_user.role, 'created_at', v_user.created_at,
        'password_changed', v_change_password
    );
end;
$$;

revoke execute on function public.me(text)                                  from public, anon, authenticated;
revoke execute on function public.update_my_profile(text, text, text, text) from public, anon, authenticated;
grant  execute on function public.me(text)                                  to anon;
grant  execute on function public.update_my_profile(text, text, text, text) to anon;

notify pgrst, 'reload schema';
