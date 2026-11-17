-- Clients cannot SELECT orders/products directly (RLS), so the old insert check's EXISTS() always failed.
-- Ownership is now checked by security-definer helpers. Policies are permissive (OR), so this new one
-- makes client inserts work; the old one stays harmless.
create or replace function public.owns_order(p_order uuid) returns boolean language sql stable security definer set search_path = '' as $$
  select p_order is null or exists (select 1 from public.orders o where o.id = p_order and o.client_id = public.my_client_id());
$$;
create or replace function public.owns_product(p_product uuid) returns boolean language sql stable security definer set search_path = '' as $$
  select p_product is null or exists (select 1 from public.products p where p.id = p_product and p.client_id = public.my_client_id());
$$;
revoke all on function public.owns_order(uuid) from public, anon;
revoke all on function public.owns_product(uuid) from public, anon;
grant execute on function public.owns_order(uuid), public.owns_product(uuid) to authenticated;
create policy client_write_v2 on public.messages for insert to authenticated
  with check (client_id = (select public.my_client_id()) and from_admin = false and author_id = auth.uid()
              and public.owns_order(order_id) and public.owns_product(product_id)
              and (order_id is not null or product_id is not null));
