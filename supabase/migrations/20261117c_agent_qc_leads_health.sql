-- Agent portal, QC photos, actual-cost margin check, leads from the Framer form, system health log.
-- No drops: existing statuses/policies stay as they are.

-- ===== agents =====
create table if not exists private.agent_emails (email text primary key);
create table if not exists public.agents (
  user_id uuid primary key references auth.users(id) on delete cascade,
  name text, created_at timestamptz not null default now()
);
alter table public.agents enable row level security;
create policy admin_all on public.agents for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

create or replace function public.is_agent() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.agents a where a.user_id = auth.uid());
$$;
grant execute on function public.is_agent() to authenticated;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare v_client uuid; v_admin boolean; v_agent boolean;
begin
  select exists (select 1 from private.admin_emails a where lower(a.email) = lower(new.email)) into v_admin;
  select exists (select 1 from private.agent_emails a where lower(a.email) = lower(new.email)) into v_agent;
  if v_admin then
    insert into public.profiles (id, email, full_name, role) values (new.id, new.email, new.raw_user_meta_data->>'full_name', 'admin');
  elsif v_agent then
    insert into public.profiles (id, email, full_name, role) values (new.id, new.email, new.raw_user_meta_data->>'full_name', 'client');
    insert into public.agents (user_id, name) values (new.id, coalesce(new.raw_user_meta_data->>'full_name', new.email));
  else
    insert into public.clients (name, contact_email, store_url)
      values (coalesce(nullif(new.raw_user_meta_data->>'company',''), new.email), new.email, nullif(new.raw_user_meta_data->>'store_url',''))
      returning id into v_client;
    insert into public.profiles (id, email, full_name, role, client_id) values (new.id, new.email, new.raw_user_meta_data->>'full_name', 'client', v_client);
  end if;
  return new;
end $function$;

create or replace function public.whoami() returns json language sql stable security definer set search_path = '' as $function$
  select json_build_object('id', p.id, 'email', p.email, 'full_name', p.full_name,
    'role', case when exists (select 1 from public.agents a where a.user_id = p.id) then 'agent' else p.role end,
    'client', (select json_build_object('id', c.id, 'name', c.name, 'store_url', c.store_url, 'whatsapp', c.whatsapp, 'status', c.status)
               from public.clients c where c.id = p.client_id))
  from public.profiles p where p.id = auth.uid();
$function$;

-- admin invites / removes an agent by email
create or replace function public.admin_set_agent(p_email text, p_enabled boolean) returns json
language plpgsql security definer set search_path = '' as $$
declare u uuid; e text := lower(trim(p_email));
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'invalid email'; end if;
  if exists (select 1 from private.admin_emails a where lower(a.email) = e) then raise exception 'that email is an admin'; end if;
  select id into u from auth.users where lower(email) = e;
  if p_enabled then
    insert into private.agent_emails (email) values (e) on conflict do nothing;
    if u is not null then
      if exists (select 1 from public.profiles p where p.id = u and p.client_id is not null
                 and exists (select 1 from public.orders o where o.client_id = p.client_id)) then
        raise exception 'this email belongs to a store with orders; use a separate email for the agent';
      end if;
      insert into public.agents (user_id, name) values (u, e) on conflict do nothing;
    end if;
  else
    delete from private.agent_emails where lower(email) = e;
    if u is not null then delete from public.agents where user_id = u; end if;
  end if;
  return json_build_object('email', e, 'enabled', p_enabled, 'has_account', u is not null);
end $$;
create or replace function public.admin_list_agents() returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return (select coalesce(json_agg(json_build_object('email', ae.email, 'has_account', u.id is not null,
           'last_sign_in', u.last_sign_in_at) order by ae.email), '[]')
          from private.agent_emails ae left join auth.users u on lower(u.email) = lower(ae.email));
end $$;

-- ===== orders: agent fields =====
alter table public.orders
  add column if not exists actual_cost numeric,
  add column if not exists agent_note text,
  add column if not exists agent_flagged_at timestamptz,
  add column if not exists agent_seen_at timestamptz;

