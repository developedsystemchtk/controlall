-- =====================================================================
-- 002: ดูข้อมูลครุภัณฑ์แบบไม่ต้องล็อกอิน (สแกน QR จากหน้าล็อกอิน)
-- รันไฟล์นี้ครั้งเดียวใน Supabase > SQL Editor (ต่อจาก 001_backend.sql)
--
-- หลักการความปลอดภัย
--   * ค้นหาได้เฉพาะ "รหัสที่ตรงทั้งหมด" (AssetCode / QRCodeValue / AssetID) ไม่มีการไล่รายการ
--   * คืนเฉพาะข้อมูลที่ติดอยู่กับตัวครุภัณฑ์อยู่แล้ว: ชื่อ หมวด ยี่ห้อ/รุ่น Serial สภาพ ที่ตั้ง สถานะ รูป
--   * ไม่คืน: ราคา หมายเหตุภายใน ชื่อ/รหัสผู้ยืม ผู้อนุมัติ ประวัติการยืม
--     (กรณีถูกยืมจะบอกแค่ "หน่วยงานผู้ยืม" และวันครบกำหนดคืน)
--   * จำกัดอัตราโดยรวม 120 ครั้ง/นาที กันการไล่เดารหัสแบบรัว
-- =====================================================================

create table if not exists af.public_lookups (
  id bigserial primary key,
  at timestamptz not null default now()
);
create index if not exists public_lookups_at on af.public_lookups (at);

create or replace function public.rpc_public_asset_lookup(p_code text) returns jsonb
language plpgsql security definer set search_path = af, public, pg_catalog as $$
declare
  c text := lower(btrim(coalesce(p_code, '')));
  a af.assets%rowtype;
  b af.borrows%rowtype;
  n int;
  dname text;
begin
  if length(c) < 2 or length(c) > 120 then
    return jsonb_build_object('ok', false, 'code', 'bad_code', 'message', 'รหัสไม่ถูกต้อง');
  end if;

  select count(*) into n from af.public_lookups where at > now() - interval '1 minute';
  if n >= 120 then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'มีการค้นหาถี่เกินไป กรุณารอสักครู่แล้วลองใหม่');
  end if;
  insert into af.public_lookups default values;
  delete from af.public_lookups where at < now() - interval '1 hour';

  select * into a from af.assets
   where lower("AssetCode") = c or lower("QRCodeValue") = c or lower("AssetID") = c
   limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'ไม่พบครุภัณฑ์รหัสนี้ในระบบ');
  end if;

  select "DeptName" into dname from af.departments where "DeptID" = a."DepartmentID";

  select * into b from af.borrows
   where "AssetID" = a."AssetID" and "Status" in ('กำลังยืม', 'อนุมัติแล้ว')
   order by "CreatedAt" desc limit 1;

  return jsonb_build_object(
    'ok', true,
    'asset', jsonb_build_object(
      'AssetCode',      a."AssetCode",
      'AssetName',      a."AssetName",
      'Category',       a."Category",
      'BrandModel',     a."BrandModel",
      'SerialNo',       a."SerialNo",
      'DepartmentName', coalesce(dname, ''),
      'Location',       a."Location",
      'PurchaseDate',   a."PurchaseDate",
      'Condition',      a."Condition",
      'Status',         a."Status",
      'ImageUrl',       case when a."ImageUrl" ~ '^(https?://|data:image/)' then a."ImageUrl" else '' end,
      'UpdatedAt',      a."UpdatedAt"
    ),
    'borrow', case when b."BorrowID" is null then null
                   else jsonb_build_object('Status', b."Status", 'BorrowerDept', b."BorrowerDept", 'DueDate', b."DueDate") end
  );
end $$;

revoke all on function public.rpc_public_asset_lookup(text) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'grant execute on function public.rpc_public_asset_lookup(text) to anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.rpc_public_asset_lookup(text) to authenticated';
  end if;
end $$;
