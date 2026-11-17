-- Online top-ups via Mollie (iDEAL, Bancontact, card).
-- The balance is only credited after the webhook re-fetches the payment from Mollie and it is 'paid'.
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id),
  amount numeric not null check (amount > 0),
  status text not null default 'created',
  mollie_id text unique,
  method text,
  mode text,
  checkout_url text,
  ledger_id uuid references public.ledger(id),
  charged_back numeric not null default 0,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
create index if not exists payments_client_idx on public.payments (client_id, created_at desc);
alter table public.payments enable row level security;
drop policy if exists admin_all on public.payments;
create policy admin_all on public.payments for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- called by the Mollie webhook / status check with the payment as Mollie reports it
create or replace function public.service_mark_payment(p_payment uuid, p_mollie_id text, p_status text, p_amount numeric,
                                                       p_method text, p_mode text, p_charged_back numeric)
returns json language plpgsql security definer set search_path = '' as $$
declare pm public.payments%rowtype; lid uuid; n int := 0; diff numeric;
begin
  select * into pm from public.payments where id = p_payment for update;
  if not found then return json_build_object('skipped', 'unknown payment'); end if;
  if pm.mollie_id is distinct from p_mollie_id then raise exception 'mollie id mismatch'; end if;

  update public.payments set status = p_status, method = coalesce(p_method, method), mode = coalesce(p_mode, mode) where id = pm.id;

  if p_status = 'paid' and pm.ledger_id is null then
    if p_amount is distinct from pm.amount then raise exception 'amount mismatch: % vs %', p_amount, pm.amount; end if;
    insert into public.ledger (client_id, type, amount, description)
      values (pm.client_id, 'topup', pm.amount,
              'Online top-up' || coalesce(' (' || p_method || ')', '') || case when p_mode = 'test' then ' [TEST]' else '' end)
      returning id into lid;
    update public.payments set ledger_id = lid, paid_at = now() where id = pm.id;
    n := public.process_waiting_orders(pm.client_id);
  end if;

  -- chargeback after it was credited: take it off the balance again
  diff := coalesce(p_charged_back, 0) - pm.charged_back;
  if diff > 0 and (pm.ledger_id is not null or lid is not null) then
    insert into public.ledger (client_id, type, amount, description)
      values (pm.client_id, 'adjustment', -diff, 'Chargeback on online top-up');
    update public.payments set charged_back = coalesce(p_charged_back, 0) where id = pm.id;
  end if;

  return json_build_object('status', p_status, 'credited', lid is not null, 'orders_released', n,
                            'balance', public.client_balance(pm.client_id));
end $$;
revoke all on function public.service_mark_payment(uuid, text, text, numeric, text, text, numeric) from public, anon, authenticated;
grant execute on function public.service_mark_payment(uuid, text, text, numeric, text, text, numeric) to service_role;

-- client: status of one of their own payments (for the "back from iDEAL" screen)
create or replace function public.my_payment(p_payment uuid)
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object('id', p.id, 'amount', p.amount, 'status', p.status, 'credited', p.ledger_id is not null,
                           'balance', public.client_balance(p.client_id))
  from public.payments p where p.id = p_payment and p.client_id = public.my_client_id();
$$;
revoke all on function public.my_payment(uuid) from public, anon;
grant execute on function public.my_payment(uuid) to authenticated;
