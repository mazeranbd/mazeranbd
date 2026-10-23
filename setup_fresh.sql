-- MAZÉRAN FRESH SETUP (new Supabase project). Paste ALL of this once into SQL Editor > Run.
-- Part 1: base tables
-- MAZÉRAN database. Paste into Supabase > SQL Editor > Run.
create table public.admins(user_id uuid primary key references auth.users(id) on delete cascade);
create table public.settings(key text primary key, value text not null default '');
create table public.products(
 id uuid primary key default gen_random_uuid(),
 code text not null unique check (code ~ '^[0-9A-F]{4}$'),
 name text not null check (length(name) between 1 and 120),
 category text not null check (length(category) between 1 and 40),
 notes text not null default '', image text not null default '',
 stock_ml int not null default 0 check (stock_ml >= 0),
 price_3 int not null check (price_3 > 0), price_6 int not null check (price_6 > 0), price_12 int not null check (price_12 > 0),
 collections text[] not null default '{}',
 offer_enabled boolean not null default false,
 discount_type text not null default 'flat' check (discount_type in ('flat','percent')),
 discount_value numeric not null default 0 check (discount_value >= 0),
 offer_ends timestamptz,
 created_at timestamptz not null default now(),
 check (discount_type <> 'percent' or discount_value < 100),
 check (discount_type <> 'flat' or discount_value <= least(price_3, price_6, price_12))
);
create function public.is_admin() returns boolean language sql stable security definer set search_path = public
as $$ select exists(select 1 from public.admins where user_id = auth.uid()) $$;

alter table public.admins enable row level security;
alter table public.settings enable row level security;
alter table public.products enable row level security;
create policy "own admin row" on public.admins for select to authenticated using (user_id = auth.uid());
create policy "public read" on public.settings for select to anon, authenticated using (true);
create policy "admin write" on public.settings for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "public read" on public.products for select to anon, authenticated using (true);
create policy "admin write" on public.products for all to authenticated using (public.is_admin()) with check (public.is_admin());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media','media',true,2097152,array['image/jpeg','image/png','image/webp']) on conflict (id) do nothing;
create policy "admin upload" on storage.objects for insert to authenticated with check (bucket_id='media' and public.is_admin());
create policy "admin update" on storage.objects for update to authenticated using (bucket_id='media' and public.is_admin());
create policy "admin delete" on storage.objects for delete to authenticated using (bucket_id='media' and public.is_admin());

-- AFTER creating your admin user in Authentication > Users, run (with your email):
-- insert into public.admins select id from auth.users where email = 'YOUR_EMAIL';

-- Part 2: full upgrade
-- MAZÉRAN migration 001 — additive and safe to re-run. Never drops tables.
-- Run in Supabase > SQL Editor. Admin user must already exist in public.admins.
begin;

create or replace function public.set_updated_at() returns trigger language plpgsql as
$$ begin new.updated_at := now(); return new; end $$;

-- ===== Categories =====
create table if not exists public.categories(
 id uuid primary key default gen_random_uuid(),
 name text not null unique check (length(name) between 1 and 40),
 description text not null default '',
 sort_order int not null default 0,
 active boolean not null default true,
 created_at timestamptz not null default now());

-- ===== Products: extend, keep old columns =====
alter table public.products
 add column if not exists slug text,
 add column if not exists description text not null default '',
 add column if not exists category_id uuid references public.categories(id) on update cascade,
 add column if not exists sort_order int not null default 0,
 add column if not exists updated_at timestamptz not null default now();
alter table public.products add column if not exists status text not null default 'active'
 check (status in ('draft','active','archived'));
alter table public.products alter column status set default 'draft';  -- new rows start as draft
alter table public.products alter column category drop not null;
alter table public.products alter column price_3 drop not null;
alter table public.products alter column price_6 drop not null;
alter table public.products alter column price_12 drop not null;
create unique index if not exists products_slug_key on public.products(slug) where slug is not null;
drop trigger if exists trg_products_upd on public.products;
create trigger trg_products_upd before update on public.products for each row execute function public.set_updated_at();

