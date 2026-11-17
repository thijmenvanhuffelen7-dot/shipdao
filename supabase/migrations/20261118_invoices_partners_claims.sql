-- Invoices for top-ups, partner (referral) program, claims (lost / damaged / wrong) with photos.

-- ===== Billing details on the client =====
alter table public.clients add column if not exists company_name text;
alter table public.clients add column if not exists billing_address text;
alter table public.clients add column if not exists country text;
alter table public.clients add column if not exists vat_id text;
alter table public.clients add column if not exists referred_by uuid;

create or replace function public.update_my_billing(p_company text, p_address text, p_country text, p_vat text)
returns void language plpgsql security definer set search_path = '' as $$
declare v uuid := public.my_client_id();
begin
  if v is null then raise exception 'no client account'; end if;
  if nullif(trim(p_country),'') is not null and upper(trim(p_country)) !~ '^[A-Z]{2}$' then raise exception 'Country must be a 2-letter code, e.g. NL'; end if;
  update public.clients set company_name = nullif(trim(p_company),''), billing_address = nullif(trim(p_address),''),
    country = upper(nullif(trim(p_country),'')), vat_id = upper(replace(nullif(trim(p_vat),''),' ','')) where id = v;
end $$;
revoke all on function public.update_my_billing(text,text,text,text) from public, anon;
grant execute on function public.update_my_billing(text,text,text,text) to authenticated;


-- ===== Invoices =====
create table if not exists private.invoice_counters (year int primary key, last int not null default 0);

create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  client_id uuid not null references public.clients(id) on delete restrict,
  ledger_id uuid unique references public.ledger(id) on delete set null,
  issued_at timestamptz not null default now(),
  description text not null,
  buyer jsonb not null,
  gross numeric(12,2) not null,
  vat_rate numeric(5,2) not null,
  vat numeric(12,2) not null,
  net numeric(12,2) not null,
  vat_note text
);
create index if not exists invoices_client_idx on public.invoices(client_id, issued_at desc);
alter table public.invoices enable row level security;
create policy admin_all on public.invoices for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
create policy client_read on public.invoices for select to authenticated using (client_id = (select public.my_client_id()));

-- Rule of thumb (check with your accountant):
--  * NL customer, or no VAT ID: 21% Dutch VAT, included in the amount paid.
--  * EU business outside NL with a VAT ID: reverse charge, 0%.
--  * Customer outside the EU: 0%, VAT not charged (service outside the EU).
create or replace function private.make_invoice() returns trigger language plpgsql security definer set search_path = '' as $$
declare c public.clients%rowtype; y int := extract(year from now())::int; n int; rate numeric := 21; note text := null;
  eu text[] := array['AT','BE','BG','CY','CZ','DE','DK','EE','ES','FI','FR','GR','HR','HU','IE','IT','LT','LU','LV','MT','PL','PT','RO','SE','SI','SK'];
begin
  if new.type <> 'topup' or new.amount <= 0 or coalesce(new.description,'') like '%[TEST]%' then return new; end if;
  select * into c from public.clients where id = new.client_id;
  if c.country is not null and c.country <> 'NL' and c.country = any(eu) and c.vat_id is not null then rate := 0; note := 'VAT reverse charged (art. 196 VAT Directive). Customer VAT ID: '||c.vat_id;
  elsif c.country is not null and c.country <> 'NL' and not (c.country = any(eu)) then rate := 0; note := 'VAT not applicable: service supplied outside the EU.';
  end if;
  insert into private.invoice_counters (year, last) values (y, 1) on conflict (year) do update set last = private.invoice_counters.last + 1 returning last into n;
  insert into public.invoices (number, client_id, ledger_id, issued_at, description, buyer, gross, vat_rate, vat, net, vat_note)
  values ('SD-'||y||'-'||lpad(n::text, 4, '0'), c.id, new.id, new.created_at,
          'Prepaid fulfilment balance'||coalesce(' · '||new.description,''),
          json_build_object('name', coalesce(c.company_name, c.name), 'address', c.billing_address, 'country', c.country, 'vat_id', c.vat_id, 'email', c.contact_email),
          new.amount, rate, round(new.amount - new.amount / (1 + rate/100), 2), round(new.amount / (1 + rate/100), 2), note);
  return new;
