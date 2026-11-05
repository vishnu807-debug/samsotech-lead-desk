-- Lets sales engineers submit their own OUTBOUND leads.
-- Run once in Supabase → SQL Editor if you already ran 01_schema.sql before this change (fresh installs get it from 01_schema.sql too).

-- Sales may insert a lead only if: it is assigned to themselves, it starts as "New" (back office still verifies it), and it is Outbound.
drop policy if exists leads_insert on public.leads;
create policy leads_insert on public.leads for insert to authenticated with check (
  public.my_role() = 'backoffice'
  or (public.my_role() = 'sales'
      and public.my_engineer() <> ''
      and lower(assigned_to) = lower(public.my_engineer())
      and status = 'New'
      and doc->>'category' = 'Outbound')
);

-- Sales may create a new account (property) record, but not change existing ones.
drop policy if exists accounts_insert_sales on public.accounts;
create policy accounts_insert_sales on public.accounts for insert to authenticated
  with check (public.my_role() = 'sales');

-- Sales may take the next lead reference number.
create or replace function public.next_lead_ref() returns text
language plpgsql security definer set search_path = public as $$
declare y int := extract(year from now() at time zone 'Asia/Dubai')::int; n int; ref text;
begin
  if public.my_role() is null or public.my_role() not in ('backoffice','sales') then
    raise exception 'You are not allowed to create leads' using errcode = '42501';
  end if;
  loop
    insert into public.lead_counter(year, next) values (y, 2)
      on conflict (year) do update set next = public.lead_counter.next + 1
      returning next - 1 into n;
    ref := 'LD' || y || '-' || lpad(n::text, 4, '0');
    exit when not exists (select 1 from public.leads where id = ref);
  end loop;
  return ref;
end $$;