create or replace function public.agent_orders(p_days int default 14) returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (public.is_agent() or public.is_admin()) then raise exception 'not allowed'; end if;
  return (select coalesce(json_agg(x order by x.paid_at nulls last), '[]') from (
    select o.id, o.order_number, c.name as store, o.status, o.paid_at, o.created_at, o.shipped_at,
           o.customer_name, o.country, o.shipping_address, o.note,
           o.tracking_number, o.tracking_company, o.tracking_url, o.actual_cost, o.agent_cost as expected_cost,
           o.agent_note, o.agent_flagged_at, o.client_id,
           (select coalesce(json_agg(json_build_object(
              'title', li->>'title', 'variant_title', li->>'variant_title', 'sku', li->>'sku', 'quantity', (li->>'quantity')::int,
              'product_id', pr.id, 'image_url', pr.image_url, 'source_url', pr.source_url, 'notes', pr.notes)), '[]')
            from jsonb_array_elements(o.line_items) li
            left join lateral (select p.* from public.products p where p.client_id = o.client_id
               and ((nullif(li->>'variant_id','') is not null and p.shopify_variant_id = (li->>'variant_id')::bigint)
                 or (nullif(li->>'sku','') is not null and lower(p.sku) = lower(li->>'sku'))
                 or lower(p.name) = lower(li->>'title'))
               order by (p.shopify_variant_id is not null) desc limit 1) pr on true) as items,
           (select count(*) from public.qc_photos q where q.order_id = o.id) as photos
    from public.orders o join public.clients c on c.id = o.client_id
    where o.status in ('paid','sent_to_agent','address_error')
       or (o.status = 'shipped' and o.shipped_at > now() - make_interval(days => p_days))) x);
end $$;

