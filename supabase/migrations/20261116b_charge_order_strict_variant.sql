-- If a Shopify variant was imported, only that variant's own price counts.
-- Fixes: an unpriced variant (Blue) got charged with the price of a priced sibling (Red) via the product_id fallback.
create or replace function public.charge_order(p_order_id uuid)
returns text language plpgsql security definer set search_path = '' as $function$
declare
  o public.orders%rowtype;
  li jsonb; p public.products%rowtype;
  v_total numeric := 0; v_cost numeric := 0; v_missing text[] := '{}'; v_qty int; v_balance numeric;
  v_var bigint; v_known boolean;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'order not found'; end if;
  if o.status not in ('new','on_hold','issue') then return o.status; end if;
  perform 1 from public.clients where id = o.client_id for update;

  for li in select * from jsonb_array_elements(o.line_items) loop
    v_qty := greatest(coalesce((li->>'quantity')::int,1),1);
    v_var := nullif(li->>'variant_id','')::bigint;
    -- if this exact variant was imported from Shopify, only its own price counts
    v_known := v_var is not null and exists (select 1 from public.products x where x.client_id = o.client_id and x.shopify_variant_id = v_var);
    if v_known then
      select * into p from public.products pr
       where pr.client_id = o.client_id and pr.active and pr.shopify_variant_id = v_var
         and (pr.country is null or o.country is null or upper(pr.country) = upper(o.country))
       order by (pr.country is not null) desc limit 1;
    else
      select * into p from public.products pr
       where pr.client_id = o.client_id and pr.active and pr.shopify_variant_id is null
         and ( (nullif(li->>'sku','') is not null and lower(pr.sku) = lower(li->>'sku'))
            or (nullif(li->>'product_id','') is not null and pr.shopify_product_id = (li->>'product_id')::bigint)
            or lower(pr.name) = lower(li->>'title') )
         and (pr.country is null or o.country is null or upper(pr.country) = upper(o.country))
       order by (pr.country is not null) desc, pr.created_at desc
       limit 1;
    end if;
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
