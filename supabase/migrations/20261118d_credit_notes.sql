-- Credit notes: money that goes back (chargeback on a top-up, refund of unused balance) gets a credit note
-- in the same number series, with negative amounts and a reference to the original invoice.
alter table public.invoices add column if not exists kind text not null default 'invoice';
alter table public.invoices add column if not exists credit_for uuid references public.invoices(id) on delete set null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'invoices_kind_check') then
    alter table public.invoices add constraint invoices_kind_check check (kind in ('invoice','credit'));
  end if;
end $$;

create or replace function private.make_credit_note(p_client uuid, p_amount numeric, p_reason text, p_ref uuid, p_ledger uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare c public.clients%rowtype; o public.invoices%rowtype; y int := extract(year from now())::int; n int; rate numeric := 21; note text := null; buyer jsonb; v_id uuid;
  eu text[] := array['AT','BE','BG','CY','CZ','DE','DK','EE','ES','FI','FR','GR','HR','HU','IE','IT','LT','LU','LV','MT','PL','PT','RO','SE','SI','SK'];
begin
  if p_amount is null or p_amount <= 0 then return null; end if;
  select * into c from public.clients where id = p_client;
  if p_ref is not null then select * into o from public.invoices where id = p_ref; end if;
  if o.id is not null then
    rate := o.vat_rate; note := o.vat_note; buyer := o.buyer;   -- same customer details and VAT treatment as the original
  else
    if c.country is not null and c.country <> 'NL' and c.country = any(eu) and c.vat_id is not null then rate := 0; note := 'VAT reverse charged (art. 196 VAT Directive). Customer VAT ID: '||c.vat_id;
    elsif c.country is not null and c.country <> 'NL' and not (c.country = any(eu)) then rate := 0; note := 'VAT not applicable: service supplied outside the EU.';
    end if;
    buyer := json_build_object('name', coalesce(c.company_name, c.name), 'address', c.billing_address, 'country', c.country, 'vat_id', c.vat_id, 'email', c.contact_email);
  end if;
  insert into private.invoice_counters (year, last) values (y, 1) on conflict (year) do update set last = private.invoice_counters.last + 1 returning last into n;
  insert into public.invoices (number, client_id, ledger_id, issued_at, description, buyer, gross, vat_rate, vat, net, vat_note, kind, credit_for)
  values ('SD-'||y||'-'||lpad(n::text, 4, '0'), p_client, p_ledger, now(),
          coalesce(p_reason, 'Credit') || coalesce(' · credit for invoice ' || o.number, ''),
          buyer, -p_amount, rate, -(p_amount - round(p_amount / (1 + rate/100), 2)), -round(p_amount / (1 + rate/100), 2), note, 'credit', o.id)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function private.make_credit_note(uuid,numeric,text,uuid,uuid) from public;

-- chargebacks on an online top-up now also get a credit note against that top-up's invoice
create or replace function public.service_mark_payment(p_payment uuid, p_mollie_id text, p_status text, p_amount numeric, p_method text, p_mode text, p_charged_back numeric)
returns json language plpgsql security definer set search_path = '' as $$
declare pm public.payments%rowtype; lid uuid; n int := 0; diff numeric; adj uuid; inv uuid;
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

  diff := coalesce(p_charged_back, 0) - pm.charged_back;
  if diff > 0 and (pm.ledger_id is not null or lid is not null) then
    insert into public.ledger (client_id, type, amount, description)
      values (pm.client_id, 'adjustment', -diff, 'Chargeback on online top-up') returning id into adj;
    update public.payments set charged_back = coalesce(p_charged_back, 0) where id = pm.id;
    select id into inv from public.invoices where ledger_id = coalesce(pm.ledger_id, lid) and kind = 'invoice';
    if inv is not null then perform private.make_credit_note(pm.client_id, diff, 'Chargeback on online top-up', inv, adj); end if;
  end if;

  return json_build_object('status', p_status, 'credited', lid is not null, 'orders_released', n,
                            'balance', public.client_balance(pm.client_id));
end $$;
revoke execute on function public.service_mark_payment(uuid,text,text,numeric,text,text,numeric) from public, anon, authenticated;
grant execute on function public.service_mark_payment(uuid,text,text,numeric,text,text,numeric) to service_role;

-- admin pays unused balance back to a store: takes it off the balance and makes a credit note
create or replace function public.admin_refund_balance(p_client uuid, p_amount numeric, p_note text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare bal numeric; adj uuid; inv uuid; cn uuid;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  perform 1 from public.clients where id = p_client for update;
  bal := public.client_balance(p_client);
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be positive'; end if;
  if p_amount > bal then raise exception 'The balance is only %', to_char(bal, 'FM999990.00'); end if;
  insert into public.ledger (client_id, type, amount, description, created_by)
    values (p_client, 'adjustment', -p_amount, 'Refund of balance' || coalesce(' · ' || nullif(trim(p_note),''), ''), auth.uid()) returning id into adj;
  -- refer to the newest invoice that has not been fully credited already
  select i.id into inv from public.invoices i
   where i.client_id = p_client and i.kind = 'invoice'
     and i.gross + coalesce((select sum(c.gross) from public.invoices c where c.credit_for = i.id), 0) > 0
   order by i.issued_at desc, i.number desc limit 1;
  cn := private.make_credit_note(p_client, p_amount, 'Refund of prepaid balance', inv, adj);
  return json_build_object('balance', public.client_balance(p_client), 'credit_note', (select number from public.invoices where id = cn));
end $$;
revoke all on function public.admin_refund_balance(uuid,numeric,text) from public, anon;
grant execute on function public.admin_refund_balance(uuid,numeric,text) to authenticated;
