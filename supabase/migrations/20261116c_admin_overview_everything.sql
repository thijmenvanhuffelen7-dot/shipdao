-- admin_overview: per-client products/sourcing/to-ship/on-hold numbers, extra totals and the 12 latest orders.
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
          (select count(*) from public.orders o where o.client_id=c.id and o.status in ('on_hold','issue')) as waiting,
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
      'waiting', (select count(*) from public.orders o where o.status in ('on_hold','issue')),
      'issue', (select count(*) from public.orders o where o.status = 'issue'),
      'on_hold', (select count(*) from public.orders o where o.status = 'on_hold'),
      'open_quotes', (select count(*) from public.quotes q where q.status='requested'),
      'to_source', (select count(*) from public.products p where coalesce(p.shopify_status,'') <> 'DELETED' and p.sourcing_status = 'to_source'),
      'sourcing', (select count(*) from public.products p where coalesce(p.shopify_status,'') <> 'DELETED' and p.sourcing_status = 'sourcing'),
      'shops', (select count(*) from public.shops s where s.status='active'),
      'balances', (select coalesce(sum(amount),0) from public.ledger)
    ),
    'recent_orders', (select coalesce(json_agg(x order by x.created_at desc),'[]') from (
        select o.id, o.order_number, o.status, o.status_note, o.price_total, o.agent_cost, o.country, o.line_items, o.created_at, c.name as client
        from public.orders o join public.clients c on c.id = o.client_id order by o.created_at desc limit 12) x)
  );
end $function$;
