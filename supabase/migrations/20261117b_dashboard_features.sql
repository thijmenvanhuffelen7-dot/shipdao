-- Dashboard features: unpaid/cancelled Shopify orders, address problems, messages,
-- bank transfer reports, richer order data.

-- 1. orders: more Shopify data + two new statuses
alter table public.orders
  add column if not exists order_total numeric,
  add column if not exists currency text,
  add column if not exists customer_email text,
  add column if not exists note text,
  add column if not exists financial_status text,
  add column if not exists shopify_created_at timestamptz;
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check check (status in
  ('new','unpaid','on_hold','issue','paid','sent_to_agent','address_error','shipped','delivered','cancelled'));

-- 2. ingest: never charge an order the customer has not paid yet
create or replace function public.service_ingest_order(p_shop text, p_payload jsonb)
returns json language plpgsql security definer set search_path = '' as $function$
declare s public.shops%rowtype; oid uuid; st text; addr jsonb := p_payload->'shipping_address';
        fin text := lower(coalesce(p_payload->>'financial_status',''));
begin
  select * into s from public.shops where shop_domain = lower(p_shop) and status = 'active';
  if not found then return json_build_object('skipped','unknown shop'); end if;
  insert into public.orders (client_id, shop_id, shopify_order_id, order_number, customer_name, country, shipping_address, line_items,
                             order_total, currency, customer_email, note, financial_status, shopify_created_at, status)
  values (s.client_id, s.id, (p_payload->>'id')::bigint, p_payload->>'name',
    nullif(trim(coalesce(addr->>'first_name','')||' '||coalesce(addr->>'last_name','')),''),
    addr->>'country_code', addr,
    (select coalesce(jsonb_agg(jsonb_build_object('title', li->>'title', 'variant_title', li->>'variant_title', 'sku', li->>'sku',
        'quantity', (li->>'quantity')::int, 'product_id', li->>'product_id', 'variant_id', li->>'variant_id', 'price', li->>'price')),'[]'::jsonb)
     from jsonb_array_elements(coalesce(p_payload->'line_items','[]'::jsonb)) li
     where coalesce((li->>'requires_shipping')::boolean, true)),
    nullif(p_payload->>'total_price','')::numeric, p_payload->>'currency', p_payload->>'email', nullif(p_payload->>'note',''),
    fin, nullif(p_payload->>'created_at','')::timestamptz,
    case when fin in ('paid','partially_paid') or fin = '' then 'new' else 'unpaid' end)
  on conflict (shop_id, shopify_order_id) do nothing
  returning id into oid;
  if oid is null then return json_build_object('skipped','duplicate'); end if;
  if p_payload->>'cancelled_at' is not null then
    update public.orders set status = 'cancelled', status_note = 'Cancelled in Shopify' where id = oid;
    return json_build_object('order_id', oid, 'status', 'cancelled');
  end if;
  select status into st from public.orders where id = oid;
  if st = 'unpaid' then
    update public.orders set status_note = 'Not paid in Shopify yet ('||fin||'). We ship once it is paid.' where id = oid;
    return json_build_object('order_id', oid, 'status', 'unpaid');
  end if;
  st := public.charge_order(oid);
  return json_build_object('order_id', oid, 'status', st);
end $function$;

-- orders/paid webhook
create or replace function public.service_order_paid(p_shop text, p_payload jsonb)
returns json language plpgsql security definer set search_path = '' as $$
declare o public.orders%rowtype; st text;
begin
  select o2.* into o from public.orders o2 join public.shops s on s.id = o2.shop_id
   where s.shop_domain = lower(p_shop) and o2.shopify_order_id = (p_payload->>'id')::bigint for update of o2;
  if not found then return public.service_ingest_order(p_shop, p_payload); end if;
  update public.orders set financial_status = lower(coalesce(p_payload->>'financial_status','paid')) where id = o.id;
  if o.status <> 'unpaid' then return json_build_object('order_id', o.id, 'status', o.status); end if;
  update public.orders set status = 'new', status_note = null where id = o.id;
  st := public.charge_order(o.id);
  return json_build_object('order_id', o.id, 'status', st);