create or replace function public.agent_update_order(p_order uuid, p_action text, p_tracking_number text default null,
  p_tracking_company text default null, p_tracking_url text default null, p_actual_cost numeric default null, p_note text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare o public.orders%rowtype;
begin
  if not (public.is_agent() or public.is_admin()) then raise exception 'not allowed'; end if;
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'order not found'; end if;
  if p_action = 'accept' then
    if o.status <> 'paid' then raise exception 'only paid orders can be accepted (status: %)', o.status; end if;
    update public.orders set status = 'sent_to_agent', agent_seen_at = now() where id = o.id;
  elsif p_action = 'tracking' then
    if o.status not in ('paid','sent_to_agent') then raise exception 'order is %; tracking not allowed', o.status; end if;
    if coalesce(trim(p_tracking_number),'') = '' then raise exception 'tracking number required'; end if;
    update public.orders set tracking_number = trim(p_tracking_number), tracking_company = nullif(trim(p_tracking_company),''),
      tracking_url = nullif(trim(p_tracking_url),''), actual_cost = coalesce(p_actual_cost, actual_cost),
      status = case when status = 'paid' then 'sent_to_agent' else status end where id = o.id;
  elsif p_action = 'cost' then
    update public.orders set actual_cost = p_actual_cost where id = o.id;
  elsif p_action = 'flag' then
    update public.orders set agent_note = nullif(trim(p_note),''), agent_flagged_at = case when nullif(trim(p_note),'') is null then null else now() end where id = o.id;
  else raise exception 'unknown action';
  end if;
  return json_build_object('ok', true);
end $$;

-- ===== QC photos =====
create table if not exists public.qc_photos (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id),
  order_id uuid references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete cascade,
  path text not null unique,
  caption text,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists qc_order_idx on public.qc_photos(order_id);
create index if not exists qc_product_idx on public.qc_photos(product_id);
alter table public.qc_photos enable row level security;
create policy staff_all on public.qc_photos for all to authenticated
  using ((select public.is_admin()) or (select public.is_agent())) with check ((select public.is_admin()) or (select public.is_agent()));
create policy client_read on public.qc_photos for select to authenticated using (client_id = (select public.my_client_id()));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('qc', 'qc', false, 8388608, array['image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do nothing;
-- path: <client_id>/<order or product id>/<file>
create policy qc_staff_write on storage.objects for insert to authenticated
  with check (bucket_id = 'qc' and ((select public.is_admin()) or (select public.is_agent())));
create policy qc_staff_delete on storage.objects for delete to authenticated
  using (bucket_id = 'qc' and ((select public.is_admin()) or (select public.is_agent())));
create policy qc_read on storage.objects for select to authenticated
  using (bucket_id = 'qc' and ((select public.is_admin()) or (select public.is_agent())
         or (storage.foldername(name))[1] = (select public.my_client_id())::text));

-- ===== leads (Framer "free price check" form) =====
create table if not exists public.leads (
  id uuid primary key default gen_random_uuid(),
  email text, store_url text, orders_per_day text, message text,
  raw jsonb, status text not null default 'new' check (status in ('new','contacted','won','lost')),
  created_at timestamptz not null default now()
);
alter table public.leads enable row level security;
create policy admin_all on public.leads for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- ===== system health log =====
create table if not exists public.system_events (
  id bigserial primary key, source text not null, shop text, topic text, ok boolean not null, detail text,
  created_at timestamptz not null default now()
);
create index if not exists system_events_time_idx on public.system_events(created_at desc);
alter table public.system_events enable row level security;
create policy admin_read on public.system_events for select to authenticated using ((select public.is_admin()));

create or replace function public.admin_health() returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return json_build_object(
    'shops', (select coalesce(json_agg(x order by x.shop_domain), '[]') from (
       select s.shop_domain, s.status, c.name as client, t.scopes like '%read_products%' as can_read_products, t.shop_id is not null as has_token,
         (select max(e.created_at) from public.system_events e where e.shop = s.shop_domain and e.ok) as last_ok,
         (select count(*) from public.system_events e where e.shop = s.shop_domain and not e.ok and e.created_at > now() - interval '24 hours') as failures_24h,
         (select max(o.created_at) from public.orders o where o.shop_id = s.id) as last_order
       from public.shops s join public.clients c on c.id = s.client_id left join private.shop_tokens t on t.shop_id = s.id) x),
    'failures', (select coalesce(json_agg(x), '[]') from (
       select e.source, e.shop, e.topic, e.detail, e.created_at from public.system_events e
       where not e.ok and e.created_at > now() - interval '7 days' order by e.created_at desc limit 20) x),
    'events_24h', (select count(*) from public.system_events e where e.created_at > now() - interval '24 hours'));
end $$;

-- ===== margin check =====
create or replace function public.admin_margins(p_days int default 60) returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return json_build_object(
    'orders', (select coalesce(json_agg(x order by x.diff desc), '[]') from (
       select o.id, o.order_number, c.name as client, o.paid_at, o.price_total, o.agent_cost as expected, o.actual_cost as actual,
              round(o.actual_cost - o.agent_cost, 2) as diff, round(o.price_total - o.actual_cost, 2) as real_profit, o.line_items
       from public.orders o join public.clients c on c.id = o.client_id
       where o.actual_cost is not null and o.paid_at > now() - make_interval(days => p_days)) x),
    'totals', (select json_build_object('orders', count(*), 'expected', coalesce(sum(o.agent_cost),0), 'actual', coalesce(sum(o.actual_cost),0),
                 'charged', coalesce(sum(o.price_total),0), 'missing_cost', (select count(*) from public.orders m where m.actual_cost is null and m.status in ('shipped','delivered') and m.paid_at > now() - make_interval(days => p_days)))
               from public.orders o where o.actual_cost is not null and o.paid_at > now() - make_interval(days => p_days)));
end $$;

revoke all on function public.admin_set_agent(text, boolean) from public, anon;
revoke all on function public.admin_list_agents() from public, anon;
revoke all on function public.agent_orders(int) from public, anon;
revoke all on function public.agent_update_order(uuid, text, text, text, text, numeric, text) from public, anon;
revoke all on function public.admin_health() from public, anon;
revoke all on function public.admin_margins(int) from public, anon;
grant execute on function public.admin_set_agent(text, boolean), public.admin_list_agents(), public.agent_orders(int),
  public.agent_update_order(uuid, text, text, text, text, numeric, text), public.admin_health(), public.admin_margins(int) to authenticated;