insert into public.categories(name) select distinct category from public.products where category is not null on conflict (name) do nothing;
update public.products p set category_id=c.id from public.categories c where c.name=p.category and p.category_id is null;
update public.products p set slug = lower(code) || coalesce('-'||nullif(trim(both '-' from regexp_replace(lower(name),'[^a-z0-9]+','-','g')),''),'') where slug is null;

-- ===== Variants and sizes (Oil / Perfume, any size) =====
create table if not exists public.product_variants(
 id uuid primary key default gen_random_uuid(),
 product_id uuid not null references public.products(id) on delete cascade,
 type text not null check (type in ('oil','perfume')),
 active boolean not null default true,
 created_at timestamptz not null default now(),
 unique(product_id,type));
create table if not exists public.variant_sizes(
 id uuid primary key default gen_random_uuid(),
 variant_id uuid not null references public.product_variants(id) on delete cascade,
 size_ml numeric(6,2) not null check (size_ml > 0),
 price int not null check (price > 0),
 stock int not null default 0 check (stock >= 0),
 active boolean not null default true,
 image text not null default '',
 updated_at timestamptz not null default now(),
 unique(variant_id,size_ml));
drop trigger if exists trg_vs_upd on public.variant_sizes;
create trigger trg_vs_upd before update on public.variant_sizes for each row execute function public.set_updated_at();
-- Internal costs live in their own admin-only table (never exposed to customers)
create table if not exists public.size_costs(
 variant_size_id uuid primary key references public.variant_sizes(id) on delete cascade,
 unit_cost numeric(10,2) not null check (unit_cost >= 0),
 updated_at timestamptz not null default now());

-- Backfill existing products as Perfume 3/6/12 ml (stock_ml moved to the 3 ml size; re-split in Admin)
insert into public.product_variants(product_id,type) select id,'perfume' from public.products where price_3 is not null on conflict do nothing;
insert into public.variant_sizes(variant_id,size_ml,price,stock)
select pv.id,s.sz,case s.sz when 3 then p.price_3 when 6 then p.price_6 else p.price_12 end,case when s.sz=3 then p.stock_ml/3 else 0 end
from public.products p join public.product_variants pv on pv.product_id=p.id and pv.type='perfume'
cross join (values(3),(6),(12)) s(sz) where p.price_3 is not null on conflict (variant_id,size_ml) do nothing;

-- ===== Delivery areas =====
create table if not exists public.delivery_areas(
 id uuid primary key default gen_random_uuid(),
 name text not null unique check (length(name) between 1 and 80),
 category text not null default 'standard',
 fee int not null check (fee >= 0),
 note text not null default '',
 active boolean not null default true,
 sort_order int not null default 0);
insert into public.delivery_areas(name,category,fee,sort_order,active) values
 ('Inside Dhaka','inside',80,1,true),
 ('Outside Dhaka','standard',130,2,true),
 ('Special nearby area (edit in Admin)','special',100,3,false) on conflict (name) do nothing;