end $$;

-- orders/cancelled webhook: refund what we charged, unless it is already with the agent / shipped
create or replace function public.service_order_cancelled(p_shop text, p_payload jsonb)
returns json language plpgsql security definer set search_path = '' as $$
declare o public.orders%rowtype;
begin
  select o2.* into o from public.orders o2 join public.shops s on s.id = o2.shop_id
   where s.shop_domain = lower(p_shop) and o2.shopify_order_id = (p_payload->>'id')::bigint for update of o2;
  if not found then return json_build_object('skipped','unknown order'); end if;
  if o.status in ('cancelled','shipped','delivered') then return json_build_object('order_id', o.id, 'status', o.status); end if;
  if o.status in ('sent_to_agent','address_error') then
    update public.orders set status_note = 'Cancelled in Shopify while already with the agent. Stop it if you still can, then cancel here.' where id = o.id;
    insert into public.messages (client_id, order_id, from_admin, body)
      values (o.client_id, o.id, false, 'Shopify: this order was cancelled by the store, but it was already sent to the agent.');
    return json_build_object('order_id', o.id, 'status', o.status, 'flagged', true);
  end if;
  if exists (select 1 from public.ledger where order_id = o.id and type='order')
     and not exists (select 1 from public.ledger where order_id = o.id and type='refund') then
    insert into public.ledger (client_id, type, amount, order_id, description)
      values (o.client_id, 'refund', coalesce(o.price_total,0), o.id, 'Cancelled in Shopify: '||coalesce(o.order_number,''));
  end if;
  update public.orders set status = 'cancelled', status_note = 'Cancelled in Shopify' where id = o.id;
  return json_build_object('order_id', o.id, 'status', 'cancelled');
end $$;

-- 3. messages (per order or per product, between store and Shipdao)
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id),
  order_id uuid references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete cascade,
  from_admin boolean not null default false,
  author_id uuid references auth.users(id) default auth.uid(),
  body text not null check (length(body) between 1 and 4000),
  read_by_client_at timestamptz,
  read_by_admin_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists messages_client_idx on public.messages (client_id, created_at desc);
create index if not exists messages_order_idx on public.messages (order_id);
create index if not exists messages_product_idx on public.messages (product_id);
alter table public.messages enable row level security;
drop policy if exists admin_all on public.messages;
create policy admin_all on public.messages for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
drop policy if exists client_read on public.messages;
create policy client_read on public.messages for select to authenticated using (client_id = (select public.my_client_id()));
drop policy if exists client_write on public.messages;
create policy client_write on public.messages for insert to authenticated
  with check (client_id = (select public.my_client_id()) and from_admin = false and author_id = auth.uid()
    and (order_id is null or exists (select 1 from public.orders o where o.id = order_id and o.client_id = (select public.my_client_id())))
    and (product_id is null or exists (select 1 from public.products p where p.id = product_id and p.client_id = (select public.my_client_id()))));

