-- Add the first back-office user (you). Change the email below to the address you'll sign in with, then run.
-- After this, add everyone else from inside Lead Desk: Products & settings → Users and access.
insert into public.members (email, role, engineer)
values (lower('you@samsotech.com'), 'supervisor', null)
on conflict (email) do update set role = 'supervisor', active = true;
