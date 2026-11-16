-- Shopify product import + sourcing workflow.
-- Every Shopify variant becomes a row in products. Imported rows start inactive with
-- sourcing_status 'to_source'; once the admin fills in costs and marks them 'priced'
-- they become active and orders for them get charged automatically.

alter table public.products
  add column if not exists shop_id uuid references public.shops(id) on delete set null,
  add column if not exists shopify_variant_id bigint,
  add column if not exists variant_title text,
  add column if not exists image_url text,
  add column if not exists shop_price numeric,
  add column if not exists shop_url text,
  add column if not exists shopify_status text,
  add column if not exists source_url text,
  add column if not exists cost_product numeric,
  add column if not exists cost_shipping numeric,
  add column if not exists cost_other numeric,
  add column if not exists notes text,
  add column if not exists sourcing_status text not null default 'priced',
  add column if not exists synced_at timestamptz;

do $$ begin
  alter table public.products add constraint products_sourcing_status_check
    check (sourcing_status in ('to_source','sourcing','priced','skip'));
exception when duplicate_object then null; end $$;

create unique index if not exists products_client_variant_uniq
  on public.products (client_id, shopify_variant_id) where shopify_variant_id is not null;
create index if not exists products_client_idx on public.products (client_id);
create index if not exists products_sourcing_idx on public.products (sourcing_status);

-- token lookup for the sync function (service role only)
create or replace function public.service_shop_token(p_shop_id uuid)
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object('shop_id', s.id, 'client_id', s.client_id, 'shop_domain', s.shop_domain,
                           'access_token', t.access_token, 'scopes', t.scopes)
  from public.shops s join private.shop_tokens t on t.shop_id = s.id
  where s.id = p_shop_id and s.status = 'active';
$$;

-- upsert a batch of variants: [{product_id, variant_id, title, variant_title, sku, price, image_url, shop_url, status}]
-- only touches the Shopify-side fields, never costs/margin/sourcing status
create or replace function public.service_upsert_products(p_shop text, p_items jsonb)
returns json language plpgsql security definer set search_path = '' as $$
declare s public.shops%rowtype; v_margin numeric; n_new int := 0; n_upd int := 0; it jsonb; was_new boolean;
begin
  select * into s from public.shops where shop_domain = lower(p_shop) and status = 'active';
  if not found then return json_build_object('skipped','unknown shop'); end if;
  select coalesce(default_margin, 0) into v_margin from public.clients where id = s.client_id;

  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    insert into public.products (client_id, shop_id, name, variant_title, sku, shopify_product_id, shopify_variant_id,
                                 image_url, shop_price, shop_url, shopify_status, cost_total, margin, active, sourcing_status, synced_at)
    values (s.client_id, s.id, coalesce(nullif(it->>'title',''), 'Untitled'), nullif(it->>'variant_title',''), nullif(it->>'sku',''),
            (it->>'product_id')::bigint, (it->>'variant_id')::bigint,
            nullif(it->>'image_url',''), nullif(it->>'price','')::numeric, nullif(it->>'shop_url',''), it->>'status',
            0, v_margin, false, 'to_source', now())
    on conflict (client_id, shopify_variant_id) where shopify_variant_id is not null do update set
      shop_id = excluded.shop_id, name = excluded.name, variant_title = excluded.variant_title, sku = excluded.sku,
      shopify_product_id = excluded.shopify_product_id, image_url = excluded.image_url, shop_price = excluded.shop_price,
      shop_url = excluded.shop_url, shopify_status = excluded.shopify_status, synced_at = now()
    returning (xmax = 0) into was_new;
    if was_new then n_new := n_new + 1; else n_upd := n_upd + 1; end if;
  end loop;
  return json_build_object('new', n_new, 'updated', n_upd);
end $$;

-- mark variants that no longer exist in Shopify (product deleted)
create or replace function public.service_products_deleted(p_shop text, p_product_id bigint)
returns void language sql security definer set search_path = '' as $$
  update public.products p set shopify_status = 'DELETED', active = false
  from public.shops s where s.id = p.shop_id and s.shop_domain = lower(p_shop) and p.shopify_product_id = p_product_id;
$$;

revoke all on function public.service_shop_token(uuid) from public, anon, authenticated;
revoke all on function public.service_upsert_products(text, jsonb) from public, anon, authenticated;
revoke all on function public.service_products_deleted(text, bigint) from public, anon, authenticated;
grant execute on function public.service_shop_token(uuid) to service_role;
grant execute on function public.service_upsert_products(text, jsonb) to service_role;
grant execute on function public.service_products_deleted(text, bigint) to service_role;