create or replace function public.mark_messages_read(p_order uuid default null, p_product uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if public.is_admin() then
    update public.messages set read_by_admin_at = now()
     where read_by_admin_at is null and not from_admin and (order_id = p_order or product_id = p_product);
  else
    update public.messages set read_by_client_at = now()
     where read_by_client_at is null and from_admin and client_id = public.my_client_id() and (order_id = p_order or product_id = p_product);
  end if;
end $$;
revoke all on function public.mark_messages_read(uuid, uuid) from public, anon;
grant execute on function public.mark_messages_read(uuid, uuid) to authenticated;

-- 4. address problems
create or replace function public.admin_flag_address(p_order uuid, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.orders%rowtype;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  select * into o from public.orders where id = p_order for update;
  if o.status not in ('paid','sent_to_agent') then raise exception 'only paid orders that have not shipped'; end if;
  update public.orders set status = 'address_error', status_note = coalesce(nullif(p_note,''), 'Address problem') where id = o.id;
  insert into public.messages (client_id, order_id, from_admin, body)
    values (o.client_id, o.id, true, 'Address problem: '||coalesce(nullif(p_note,''),'please check the delivery address')||'. Please correct it in your portal.');
end $$;

create or replace function public.client_fix_address(p_order uuid, p_address jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.orders%rowtype; a jsonb;
begin
  select * into o from public.orders where id = p_order and client_id = public.my_client_id() for update;
  if not found then raise exception 'order not found'; end if;
  if o.status <> 'address_error' then raise exception 'this order does not need an address fix'; end if;
  a := coalesce(o.shipping_address, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
        'name', p_address->>'name', 'address1', p_address->>'address1', 'address2', p_address->>'address2',
        'zip', p_address->>'zip', 'city', p_address->>'city', 'province', p_address->>'province',
        'country_code', upper(p_address->>'country_code'), 'phone', p_address->>'phone'));
  update public.orders set shipping_address = a, country = coalesce(upper(p_address->>'country_code'), country),
         customer_name = coalesce(nullif(p_address->>'name',''), customer_name),
         status = 'paid', status_note = 'Address corrected by the store' where id = o.id;
  insert into public.messages (client_id, order_id, from_admin, body)
    values (o.client_id, o.id, false, 'Address corrected: '||concat_ws(', ', a->>'address1', a->>'zip', a->>'city', a->>'country_code'));
end $$;
revoke all on function public.admin_flag_address(uuid, text) from public, anon;
revoke all on function public.client_fix_address(uuid, jsonb) from public, anon;
grant execute on function public.admin_flag_address(uuid, text) to authenticated;
grant execute on function public.client_fix_address(uuid, jsonb) to authenticated;

-- 5. bank transfers the client reports, admin confirms
alter table public.payments add column if not exists reference text;
create or replace function public.client_report_transfer(p_amount numeric, p_reference text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid := public.my_client_id(); pid uuid;
begin
  if v is null then raise exception 'no client account'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100000 then raise exception 'invalid amount'; end if;
  insert into public.payments (client_id, amount, status, method, reference, created_by)
    values (v, round(p_amount, 2), 'reported', 'banktransfer', left(p_reference, 200), auth.uid()) returning id into pid;
  return pid;
end $$;
create or replace function public.admin_confirm_transfer(p_payment uuid, p_accept boolean)
returns json language plpgsql security definer set search_path = '' as $$
declare pm public.payments%rowtype; lid uuid; n int := 0;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  select * into pm from public.payments where id = p_payment and method = 'banktransfer' for update;
  if not found or pm.status <> 'reported' then raise exception 'not a reported transfer'; end if;
  if not p_accept then update public.payments set status = 'rejected' where id = pm.id; return json_build_object('status','rejected'); end if;
  insert into public.ledger (client_id, type, amount, description, created_by)
    values (pm.client_id, 'topup', pm.amount, 'Bank transfer'||coalesce(' ('||pm.reference||')',''), auth.uid()) returning id into lid;
  update public.payments set status = 'paid', ledger_id = lid, paid_at = now() where id = pm.id;
  n := public.process_waiting_orders(pm.client_id);
  return json_build_object('status','paid','orders_released', n, 'balance', public.client_balance(pm.client_id));
end $$;
revoke all on function public.client_report_transfer(numeric, text) from public, anon;
revoke all on function public.admin_confirm_transfer(uuid, boolean) from public, anon;
grant execute on function public.client_report_transfer(numeric, text) to authenticated;
grant execute on function public.admin_confirm_transfer(uuid, boolean) to authenticated;

-- 6. client_dashboard: full order data, running balance, unread messages, payments
create or replace function public.client_dashboard()
returns json language plpgsql stable security definer set search_path = '' as $function$
declare v uuid := public.my_client_id();
begin
  if v is null then raise exception 'no client account'; end if;
  return json_build_object(
    'balance', public.client_balance(v),
    'orders', (select coalesce(json_agg(x order by x.created_at desc),'[]') from (
        select o.id, o.order_number, o.customer_name, o.customer_email, o.country, o.shipping_address, o.line_items, o.status, o.status_note,
               o.price_total, o.order_total, o.currency, o.note, o.financial_status, o.shopify_created_at,
               o.tracking_number, o.tracking_company, o.tracking_url, o.created_at, o.paid_at, o.shipped_at,
               (select count(*) from public.messages m where m.order_id = o.id) as messages,
               (select count(*) from public.messages m where m.order_id = o.id and m.from_admin and m.read_by_client_at is null) as unread
        from public.orders o where o.client_id = v order by o.created_at desc limit 1000) x),
    'ledger', (select coalesce(json_agg(x order by x.created_at desc),'[]') from (
        select l.type, l.amount, l.description, l.created_at, l.order_id,
               sum(l.amount) over (order by l.created_at, l.id) as balance_after
        from public.ledger l where l.client_id = v order by l.created_at desc limit 2000) x),
    'products', (select coalesce(json_agg(x order by x.name, x.variant_title),'[]') from (
        select pr.id, pr.name, pr.variant_title, pr.sku, pr.country, pr.image_url, pr.shop_price, pr.delivery_days, pr.active,
               case when pr.active then 'priced' when pr.sourcing_status = 'priced' then 'sourcing' else pr.sourcing_status end as sourcing_status,
               case when pr.active then pr.price_all_in end as price_all_in,
               (select count(*) from public.messages m where m.product_id = pr.id and m.from_admin and m.read_by_client_at is null) as unread
        from public.products pr
        where pr.client_id = v and coalesce(pr.shopify_status,'') <> 'DELETED' and pr.sourcing_status <> 'skip') x),
    'quotes', (select coalesce(json_agg(q order by q.created_at desc),'[]') from (
        select qu.id, qu.status, qu.orders_per_day, qu.notes, qu.created_at, qu.quoted_at,
          (select coalesce(json_agg(json_build_object('product_name', i.product_name, 'product_url', i.product_url, 'country', i.country,
              'current_price', i.current_price, 'delivery_days', i.delivery_days,
              'price_all_in', case when qu.status in ('quoted','accepted','declined') then i.price_all_in end) order by i.created_at),'[]')
           from public.quote_items i where i.quote_id = qu.id) as items
        from public.quotes qu where qu.client_id = v) q),
    'shops', (select coalesce(json_agg(s),'[]') from (select sh.id, sh.shop_domain, sh.status, sh.installed_at from public.shops sh where sh.client_id = v) s),
    'payments', (select coalesce(json_agg(x order by x.created_at desc),'[]') from (
        select p.id, p.amount, p.status, p.method, p.reference, p.created_at, p.paid_at from public.payments p
        where p.client_id = v and p.status in ('reported','paid','rejected') order by p.created_at desc limit 50) x),
    'unread', (select count(*) from public.messages m where m.client_id = v and m.from_admin and m.read_by_client_at is null)
  );
end $function$;

revoke all on function public.service_order_paid(text, jsonb) from public, anon, authenticated;
revoke all on function public.service_order_cancelled(text, jsonb) from public, anon, authenticated;
grant execute on function public.service_order_paid(text, jsonb) to service_role;
grant execute on function public.service_order_cancelled(text, jsonb) to service_role;

-- 7. admin_overview: extra to-do counters
create or replace function public.admin_overview()
returns json language plpgsql stable security definer set search_path = '' as $function$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return json_build_object(
    'clients', (select coalesce(json_agg(x order by x.name),'[]') from (
        select c.id, c.name, c.store_url, c.contact_email, c.whatsapp, c.status, c.default_margin, c.created_at,
          public.client_balance(c.id) as balance,
          (select coalesce(sum(-l.amount - l.agent_cost),0) from public.ledger l where l.client_id=c.id and l.type='order')
            - (select coalesce(sum(l.amount),0) from public.ledger l where l.client_id=c.id and l.type='refund') as profit,
          (select count(*) from public.orders o where o.client_id=c.id) as orders,
          (select count(*) from public.orders o where o.client_id=c.id and o.status in ('on_hold','issue','address_error')) as waiting,
          (select count(*) from public.orders o where o.client_id=c.id and o.status in ('paid','sent_to_agent')) as to_ship,
          (select count(*) from public.orders o where o.client_id=c.id and o.created_at > now() - interval '7 days') as orders_7d,
          (select max(o.created_at) from public.orders o where o.client_id=c.id) as last_order_at,
          (select count(*) from public.products p where p.client_id=c.id and coalesce(p.shopify_status,'') <> 'DELETED' and p.sourcing_status <> 'skip') as products,
          (select count(*) from public.products p where p.client_id=c.id and p.active) as priced,
          (select count(*) from public.products p where p.client_id=c.id and coalesce(p.shopify_status,'') <> 'DELETED' and p.sourcing_status in ('to_source','sourcing')) as to_source,
          (select coalesce(sum(o.price_total),0) from public.orders o where o.client_id=c.id and o.status='on_hold') as on_hold_value,
          (select string_agg(s.shop_domain, ', ') from public.shops s where s.client_id=c.id and s.status='active') as shops,
          (select count(*) from public.quotes q where q.client_id=c.id and q.status='requested') as open_quotes
        from public.clients c) x),
    'totals', json_build_object(
      'profit_30d', (select coalesce(sum(-l.amount - l.agent_cost),0) from public.ledger l where l.type='order' and l.created_at > now() - interval '30 days'),
      'revenue_30d', (select coalesce(sum(-l.amount),0) from public.ledger l where l.type='order' and l.created_at > now() - interval '30 days'),
      'orders_30d', (select count(*) from public.orders o where o.created_at > now() - interval '30 days'),
      'orders_today', (select count(*) from public.orders o where o.created_at > date_trunc('day', now())),
      'to_ship', (select count(*) from public.orders o where o.status in ('paid','sent_to_agent')),
      'paid', (select count(*) from public.orders o where o.status = 'paid'),
      'sent_to_agent', (select count(*) from public.orders o where o.status = 'sent_to_agent'),
      'late', (select count(*) from public.orders o where o.status in ('paid','sent_to_agent') and o.paid_at < now() - interval '5 days'),
      'waiting', (select count(*) from public.orders o where o.status in ('on_hold','issue','address_error')),
      'issue', (select count(*) from public.orders o where o.status = 'issue'),
      'on_hold', (select count(*) from public.orders o where o.status = 'on_hold'),
      'address_error', (select count(*) from public.orders o where o.status = 'address_error'),
      'unpaid', (select count(*) from public.orders o where o.status = 'unpaid'),
      'unread', (select count(*) from public.messages m where not m.from_admin and m.read_by_admin_at is null),
      'transfers', (select count(*) from public.payments p where p.status = 'reported'),
      'open_quotes', (select count(*) from public.quotes q where q.status='requested'),
      'to_source', (select count(*) from public.products p where coalesce(p.shopify_status,'') <> 'DELETED' and p.sourcing_status = 'to_source'),
      'sourcing', (select count(*) from public.products p where coalesce(p.shopify_status,'') <> 'DELETED' and p.sourcing_status = 'sourcing'),
      'shops', (select count(*) from public.shops s where s.status='active'),
      'balances', (select coalesce(sum(amount),0) from public.ledger)
    ),
    'transfers', (select coalesce(json_agg(x order by x.created_at),'[]') from (
        select p.id, p.amount, p.reference, p.created_at, c.name as client from public.payments p join public.clients c on c.id = p.client_id
        where p.status = 'reported') x),
    'recent_orders', (select coalesce(json_agg(x order by x.created_at desc),'[]') from (
        select o.id, o.order_number, o.status, o.status_note, o.price_total, o.agent_cost, o.country, o.line_items, o.created_at, c.name as client
        from public.orders o join public.clients c on c.id = o.client_id order by o.created_at desc limit 12) x)
  );
end $function$;
