-- Security hardening
-- 1. Admin needs two-factor (authenticator app): once linked, admin powers only with an aal2 session.
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
     and (coalesce(auth.jwt()->>'aal', 'aal1') = 'aal2'
          -- until the admin has linked an authenticator app (the portal forces this at login), a password session still works
          or not exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified'));
$$;

-- 2. Anonymous visitors never touch tables or functions directly (the public site only posts to lead-intake).
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from anon;
revoke execute on all functions in schema public from public;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke execute on functions from anon;
alter default privileges in schema public revoke execute on functions from public;
-- signed-in users keep execute on the functions the portal calls (each checks who is calling)
grant execute on all functions in schema public to authenticated, service_role;
-- service_* functions are for the backend only
do $$ declare f record; begin
  for f in select p.oid::regprocedure sig from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'service\_%' loop
    execute format('revoke execute on function %s from authenticated', f.sig);
  end loop;
end $$;
-- internal helpers used by other functions only
revoke execute on function public.client_balance(uuid) from authenticated;
revoke execute on function public.charge_order(uuid) from authenticated;
revoke execute on function public.process_waiting_orders(uuid) from authenticated;

-- 3. Rate limits (lead form, payments, store connections)
create table if not exists private.rate_limits (key text not null, at timestamptz not null default now());
create index if not exists rate_limits_key_at on private.rate_limits(key, at desc);
create or replace function public.service_rate_limit(p_key text, p_max int, p_seconds int) returns boolean
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  delete from private.rate_limits where at < now() - interval '2 days';
  select count(*) into n from private.rate_limits where key = p_key and at > now() - make_interval(secs => p_seconds);
  if n >= p_max then return false; end if;
  insert into private.rate_limits(key) values (p_key);
  return true;
end $$;
revoke all on function public.service_rate_limit(text,int,int) from public, anon, authenticated;
grant execute on function public.service_rate_limit(text,int,int) to service_role;

-- caps on what a signed-in store can create (bots or a stolen login can't flood you)
create or replace function private.rate_guard() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or public.is_admin() then return new; end if;
  if not public.service_rate_limit(tg_table_name || ':' || auth.uid()::text, tg_argv[0]::int, tg_argv[1]::int) then
    raise exception 'Too many requests. Try again later or message us.';
  end if;
  return new;
end $$;
create trigger rate_guard before insert on public.payments for each row execute function private.rate_guard('30', '3600');
create trigger rate_guard before insert on public.quotes for each row execute function private.rate_guard('20', '86400');
create trigger rate_guard before insert on public.claims for each row execute function private.rate_guard('20', '86400');
create trigger rate_guard before insert on public.messages for each row execute function private.rate_guard('120', '3600');