end $$;
create trigger ledger_make_invoice after insert on public.ledger for each row execute function private.make_invoice();

-- ===== Partners (coaches / communities) =====
create table if not exists public.partners (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text not null unique,
  code text not null unique check (code ~ '^[a-z0-9-]{3,30}$'),
  commission numeric(8,2) not null default 0,   -- € per shipped order of a referred store
  user_id uuid unique references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.partners enable row level security;
create policy admin_all on public.partners for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
alter table public.clients add constraint clients_referred_by_fk foreign key (referred_by) references public.partners(id) on delete set null;

create table if not exists public.partner_payouts (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.partners(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  note text, created_at timestamptz not null default now()
);
alter table public.partner_payouts enable row level security;
create policy admin_all on public.partner_payouts for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- Earned = commission × shipped orders of referred stores (counted on the month they shipped). Redefined at the end of this file once claims exist.
create or replace function private.partner_stats(p_partner uuid) returns json language sql stable security definer set search_path = '' as $$
  with pa as (select * from public.partners where id = p_partner),
  o as (select date_trunc('month', o.shipped_at)::date m, count(*) n from public.orders o join public.clients c on c.id = o.client_id
        where c.referred_by = p_partner and o.status = 'shipped' and o.shipped_at is not null group by 1)
  select json_build_object(
    'partner', (select json_build_object('id', id, 'name', name, 'email', email, 'code', code, 'commission', commission) from pa),
    'stores', (select coalesce(json_agg(json_build_object('name', c.name, 'status', c.status, 'since', c.created_at) order by c.created_at desc), '[]') from public.clients c where c.referred_by = p_partner),
    'months', (select coalesce(json_agg(json_build_object('month', m, 'orders', n, 'earned', n * (select commission from pa)) order by m desc), '[]') from o),
    'earned', coalesce((select sum(n) from o), 0) * (select commission from pa),
    'paid', coalesce((select sum(amount) from public.partner_payouts where partner_id = p_partner), 0));
$$;

create or replace function public.partner_dashboard() returns json language plpgsql stable security definer set search_path = '' as $$
declare v uuid;
begin
  select id into v from public.partners where user_id = auth.uid();
  if v is null then raise exception 'not a partner'; end if;
  return private.partner_stats(v);
end $$;
revoke all on function public.partner_dashboard() from public, anon;
grant execute on function public.partner_dashboard() to authenticated;

create or replace function public.admin_partners() returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return (select coalesce(json_agg(private.partner_stats(p.id) order by p.created_at desc), '[]') from public.partners p);
end $$;
revoke all on function public.admin_partners() from public, anon;
grant execute on function public.admin_partners() to authenticated;

create or replace function public.admin_save_partner(p_id uuid, p_name text, p_email text, p_code text, p_commission numeric)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; u uuid;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  select id into u from auth.users where lower(email) = lower(trim(p_email));
  if p_id is null then
    insert into public.partners (name, email, code, commission, user_id) values (trim(p_name), lower(trim(p_email)), lower(trim(p_code)), coalesce(p_commission,0), u) returning id into v;
  else
    update public.partners set name = trim(p_name), email = lower(trim(p_email)), code = lower(trim(p_code)), commission = coalesce(p_commission,0), user_id = coalesce(user_id, u) where id = p_id returning id into v;
  end if;
  return v;
end $$;
revoke all on function public.admin_save_partner(uuid,text,text,text,numeric) from public, anon;
grant execute on function public.admin_save_partner(uuid,text,text,text,numeric) to authenticated;

create or replace function public.admin_set_referrer(p_client uuid, p_partner uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  update public.clients set referred_by = p_partner where id = p_client;
end $$;
revoke all on function public.admin_set_referrer(uuid,uuid) from public, anon;
grant execute on function public.admin_set_referrer(uuid,uuid) to authenticated;

-- signup: agents and partners get no store account; clients remember who referred them (?ref=code)
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = '' as $$
declare v_client uuid; v_admin boolean; v_agent boolean; v_partner uuid; v_ref uuid;
begin
  select exists (select 1 from private.admin_emails a where lower(a.email) = lower(new.email)) into v_admin;
  select exists (select 1 from private.agent_emails a where lower(a.email) = lower(new.email)) into v_agent;
  select id into v_partner from public.partners p where lower(p.email) = lower(new.email);
  if v_admin then
    insert into public.profiles (id, email, full_name, role) values (new.id, new.email, new.raw_user_meta_data->>'full_name', 'admin');
  elsif v_agent then
    insert into public.profiles (id, email, full_name, role) values (new.id, new.email, new.raw_user_meta_data->>'full_name', 'client');
    insert into public.agents (user_id, name) values (new.id, coalesce(new.raw_user_meta_data->>'full_name', new.email));
  elsif v_partner is not null then
    insert into public.profiles (id, email, full_name, role) values (new.id, new.email, new.raw_user_meta_data->>'full_name', 'client');
    update public.partners set user_id = new.id where id = v_partner;
  else
    select id into v_ref from public.partners where code = lower(nullif(new.raw_user_meta_data->>'ref',''));
    insert into public.clients (name, contact_email, store_url, referred_by)
      values (coalesce(nullif(new.raw_user_meta_data->>'company',''), new.email), new.email, nullif(new.raw_user_meta_data->>'store_url',''), v_ref)
      returning id into v_client;
    insert into public.profiles (id, email, full_name, role, client_id) values (new.id, new.email, new.raw_user_meta_data->>'full_name', 'client', v_client);
  end if;
  return new;
end $$;

-- whoami knows partners (needs the partners table above)
create or replace function public.whoami() returns json language sql stable security definer set search_path = '' as $$
  select json_build_object('id', p.id, 'email', p.email, 'full_name', p.full_name,
    'role', case when exists (select 1 from public.agents a where a.user_id = p.id) then 'agent'
                 when exists (select 1 from public.partners x where x.user_id = p.id) and p.client_id is null and p.role <> 'admin' then 'partner'
                 else p.role end,
    'client', (select json_build_object('id', c.id, 'name', c.name, 'store_url', c.store_url, 'whatsapp', c.whatsapp, 'status', c.status,
                 'company_name', c.company_name, 'billing_address', c.billing_address, 'country', c.country, 'vat_id', c.vat_id)
               from public.clients c where c.id = p.client_id))
  from public.profiles p where p.id = auth.uid();
$$;

-- ===== Claims: lost, damaged or wrong item =====
create table if not exists public.claims (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete cascade,
  type text not null check (type in ('lost','damaged','wrong')),
  note text,
  photos text[] not null default '{}',
  status text not null default 'open' check (status in ('open','reshipped','credited','rejected')),
  amount numeric(12,2),
  resolution text,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references auth.users(id) on delete set null
);
create unique index if not exists claims_one_open_per_order on public.claims(order_id) where status = 'open';
alter table public.claims enable row level security;
create policy admin_all on public.claims for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
create policy client_read on public.claims for select to authenticated using (client_id = (select public.my_client_id()));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('claims', 'claims', false, 10485760, array['image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do nothing;
create policy claims_client_write on storage.objects for insert to authenticated
  with check (bucket_id = 'claims' and (storage.foldername(name))[1] = (select public.my_client_id())::text);
create policy claims_read on storage.objects for select to authenticated
  using (bucket_id = 'claims' and ((select public.is_admin()) or (storage.foldername(name))[1] = (select public.my_client_id())::text));

create or replace function public.client_open_claim(p_order uuid, p_type text, p_note text, p_photos text[])
returns uuid language plpgsql security definer set search_path = '' as $$
declare o public.orders%rowtype; v uuid := public.my_client_id(); v_id uuid;
begin
  select * into o from public.orders x where x.id = p_order and x.client_id = v;
  if not found then raise exception 'order not found'; end if;
  if o.status <> 'shipped' or o.shipped_at is null then raise exception 'You can report a problem once the order has shipped.'; end if;
  if p_type = 'lost' and o.shipped_at > now() - interval '30 days' then
    raise exception 'A parcel counts as lost 30 days after shipping (%). Until then it is usually still on its way: check the tracking.', to_char(o.shipped_at + interval '30 days', 'DD Mon YYYY');
  end if;
  if p_type in ('damaged','wrong') and coalesce(array_length(p_photos,1),0) = 0 then raise exception 'Add at least one photo of the item.'; end if;
  if exists (select 1 from unnest(coalesce(p_photos,'{}')) ph where ph not like v::text || '/%') then raise exception 'invalid photo'; end if;
  insert into public.claims (client_id, order_id, type, note, photos) values (v, o.id, p_type, nullif(trim(p_note),''), coalesce(p_photos,'{}')) returning claims.id into v_id;
  insert into public.messages (client_id, order_id, from_admin, author_id, body)
    values (v, o.id, false, auth.uid(), 'Reported a problem: '||p_type||coalesce(' · '||nullif(trim(p_note),''),''));
  return v_id;
exception when unique_violation then raise exception 'There is already an open report for this order.';
end $$;
revoke all on function public.client_open_claim(uuid,text,text,text[]) from public, anon;
grant execute on function public.client_open_claim(uuid,text,text,text[]) to authenticated;

-- decision: 'reship' (order goes back to the agent, free), 'credit' (order price back to the balance), 'reject'
create or replace function public.admin_decide_claim(p_claim uuid, p_decision text, p_note text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare cl public.claims%rowtype; o public.orders%rowtype; amt numeric;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  select * into cl from public.claims where id = p_claim for update;
  if not found or cl.status <> 'open' then raise exception 'claim is not open'; end if;
  select * into o from public.orders where id = cl.order_id for update;
  if p_decision = 'credit' then
    amt := coalesce(o.price_total, 0);
    insert into public.ledger (client_id, type, amount, order_id, description, created_by)
      values (cl.client_id, 'refund', amt, o.id, 'Credit for '||cl.type||' parcel, order '||coalesce(o.order_number,''), auth.uid());
    update public.claims set status = 'credited', amount = amt, resolution = p_note, decided_at = now(), decided_by = auth.uid() where id = cl.id;
  elsif p_decision = 'reship' then
    update public.orders set status = 'paid', status_note = 'Reship ('||cl.type||'). Previous tracking: '||coalesce(o.tracking_number,'–'),
      tracking_number = null, tracking_company = null, tracking_url = null, shipped_at = null, agent_seen_at = null where id = o.id;
    update public.claims set status = 'reshipped', resolution = p_note, decided_at = now(), decided_by = auth.uid() where id = cl.id;
  elsif p_decision = 'reject' then
    update public.claims set status = 'rejected', resolution = p_note, decided_at = now(), decided_by = auth.uid() where id = cl.id;
  else raise exception 'unknown decision'; end if;
  insert into public.messages (client_id, order_id, from_admin, author_id, body)
    values (cl.client_id, o.id, true, auth.uid(), case p_decision
      when 'credit' then 'We credited '||to_char(amt, 'FM999990.00')||' EUR to your balance for this order.'
      when 'reship' then 'We are sending this order again, at no cost to you. You get a new tracking number once it ships.'
      else 'We looked at your report and cannot accept it.' end || coalesce(' '||nullif(trim(p_note),''), ''));
  return json_build_object('status', p_decision, 'balance', public.client_balance(cl.client_id));
end $$;
revoke all on function public.admin_decide_claim(uuid,text,text) from public, anon;
grant execute on function public.admin_decide_claim(uuid,text,text) to authenticated;

-- partner commission: leave out orders that were credited after a claim (needs the claims table above)
create or replace function private.partner_stats(p_partner uuid) returns json language sql stable security definer set search_path = '' as $$
  with pa as (select * from public.partners where id = p_partner),
  o as (select date_trunc('month', o.shipped_at)::date m, count(*) n from public.orders o join public.clients c on c.id = o.client_id
        where c.referred_by = p_partner and o.status = 'shipped' and o.shipped_at is not null
          and not exists (select 1 from public.claims k where k.order_id = o.id and k.status = 'credited') group by 1)
  select json_build_object(
    'partner', (select json_build_object('id', id, 'name', name, 'email', email, 'code', code, 'commission', commission) from pa),
    'stores', (select coalesce(json_agg(json_build_object('name', c.name, 'status', c.status, 'since', c.created_at) order by c.created_at desc), '[]') from public.clients c where c.referred_by = p_partner),
    'months', (select coalesce(json_agg(json_build_object('month', m, 'orders', n, 'earned', n * (select commission from pa)) order by m desc), '[]') from o),
    'earned', coalesce((select sum(n) from o), 0) * (select commission from pa),
    'paid', coalesce((select sum(amount) from public.partner_payouts where partner_id = p_partner), 0));
$$;
