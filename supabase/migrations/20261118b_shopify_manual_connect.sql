-- Manual Shopify connection: the store creates its own app (Shopify admin -> Develop apps) and gives us
-- its Client ID + secret. We get 24-hour tokens with the client credentials grant and refresh them on use.
alter table private.shop_tokens add column if not exists app_client_id text;
alter table private.shop_tokens add column if not exists app_secret text;
alter table private.shop_tokens add column if not exists expires_at timestamptz;

create or replace function public.service_shop_token(p_shop_id uuid) returns json language sql stable security definer set search_path = '' as $$
  select json_build_object('shop_id', s.id, 'client_id', s.client_id, 'shop_domain', s.shop_domain,
                           'access_token', t.access_token, 'scopes', t.scopes,
                           'app_client_id', t.app_client_id, 'app_secret', t.app_secret, 'expires_at', t.expires_at)
  from public.shops s join private.shop_tokens t on t.shop_id = s.id
  where s.id = p_shop_id and s.status = 'active';
$$;

create or replace function public.service_fulfillment_info(p_order uuid) returns json language sql stable security definer set search_path = '' as $$
  select json_build_object('shop_id', s.id, 'shop_domain', s.shop_domain, 'access_token', t.access_token, 'shopify_order_id', o.shopify_order_id,
     'tracking_number', o.tracking_number, 'tracking_company', o.tracking_company, 'tracking_url', o.tracking_url,
     'app_client_id', t.app_client_id, 'app_secret', t.app_secret, 'expires_at', t.expires_at)
  from public.orders o join public.shops s on s.id = o.shop_id join private.shop_tokens t on t.shop_id = s.id
  where o.id = p_order;
$$;

create or replace function public.service_store_token(p_shop_id uuid, p_token text, p_scopes text, p_expires_in int)
returns void language sql security definer set search_path = '' as $$
  update private.shop_tokens set access_token = p_token, scopes = coalesce(nullif(p_scopes,''), scopes),
    expires_at = now() + make_interval(secs => coalesce(p_expires_in, 86399)), updated_at = now() where shop_id = p_shop_id;
$$;

-- the secret that signs webhooks for a manually connected store
create or replace function public.service_shop_webhook_secret(p_shop text) returns text language sql stable security definer set search_path = '' as $$
  select t.app_secret from public.shops s join private.shop_tokens t on t.shop_id = s.id where s.shop_domain = lower(p_shop) and t.app_secret is not null;
$$;

create or replace function public.service_connect_manual(p_client uuid, p_shop text, p_app_client_id text, p_app_secret text, p_token text, p_scopes text, p_expires_in int)
returns uuid language plpgsql security definer set search_path = '' as $$
declare sid uuid;
begin
  if p_client is null then raise exception 'no client account'; end if;
  insert into public.shops (client_id, shop_domain, status) values (p_client, lower(p_shop), 'active')
    on conflict (shop_domain) do update set client_id = excluded.client_id, status = 'active', installed_at = now()
    returning id into sid;
  insert into private.shop_tokens (shop_id, access_token, scopes, app_client_id, app_secret, expires_at)
    values (sid, p_token, p_scopes, p_app_client_id, p_app_secret, now() + make_interval(secs => coalesce(p_expires_in, 86399)))
    on conflict (shop_id) do update set access_token = excluded.access_token, scopes = excluded.scopes, app_client_id = excluded.app_client_id,
      app_secret = excluded.app_secret, expires_at = excluded.expires_at, updated_at = now();
  update public.clients set store_url = coalesce(store_url, 'https://'||lower(p_shop)) where id = p_client;
  return sid;
end $$;

revoke all on function public.service_store_token(uuid,text,text,int) from public, anon, authenticated;
revoke all on function public.service_shop_webhook_secret(text) from public, anon, authenticated;
revoke all on function public.service_connect_manual(uuid,text,text,text,text,text,int) from public, anon, authenticated;
revoke all on function public.service_shop_token(uuid) from public, anon, authenticated;
revoke all on function public.service_fulfillment_info(uuid) from public, anon, authenticated;

-- Free credit or a correction by the admin: changes the balance without an invoice (ledger type 'adjustment').
create or replace function public.admin_credit(p_client uuid, p_amount numeric, p_description text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare n int := 0;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  if p_amount is null or p_amount = 0 then raise exception 'amount must not be zero'; end if;
  insert into public.ledger (client_id, type, amount, description, created_by)
    values (p_client, 'adjustment', p_amount, coalesce(nullif(trim(p_description),''), case when p_amount > 0 then 'Credit from Shipdao' else 'Correction' end), auth.uid());
  if p_amount > 0 then n := public.process_waiting_orders(p_client); end if;
  return json_build_object('balance', public.client_balance(p_client), 'orders_released', n);
end $$;
revoke all on function public.admin_credit(uuid,numeric,text) from public, anon;
grant execute on function public.admin_credit(uuid,numeric,text) to authenticated;
