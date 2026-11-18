-- Performance: indexes on foreign keys, auth checks evaluated once per query in message policies, key on rate_limits.
create index if not exists oauth_states_client_idx on private.oauth_states(client_id);
create index if not exists claims_client_idx on public.claims(client_id);
create index if not exists claims_decided_by_idx on public.claims(decided_by);
create index if not exists clients_referred_by_idx on public.clients(referred_by);
create index if not exists invoices_credit_for_idx on public.invoices(credit_for);
create index if not exists ledger_created_by_idx on public.ledger(created_by);
create index if not exists messages_author_idx on public.messages(author_id);
create index if not exists partner_payouts_partner_idx on public.partner_payouts(partner_id);
create index if not exists payments_created_by_idx on public.payments(created_by);
create index if not exists payments_ledger_idx on public.payments(ledger_id);
create index if not exists products_quote_item_idx on public.products(quote_item_id);
create index if not exists products_shop_idx on public.products(shop_id);
create index if not exists qc_photos_client_idx on public.qc_photos(client_id);
create index if not exists qc_photos_created_by_idx on public.qc_photos(created_by);

alter table private.rate_limits add column if not exists id bigint generated always as identity;
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'private.rate_limits'::regclass and contype = 'p') then
    alter table private.rate_limits add primary key (id);
  end if;
end $$;

-- the newer message policy: auth.uid() once per query
alter policy client_write_v2 on public.messages with check (
  (client_id = (select public.my_client_id())) and (from_admin = false) and (author_id = (select auth.uid()))
  and public.owns_order(order_id) and public.owns_product(product_id) and ((order_id is not null) or (product_id is not null)));
-- the old message policy is fully replaced by client_write_v2; switch it off (it can be dropped later)
alter policy client_write on public.messages with check (false);