-- ===== Orders =====
create sequence if not exists public.order_seq;
create table if not exists public.orders(
 id uuid primary key default gen_random_uuid(),
 order_no text not null unique,
 idempotency_key text not null unique,
 customer_name text not null, phone text not null, address text not null,
 area_id uuid references public.delivery_areas(id) on delete set null,
 area_name text not null, delivery_fee int not null check (delivery_fee >= 0),
 subtotal int not null check (subtotal >= 0), discount int not null default 0 check (discount >= 0),
 coupon_code text, total int not null check (total >= 0),
 payment_method text not null check (payment_method in ('cod','bkash')),
 payment_status text not null default 'unpaid' check (payment_status in ('unpaid','submitted','verified','rejected')),
 payment_ref text not null default '',
 status text not null default 'pending' check (status in ('pending','confirmed','processing','shipped','delivered','cancelled')),
 is_reviewed boolean not null default false,
 customer_note text not null default '', special_request text not null default '', admin_note text not null default '',
 stock_deducted boolean not null default false, stock_restored boolean not null default false,
 confirmed_at timestamptz, confirmed_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create index if not exists orders_status_idx on public.orders(status,created_at desc);
drop trigger if exists trg_orders_upd on public.orders;
create trigger trg_orders_upd before update on public.orders for each row execute function public.set_updated_at();

create table if not exists public.order_items(
 id uuid primary key default gen_random_uuid(),
 order_id uuid not null references public.orders(id) on delete cascade,
 variant_size_id uuid references public.variant_sizes(id) on delete set null,
 product_id uuid, product_name text not null, product_code text, variant_type text not null,
 size_ml numeric(6,2) not null, qty int not null check (qty > 0),
 unit_price int not null check (unit_price >= 0), line_total int not null,
 unit_cost_snapshot numeric(10,2));
create index if not exists order_items_order_idx on public.order_items(order_id);
create table if not exists public.order_status_history(
 id bigint generated always as identity primary key,
 order_id uuid not null references public.orders(id) on delete cascade,
 from_status text, to_status text not null, actor uuid, note text not null default '', created_at timestamptz not null default now());
create table if not exists public.inventory_movements(
 id bigint generated always as identity primary key,
 variant_size_id uuid references public.variant_sizes(id) on delete set null,
 delta int not null, reason text not null, order_id uuid references public.orders(id) on delete set null,
 actor uuid, created_at timestamptz not null default now());

-- ===== Row Level Security =====
do $$ declare t text; begin
 foreach t in array array['categories','product_variants','variant_sizes','size_costs','delivery_areas','orders','order_items','order_status_history','inventory_movements'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('drop policy if exists "admin all" on public.%I',t);
  execute format('create policy "admin all" on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())',t);
 end loop; end $$;
-- Public (storefront) read access only where intended. orders/items/costs/movements: admin only.
drop policy if exists "public read" on public.categories;
create policy "public read" on public.categories for select to anon, authenticated using (active);
drop policy if exists "public read" on public.product_variants;
create policy "public read" on public.product_variants for select to anon, authenticated using (active);
drop policy if exists "public read" on public.variant_sizes;
create policy "public read" on public.variant_sizes for select to anon, authenticated using (active);
drop policy if exists "public read" on public.delivery_areas;
create policy "public read" on public.delivery_areas for select to anon, authenticated using (active);
-- Products: customers see only active products
drop policy if exists "public read" on public.products;
create policy "public read" on public.products for select to anon, authenticated using (status='active' or public.is_admin());

-- ===== Place order (customer) — all prices/fees recomputed server-side =====
create or replace function public.place_order(p_key text,p_name text,p_phone text,p_address text,p_area uuid,p_pay text,p_ref text,p_note text,p_special text,p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.orders; a public.delivery_areas; r record; it record; v_id uuid := gen_random_uuid(); v_phone text; v_unit int; v_sub int := 0; v_no text;
begin
 if p_key is null or length(p_key) not between 8 and 80 then raise exception 'Invalid request'; end if;
 select * into o from public.orders where idempotency_key=p_key;
 if found then return jsonb_build_object('order_no',o.order_no,'total',o.total,'duplicate',true); end if;
 v_phone := regexp_replace(coalesce(p_phone,''),'[\s-]','','g');
 if length(trim(coalesce(p_name,''))) < 3 then raise exception 'Enter your full name'; end if;
 if v_phone !~ '^(\+?880|0)1[3-9][0-9]{8}$' then raise exception 'Enter a valid Bangladeshi phone number'; end if;
 if length(trim(coalesce(p_address,''))) < 10 then raise exception 'Enter your full delivery address'; end if;
 if p_pay not in ('cod','bkash') then raise exception 'Invalid payment method'; end if;
 if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 50 then raise exception 'Your cart is empty'; end if;
 select * into a from public.delivery_areas where id=p_area and active;
 if not found then raise exception 'Select a delivery area'; end if;
 v_no := 'MZ'||to_char(now() at time zone 'Asia/Dhaka','YYMMDD')||'-'||lpad(nextval('public.order_seq')::text,4,'0');
 insert into public.orders(id,order_no,idempotency_key,customer_name,phone,address,area_id,area_name,delivery_fee,subtotal,total,payment_method,payment_status,payment_ref,customer_note,special_request)
 values(v_id,v_no,p_key,trim(p_name),v_phone,trim(p_address),a.id,a.name,a.fee,0,0,p_pay,case when coalesce(trim(p_ref),'')<>'' then 'submitted' else 'unpaid' end,left(coalesce(trim(p_ref),''),40),left(coalesce(p_note,''),500),left(coalesce(p_special,''),500));
 for it in select (e->>'size_id')::uuid sid, sum((e->>'qty')::int)::int q from jsonb_array_elements(p_items) e group by 1 loop
  if it.q not between 1 and 50 then raise exception 'Invalid quantity'; end if;
  select vs.id,vs.size_ml,vs.price,vs.stock,pv.type,p.id pid,p.name,p.code,p.offer_enabled,p.discount_type,p.discount_value,p.offer_ends,sc.unit_cost into r
  from public.variant_sizes vs join public.product_variants pv on pv.id=vs.variant_id join public.products p on p.id=pv.product_id
  left join public.size_costs sc on sc.variant_size_id=vs.id
  where vs.id=it.sid and vs.active and pv.active and p.status='active';
  if not found then raise exception 'An item in your cart is no longer available'; end if;
  if r.stock < it.q then raise exception 'Not enough stock for % (% ml)',r.name,r.size_ml; end if;
  v_unit := r.price;
  if r.offer_enabled and coalesce(r.discount_value,0) > 0 and (r.offer_ends is null or r.offer_ends > now()) then
   v_unit := case when r.discount_type='percent' then round(r.price*(1-r.discount_value/100))::int else r.price - r.discount_value::int end;
  end if;
  v_unit := greatest(v_unit,0);
  insert into public.order_items(order_id,variant_size_id,product_id,product_name,product_code,variant_type,size_ml,qty,unit_price,line_total,unit_cost_snapshot)
  values(v_id,r.id,r.pid,r.name,r.code,r.type,r.size_ml,it.q,v_unit,v_unit*it.q,r.unit_cost);
  v_sub := v_sub + v_unit*it.q;
 end loop;
 update public.orders set subtotal=v_sub,total=v_sub+a.fee where id=v_id;
 insert into public.order_status_history(order_id,from_status,to_status,note) values(v_id,null,'pending','Order placed');
 return jsonb_build_object('order_no',v_no,'total',v_sub+a.fee,'duplicate',false);
exception when unique_violation then
 select * into o from public.orders where idempotency_key=p_key;
 if found then return jsonb_build_object('order_no',o.order_no,'total',o.total,'duplicate',true); end if;
 raise;
end $$;

-- ===== Admin: confirm (atomic, idempotent) =====
create or replace function public.admin_confirm_order(p_order uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.orders; r record;
begin
 if not public.is_admin() then raise exception 'Not authorized'; end if;
 select * into o from public.orders where id=p_order for update;
 if not found then raise exception 'Order not found'; end if;
 if o.stock_deducted then return jsonb_build_object('ok',true,'already',true); end if;
 if o.status <> 'pending' then raise exception 'Only pending orders can be confirmed'; end if;
 if exists(select 1 from public.order_items where order_id=p_order and variant_size_id is null) then raise exception 'An item no longer exists; cannot confirm'; end if;
 for r in select oi.variant_size_id sid,sum(oi.qty)::int q from public.order_items oi where oi.order_id=p_order group by 1 order by 1 loop
  perform 1 from public.variant_sizes where id=r.sid for update;
  update public.variant_sizes set stock=stock-r.q where id=r.sid and stock>=r.q;
  if not found then raise exception 'Insufficient stock — order not confirmed'; end if;
  insert into public.inventory_movements(variant_size_id,delta,reason,order_id,actor) values(r.sid,-r.q,'order confirmed',p_order,auth.uid());
 end loop;
 update public.orders set status='confirmed',stock_deducted=true,is_reviewed=true,confirmed_at=now(),confirmed_by=auth.uid() where id=p_order;
 insert into public.order_status_history(order_id,from_status,to_status,actor) values(p_order,'pending','confirmed',auth.uid());
 return jsonb_build_object('ok',true,'already',false);
end $$;

-- ===== Admin: cancel (restores stock at most once) =====
create or replace function public.admin_cancel_order(p_order uuid,p_reason text default '') returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.orders; r record;
begin
 if not public.is_admin() then raise exception 'Not authorized'; end if;
 select * into o from public.orders where id=p_order for update;
 if not found then raise exception 'Order not found'; end if;
 if o.status = 'cancelled' then return jsonb_build_object('ok',true,'already',true); end if;
 if o.status in ('shipped','delivered') then raise exception 'Shipped/delivered orders need a return process, not cancellation'; end if;
 if o.stock_deducted and not o.stock_restored then
  for r in select variant_size_id sid,sum(qty)::int q from public.order_items where order_id=p_order and variant_size_id is not null group by 1 order by 1 loop
   update public.variant_sizes set stock=stock+r.q where id=r.sid;
   insert into public.inventory_movements(variant_size_id,delta,reason,order_id,actor) values(r.sid,r.q,'order cancelled',p_order,auth.uid());
  end loop;
 end if;
 update public.orders set status='cancelled',is_reviewed=true,stock_restored=(stock_deducted or stock_restored),admin_note=case when coalesce(p_reason,'')='' then admin_note else left(p_reason,500) end where id=p_order;
 insert into public.order_status_history(order_id,from_status,to_status,actor,note) values(p_order,o.status,'cancelled',auth.uid(),coalesce(p_reason,''));
 return jsonb_build_object('ok',true,'already',false);
end $$;

-- ===== Admin: move forward (confirmed > processing > shipped > delivered) =====
create or replace function public.admin_set_status(p_order uuid,p_status text) returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
 if not public.is_admin() then raise exception 'Not authorized'; end if;
 select * into o from public.orders where id=p_order for update;
 if not found then raise exception 'Order not found'; end if;
 if not ((o.status='confirmed' and p_status='processing') or (o.status='processing' and p_status='shipped') or (o.status='shipped' and p_status='delivered')) then
  raise exception 'Invalid status change % -> %',o.status,p_status; end if;
 update public.orders set status=p_status where id=p_order;
 insert into public.order_status_history(order_id,from_status,to_status,actor) values(p_order,o.status,p_status,auth.uid());
 return jsonb_build_object('ok',true);
end $$;

-- ===== Admin: manual stock adjustment with reason =====
create or replace function public.admin_adjust_stock(p_size uuid,p_delta int,p_reason text) returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
 if not public.is_admin() then raise exception 'Not authorized'; end if;
 if coalesce(trim(p_reason),'')='' or p_delta=0 then raise exception 'A reason and a non-zero change are required'; end if;
 update public.variant_sizes set stock=stock+p_delta where id=p_size and stock+p_delta>=0 returning stock into n;
 if not found then raise exception 'Stock cannot go below zero'; end if;
 insert into public.inventory_movements(variant_size_id,delta,reason,actor) values(p_size,p_delta,left(p_reason,200),auth.uid());
 return n;
end $$;

revoke all on function public.place_order(text,text,text,text,uuid,text,text,text,text,jsonb) from public;
grant execute on function public.place_order(text,text,text,text,uuid,text,text,text,text,jsonb) to anon, authenticated;
revoke all on function public.admin_confirm_order(uuid), public.admin_cancel_order(uuid,text), public.admin_set_status(uuid,text), public.admin_adjust_stock(uuid,int,text) from public, anon;
grant execute on function public.admin_confirm_order(uuid), public.admin_cancel_order(uuid,text), public.admin_set_status(uuid,text), public.admin_adjust_stock(uuid,int,text) to authenticated;

-- ===== Storage: hero videos (public read, admin write) =====
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('videos','videos',true,52428800,array['video/mp4']) on conflict (id) do nothing;
drop policy if exists "videos admin insert" on storage.objects;
drop policy if exists "videos admin update" on storage.objects;
drop policy if exists "videos admin delete" on storage.objects;
create policy "videos admin insert" on storage.objects for insert to authenticated with check (bucket_id='videos' and public.is_admin());
create policy "videos admin update" on storage.objects for update to authenticated using (bucket_id='videos' and public.is_admin());
create policy "videos admin delete" on storage.objects for delete to authenticated using (bucket_id='videos' and public.is_admin());

-- ===== Editable policies (stored in settings; only fills if empty/missing) =====
insert into public.settings(key,value) values
('policy_return',$t$RETURN & REFUND POLICY
(Draft written for you. Items marked [CONFIRM] must be set by MAZÉRAN before relying on them. Edit this text in Admin > Settings.)

1. Change of mind before delivery
You may ask to cancel an order before it is shipped by contacting us on WhatsApp with your Order ID. If payment was already made, we will tell you how the refund will be handled. [CONFIRM: cancellation deadline and refund method]

2. Change of mind after receipt
Because fragrances are personal and sealed products cannot be re-sold once opened, requests after receipt are reviewed case by case. [CONFIRM: whether you accept returns of unopened products, and the time limit]

3. Damaged, wrong or suspected quality problems
If your item arrives damaged, is not what you ordered, or you believe there is a quality problem, contact us within [CONFIRM: number of hours/days] of receiving it. This does not limit any rights you have under the law.

4. How to make a complaint
Message us on WhatsApp (+880 1930-986902) with: your Order ID, your name and phone number, a short description, and clear photos or a video of the product and packaging.

5. Inspection
We will review your complaint, and may compare the product with our reference sample where available. We will reply with our decision and the next step. [CONFIRM: expected reply time]

6. Returns and shipping
If a return is needed, we will explain how to send the item. [CONFIRM: who pays return shipping in each case]

7. Refunds
Approved refunds are paid back to you by the agreed method (for example bKash). [CONFIRM: refund processing time]

Nothing in this policy removes your legal rights as a consumer in Bangladesh.$t$),
('policy_privacy',$t$PRIVACY POLICY
(Draft written for you. Items marked [CONFIRM] must be set by MAZÉRAN. Edit this text in Admin > Settings. Effective date: [CONFIRM])

1. Who we are
MAZÉRAN, an online fragrance business in Bangladesh. Contact: WhatsApp +880 1930-986902. [CONFIRM: business legal name, address, email]

2. What we collect
When you place an order we collect your name, phone number, delivery address and area, the items you order, payment method, and any payment reference (such as a bKash transaction ID) and notes you choose to give. We do not collect more than we need.

3. Why we use it
To process and deliver your order, verify your payment, contact you about your order, handle returns or complaints, and keep business and accounting records.

4. Who handles your data
Your data is stored with Supabase (our database and file storage provider). Order details may be copied to Google Sheets for our internal order tracking, and we may contact you through WhatsApp. These providers may process data outside Bangladesh. We do not sell your information.

5. Security
Access to order data is limited to authorized MAZÉRAN administrators who must sign in. No system is perfectly secure, and we cannot guarantee absolute security.

6. How long we keep it
We keep order records for as long as needed for business, accounting and legal reasons. [CONFIRM: retention period]

7. Your choices
You can ask us on WhatsApp to see, correct, or delete your personal information, subject to records we must keep.

8. Cookies
This website stores your shopping cart in your browser so it is not lost while you browse. [CONFIRM: add details if you use analytics or advertising tools]

9. Children
Our website is not directed at children.

10. Changes
We may update this policy and will change the effective date when we do.$t$)
on conflict (key) do update set value=excluded.value where public.settings.value = '';

-- Realtime for the New Orders counter (admin-only via RLS)
do $$ begin alter publication supabase_realtime add table public.orders; exception when others then null; end $$;

commit;

-- ===== Check after running =====
-- select (select count(*) from products) products, (select count(*) from product_variants) variants, (select count(*) from variant_sizes) sizes, (select count(*) from categories) categories, (select count(*) from delivery_areas) areas;
