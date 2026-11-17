-- Token for the Framer form webhook (lead-intake). The value itself is set directly in the database, not in git.
create table if not exists private.settings (key text primary key, value text not null);
create or replace function public.service_setting(p_key text) returns text language sql stable security definer set search_path = '' as $$
  select value from private.settings where key = p_key;
$$;
revoke all on function public.service_setting(text) from public, anon, authenticated;
grant execute on function public.service_setting(text) to service_role;