-- charge_order: match on variant first, so variants can have their own price
create or replace function public.charge_order(p_order_id uuid)
returns text language plpgsql security definer set search_path = '' as $function$
declare
  o public.orders%rowtype;
  li jsonb; p public.products%rowtype;
  v_total numeric := 0; v_cost numeric := 0; v_missing text[] := '{}'; v_qty int; v_balance numeric;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'order not found'; end if;
  if o.status not in ('new','on_hold','issue') then return o.status; end if;
  perform 1 from public.clients where id = o.client_id for update; -- serialize per client

  for li in select * from jsonb_array_elements(o.line_items) loop
    v_qty := greatest(coalesce((li->>'quantity')::int,1),1);
    select * into p from public.products pr
     where pr.client_id = o.client_id and pr.active
       and ( (nullif(li->>'variant_id','') is not null and pr.shopify_variant_id = (li->>'variant_id')::bigint)
          or (nullif(li->>'sku','') is not null and lower(pr.sku) = lower(li->>'sku'))
          or (nullif(li->>'product_id','') is not null and pr.shopify_product_id = (li->>'product_id')::bigint)
          or lower(pr.name) = lower(li->>'title') )
       and (pr.country is null or o.country is null or upper(pr.country) = upper(o.country))
     order by (nullif(li->>'variant_id','') is not null and pr.shopify_variant_id = (li->>'variant_id')::bigint) desc,
              (pr.country is not null) desc, pr.created_at desc
     limit 1;
    if not found then
      v_missing := v_missing || (coalesce(li->>'title','?') || coalesce(' ('||nullif(li->>'variant_title','')||')',''));
    else
      v_total := v_total + p.price_all_in * v_qty;
      v_cost  := v_cost  + p.cost_total  * v_qty;
    end if;
  end loop;

  if array_length(v_missing,1) > 0 then
    update public.orders set status='issue', status_note='No agreed price for: '||array_to_string(v_missing, ', ') where id = o.id;
    return 'issue';
  end if;

  v_balance := public.client_balance(o.client_id);
  if v_balance < v_total then
    update public.orders set status='on_hold', price_total=v_total, agent_cost=v_cost,
      status_note=format('Balance too low: needs €%s, balance €%s', v_total, v_balance) where id = o.id;
    return 'on_hold';
  end if;

  insert into public.ledger (client_id, type, amount, agent_cost, order_id, description)
    values (o.client_id, 'order', -v_total, v_cost, o.id, 'Order '||coalesce(o.order_number, o.id::text));
  update public.orders set status='paid', price_total=v_total, agent_cost=v_cost, status_note=null, paid_at=now() where id = o.id;
  return 'paid';
end $function$;

-- client_dashboard: products now include imported ones (status, image), never costs
create or replace function public.client_dashboard()
returns json language plpgsql stable security definer set search_path = '' as $function$
declare v uuid := public.my_client_id();
begin
  if v is null then raise exception 'no client account'; end if;
  return json_build_object(
    'balance', public.client_balance(v),
    'orders', (select coalesce(json_agg(x order by x.created_at desc),'[]') from (
        select o.id, o.order_number, o.customer_name, o.country, o.line_items, o.status, o.status_note, o.price_total,
               o.tracking_number, o.tracking_company, o.tracking_url, o.created_at, o.paid_at, o.shipped_at
        from public.orders o where o.client_id = v order by o.created_at desc limit 200) x),
    'ledger', (select coalesce(json_agg(x order by x.created_at desc),'[]') from (
        select l.type, l.amount, l.description, l.created_at from public.ledger l where l.client_id = v order by l.created_at desc limit 200) x),
    'products', (select coalesce(json_agg(x order by x.name, x.variant_title),'[]') from (
        select pr.id, pr.name, pr.variant_title, pr.sku, pr.country, pr.image_url, pr.shop_price, pr.delivery_days, pr.active,
               case when pr.active then 'priced' when pr.sourcing_status = 'priced' then 'sourcing' else pr.sourcing_status end as sourcing_status,
               case when pr.active then pr.price_all_in end as price_all_in
        from public.products pr
        where pr.client_id = v and coalesce(pr.shopify_status,'') <> 'DELETED' and pr.sourcing_status <> 'skip') x),
    'quotes', (select coalesce(json_agg(q order by q.created_at desc),'[]') from (
        select qu.id, qu.status, qu.orders_per_day, qu.notes, qu.created_at, qu.quoted_at,
          (select coalesce(json_agg(json_build_object('product_name', i.product_name, 'product_url', i.product_url, 'country', i.country,
              'current_price', i.current_price, 'delivery_days', i.delivery_days,
              'price_all_in', case when qu.status in ('quoted','accepted','declined') then i.price_all_in end) order by i.created_at),'[]')
           from public.quote_items i where i.quote_id = qu.id) as items
        from public.quotes qu where qu.client_id = v) q),
    'shops', (select coalesce(json_agg(s),'[]') from (select sh.id, sh.shop_domain, sh.status, sh.installed_at from public.shops sh where sh.client_id = v) s)
  );
end $function$;

-- NOTE: charge_order above was replaced by 20261116b_charge_order_strict_variant.sql
