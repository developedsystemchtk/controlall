-- =====================================================================
-- ระบบยืม-คืนครุภัณฑ์ โรงพยาบาลสันทราย  |  Backend (Supabase / PostgreSQL)
-- รันไฟล์นี้ทั้งไฟล์ 1 ครั้งใน Supabase > SQL Editor (รันซ้ำได้ ไม่ลบข้อมูลเดิม)
--
-- แนวคิดความปลอดภัย
--   * ตารางทั้งหมดอยู่ใน schema "af" ที่ anon/authenticated เข้าไม่ถึงโดยตรง
--   * หน้าเว็บเรียกได้เฉพาะฟังก์ชัน rpc_* (schema public) เท่านั้น
--   * ทุกฟังก์ชันที่ต้องล็อกอินตรวจ session token + สิทธิ์ (Role) ที่ฝั่งฐานข้อมูลเสมอ
--     ไม่เชื่อ "ผู้ใช้" ที่หน้าเว็บส่งมา
--   * รหัสผ่านเก็บเป็น bcrypt, session เก็บเป็น SHA-256 ของ token
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create schema if not exists af;
revoke all on schema af from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on schema af from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on schema af from authenticated';
  end if;
end $$;

-- ---------- sequences ----------
create sequence if not exists af.seq_dept;
create sequence if not exists af.seq_user;
create sequence if not exists af.seq_asset;
create sequence if not exists af.seq_borrow;
create sequence if not exists af.seq_reqcode;
create sequence if not exists af.seq_maint;
create sequence if not exists af.seq_disposal;
create sequence if not exists af.seq_log;

create or replace function af.now_th() returns text
language sql stable set search_path = pg_catalog as $$
  select to_char(now() at time zone 'Asia/Bangkok', 'YYYY-MM-DD HH24:MI:SS')
$$;

create or replace function af.today_th() returns text
language sql stable set search_path = pg_catalog as $$
  select to_char(now() at time zone 'Asia/Bangkok', 'YYYY-MM-DD')
$$;

-- ---------- tables ----------
create table if not exists af.departments (
  "DeptID"       text primary key default ('DEPT-' || lpad(nextval('af.seq_dept')::text, 3, '0')),
  "DeptCode"     text not null default '',
  "DeptName"     text not null,
  "HeadName"     text not null default '',
  "Location"     text not null default '',
  "ContactPhone" text not null default '',
  "Status"       text not null default 'Active' check ("Status" in ('Active','Inactive')),
  "CreatedAt"    text not null default af.now_th()
);

create table if not exists af.users (
  "UserID"       text primary key default ('USR-' || lpad(nextval('af.seq_user')::text, 3, '0')),
  "Username"     text not null,
  "PasswordHash" text not null,
  "FullName"     text not null,
  "Email"        text not null default '',
  "Phone"        text not null default '',
  "Role"         text not null default 'Borrower' check ("Role" in ('SuperAdmin','DeptAdmin','Approver','Borrower')),
  "DepartmentID" text not null references af.departments("DeptID") on update cascade on delete restrict,
  "Status"       text not null default 'Active' check ("Status" in ('Active','Inactive')),
  "LastLogin"    text not null default '',
  "CreatedAt"    text not null default af.now_th()
);
create unique index if not exists users_username_lower on af.users (lower("Username"));

create table if not exists af.assets (
  "AssetID"      text primary key default ('AST-' || lpad(nextval('af.seq_asset')::text, 3, '0')),
  "AssetCode"    text not null,
  "SerialNo"     text not null default '',
  "AssetName"    text not null,
  "Category"     text not null default '',
  "BrandModel"   text not null default '',
  "DepartmentID" text not null references af.departments("DeptID") on update cascade on delete restrict,
  "Location"     text not null default '',
  "PurchaseDate" text not null default '',
  "Price"        numeric(14,2) not null default 0,
  "Condition"    text not null default '',
  "Status"       text not null default 'พร้อมให้ยืม'
                 check ("Status" in ('พร้อมให้ยืม','ถูกยืม','จองแล้ว','ส่งซ่อม','รอตัดจำหน่าย','ตัดจำหน่าย')),
  "ImageUrl"     text not null default '',
  "QRCodeValue"  text not null default '',
  "Notes"        text not null default '',
  "UpdatedAt"    text not null default af.now_th()
);
create unique index if not exists assets_code_lower on af.assets (lower("AssetCode"));

create table if not exists af.borrows (
  "BorrowID"        text primary key default ('BRW-' || lpad(nextval('af.seq_borrow')::text, 3, '0')),
  "RequestCode"     text not null,
  "AssetID"         text not null,
  "AssetCode"       text not null default '',
  "AssetName"       text not null default '',
  "BorrowerID"      text not null,
  "BorrowerName"    text not null default '',
  "BorrowerDept"    text not null default '',
  "OwnerDeptID"     text not null default '',
  "OwnerDeptName"   text not null default '',
  "BorrowDate"      text not null default '',
  "DueDate"         text not null default '',
  "ReturnDate"      text not null default '',
  "Purpose"         text not null default '',
  "LocationUse"     text not null default '',
  "Status"          text not null default 'รออนุมัติ'
                    check ("Status" in ('รออนุมัติ','อนุมัติแล้ว','กำลังยืม','คืนแล้ว','ปฏิเสธ','ยกเลิก')),
  "ApproverID"      text not null default '',
  "ApproverName"    text not null default '',
  "ApprovedAt"      text not null default '',
  "RejectReason"    text not null default '',
  "ConditionBefore" text not null default '',
  "ConditionAfter"  text not null default '',
  "BeforePhotoUrl"  text not null default '',
  "AfterPhotoUrl"   text not null default '',
  "Remarks"         text not null default '',
  "CreatedAt"       text not null default af.now_th(),
  "UpdatedAt"       text not null default af.now_th(),
  "BorrowDays"      integer not null default 1,
  "OverdueDays"     integer not null default 0,
  "OverdueStatus"   text not null default 'ปกติ',
  "ApprovalStatus"  text not null default 'รออนุมัติ',
  "ReceiverName"    text not null default ''
);
create index if not exists borrows_asset on af.borrows ("AssetID");
create index if not exists borrows_borrower on af.borrows ("BorrowerID");

create table if not exists af.maintenances (
  "MaintID"            text primary key default ('MNT-' || lpad(nextval('af.seq_maint')::text, 3, '0')),
  "AssetID"            text not null,
  "AssetCode"          text not null default '',
  "AssetName"          text not null default '',
  "DepartmentID"       text not null default '',
  "ReportedBy"         text not null default '',
  "IssueDetail"        text not null default '',
  "Priority"           text not null default 'ปกติ' check ("Priority" in ('ปกติ','สูง','เร่งด่วนมาก')),
  "VendorOrTechnician" text not null default '',
  "Cost"               numeric(14,2) not null default 0,
  "Status"             text not null default 'แจ้งซ่อม'
                       check ("Status" in ('แจ้งซ่อม','กำลังซ่อม','ซ่อมเสร็จ','ซ่อมไม่ได้-รอตัดจำหน่าย')),
  "ReportedAt"         text not null default af.now_th(),
  "CompletedAt"        text not null default '',
  "AttachmentUrl"      text not null default ''
);

create table if not exists af.disposals (
  "DisposalID"     text primary key default ('DSP-' || lpad(nextval('af.seq_disposal')::text, 3, '0')),
  "AssetID"        text not null,
  "AssetCode"      text not null default '',
  "AssetName"      text not null default '',
  "DepartmentID"   text not null default '',
  "Reason"         text not null default '',
  "DisposalMethod" text not null default '',
  "ApprovedBy"     text not null default '',
  "DisposalDate"   text not null default '',
  "Notes"          text not null default ''
);

create table if not exists af.logs (
  "LogID"     text primary key default ('LOG-' || lpad(nextval('af.seq_log')::text, 7, '0')),
  "Timestamp" text not null default af.now_th(),
  "UserID"    text not null default 'SYSTEM',
  "UserName"  text not null default 'SYSTEM',
  "Action"    text not null default '',
  "Module"    text not null default '',
  "TargetID"  text not null default '',
  "Detail"    text not null default ''
);

create table if not exists af.settings (
  "Key"   text primary key,
  "Value" text not null default ''
);

create table if not exists af.sessions (
  token_hash text primary key,
  user_id    text not null references af.users("UserID") on update cascade on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists sessions_user on af.sessions (user_id);

create table if not exists af.login_attempts (
  id       bigserial primary key,
  username text not null,
  at       timestamptz not null default now()
);
create index if not exists login_attempts_user_at on af.login_attempts (username, at);

create table if not exists af.register_attempts (
  id bigserial primary key,
  at timestamptz not null default now()
);

-- ปิดการเข้าถึงตรงทุกตาราง (RLS เปิด + ไม่มี policy = ปฏิเสธทั้งหมด สำหรับ API)
alter table af.departments       enable row level security;
alter table af.users             enable row level security;
alter table af.assets            enable row level security;
alter table af.borrows           enable row level security;
alter table af.maintenances      enable row level security;
alter table af.disposals         enable row level security;
alter table af.logs              enable row level security;
alter table af.settings          enable row level security;
alter table af.sessions          enable row level security;
alter table af.login_attempts    enable row level security;
alter table af.register_attempts enable row level security;

-- ---------- ค่าตั้งต้น (ไม่ทับค่าเดิมถ้ามีแล้ว) ----------
insert into af.settings ("Key","Value") values
  ('AppTitle',        'ระบบยืม-คืนครุภัณฑ์'),
  ('AppSubtitle',     'โรงพยาบาลสันทราย'),
  ('OrgName',         'โรงพยาบาลสันทราย'),
  ('OrgAddress',      ''),
  ('OrgPhone',        ''),
  ('LogoUrl',         ''),
  ('DocPrefix',       'ที่ '),
  ('Signer1Name',     ''),
  ('Signer1Position', 'เจ้าหน้าที่พัสดุ'),
  ('Signer2Name',     ''),
  ('Signer2Position', 'หัวหน้ากลุ่มงาน'),
  ('Signer3Name',     ''),
  ('Signer3Position', 'ผู้อำนวยการโรงพยาบาลสันทราย'),
  ('MaxBorrowDays',   '7'),
  ('RequireApproval', 'true'),
  ('AllowCrossDeptBorrow', 'true'),
  ('OverdueAlertNote','กรุณาคืนครุภัณฑ์ภายในกำหนดเวลา หากมีความจำเป็นต้องยืมต่อโปรดแจ้งเจ้าหน้าที่พัสดุ')
on conflict ("Key") do nothing;

insert into af.departments ("DeptCode","DeptName")
select 'CENTRAL', 'ส่วนกลาง (งานพัสดุ) โรงพยาบาลสันทราย'
where not exists (select 1 from af.departments);

-- =====================================================================
-- ฟังก์ชันภายใน (schema af — เรียกจาก API โดยตรงไม่ได้)
-- =====================================================================
create or replace function af.fail(p_msg text, p_code text default 'error') returns jsonb
language sql immutable set search_path = pg_catalog as $$
  select jsonb_build_object('ok', false, 'message', p_msg, 'code', p_code)
$$;

create or replace function af.unauth() returns jsonb
language sql immutable set search_path = pg_catalog as $$
  select jsonb_build_object('ok', false, 'code', 'unauthorized',
                            'message', 'เซสชันหมดอายุหรือไม่ถูกต้อง กรุณาเข้าสู่ระบบใหม่')
$$;

-- คืนแถวผู้ใช้จาก token (UserID เป็น null ถ้าไม่ผ่าน)
create or replace function af.auth(p_token text) returns af.users
language plpgsql security definer set search_path = af, public, extensions, pg_catalog as $$
declare u af.users;
begin
  if p_token is null or length(p_token) < 32 or length(p_token) > 200 then
    return u;
  end if;
  select us.* into u
    from af.sessions s
    join af.users us on us."UserID" = s.user_id
   where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and s.expires_at > now()
     and us."Status" = 'Active';
  return u;
end $$;

create or replace function af.user_json(u af.users) returns jsonb
language sql stable security definer set search_path = af, pg_catalog as $$
  select (to_jsonb(u) - 'PasswordHash')
         || jsonb_build_object('DepartmentName',
              coalesce((select d."DeptName" from af.departments d where d."DeptID" = u."DepartmentID"), ''))
$$;

create or replace function af.asset_json(a af.assets) returns jsonb
language sql stable security definer set search_path = af, pg_catalog as $$
  select to_jsonb(a)
         || jsonb_build_object('DepartmentName',
              coalesce((select d."DeptName" from af.departments d where d."DeptID" = a."DepartmentID"), ''))
$$;

create or replace function af.log(u af.users, p_action text, p_module text, p_target text, p_detail text)
returns void language sql security definer set search_path = af, pg_catalog as $$
  insert into af.logs ("UserID","UserName","Action","Module","TargetID","Detail")
  values (coalesce(u."UserID",'SYSTEM'), coalesce(u."FullName",'SYSTEM'), p_action, p_module,
          coalesce(p_target,''), left(coalesce(p_detail,''), 500))
$$;

-- ตรวจรูปภาพ: รับเฉพาะ https:// หรือ data:image/(png|jpeg|webp|gif);base64 (ไม่รับ svg) ขนาดจำกัด
create or replace function af.clean_img(p_val text, p_max int default 700000) returns text
language plpgsql immutable set search_path = pg_catalog as $$
begin
  if p_val is null or btrim(p_val) = '' then return ''; end if;
  if length(p_val) > p_max then
    raise exception 'ไฟล์รูปภาพมีขนาดใหญ่เกินไป' using errcode = 'P0001';
  end if;
  if p_val ~ '^https://[^\s<>"'']+$' then return p_val; end if;
  if p_val ~ '^data:image/(png|jpeg|jpg|webp|gif);base64,[A-Za-z0-9+/=]+$' then return p_val; end if;
  raise exception 'รูปแบบรูปภาพไม่ถูกต้อง (รองรับ PNG/JPG/WEBP/GIF)' using errcode = 'P0001';
end $$;

create or replace function af.txt(p jsonb, k text, p_max int default 200) returns text
language sql immutable set search_path = pg_catalog as $$
  select left(btrim(coalesce(p ->> k, '')), p_max)
$$;

create or replace function af.is_date(p text) returns boolean
language plpgsql immutable set search_path = pg_catalog as $$
begin
  if p is null or p !~ '^\d{4}-\d{2}-\d{2}$' then return false; end if;
  perform p::date;
  return true;
exception when others then return false;
end $$;

create or replace function af.setting(p_key text) returns text
language sql stable security definer set search_path = af, pg_catalog as $$
  select "Value" from af.settings where "Key" = p_key
$$;

-- =====================================================================
-- RPC สำหรับหน้าเว็บ (schema public)
-- =====================================================================

-- ---- ข้อมูลสาธารณะก่อนล็อกอิน (ชื่อระบบ/โลโก้/รายชื่อหน่วยงานสำหรับสมัคร) ----
create or replace function public.rpc_get_public_branding() returns jsonb
language sql stable security definer set search_path = af, public, pg_catalog as $$
  select jsonb_build_object(
    'ok', true,
    'settings', (select coalesce(jsonb_object_agg("Key","Value"), '{}'::jsonb)
                   from af.settings where "Key" in ('AppTitle','AppSubtitle','OrgName','LogoUrl')),
    'departments', (select coalesce(jsonb_agg(jsonb_build_object('DeptID',"DeptID",'DeptName',"DeptName") order by "DeptID"), '[]'::jsonb)
                      from af.departments where "Status" = 'Active')
  )
$$;

-- ---- เข้าสู่ระบบ ----
create or replace function public.rpc_login_user(p_username text, p_password text, p_remember boolean default true)
returns jsonb language plpgsql security definer set search_path = af, public, extensions, pg_catalog as $$
declare
  uname text := lower(btrim(coalesce(p_username, '')));
  u af.users;
  tok text;
  fails int;
begin
  if uname = '' or p_password is null or length(p_password) > 200 then
    return af.fail('ชื่อผู้ใช้หรือรหัสผ่านไม่ถูกต้อง');
  end if;
  select count(*) into fails from af.login_attempts
   where username = uname and at > now() - interval '15 minutes';
  if fails >= 5 then
    return af.fail('พยายามเข้าสู่ระบบผิดหลายครั้ง กรุณารอ 15 นาทีแล้วลองใหม่', 'locked');
  end if;

  select * into u from af.users where lower("Username") = uname;
  if not found then
    perform extensions.crypt(p_password, extensions.gen_salt('bf', 8));   -- กัน timing
    insert into af.login_attempts (username) values (uname);
    return af.fail('ชื่อผู้ใช้หรือรหัสผ่านไม่ถูกต้อง');
  end if;
  if u."PasswordHash" <> extensions.crypt(p_password, u."PasswordHash") then
    insert into af.login_attempts (username) values (uname);
    return af.fail('ชื่อผู้ใช้หรือรหัสผ่านไม่ถูกต้อง');
  end if;
  if u."Status" <> 'Active' then
    return af.fail('บัญชีนี้ถูกระงับการใช้งาน');
  end if;

  delete from af.login_attempts where username = uname or at < now() - interval '1 day';
  delete from af.sessions where expires_at < now();
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into af.sessions (token_hash, user_id, expires_at)
  values (encode(extensions.digest(tok, 'sha256'), 'hex'), u."UserID",
          now() + case when coalesce(p_remember, true) then interval '30 days' else interval '12 hours' end);
  update af.users set "LastLogin" = af.now_th() where "UserID" = u."UserID" returning * into u;
  perform af.log(u, 'LOGIN', 'Auth', u."UserID", 'เข้าสู่ระบบสำเร็จ');
  return jsonb_build_object('ok', true, 'token', tok, 'user', af.user_json(u));
end $$;

create or replace function public.rpc_logout(p_token text) returns jsonb
language plpgsql security definer set search_path = af, public, extensions, pg_catalog as $$
begin
  if p_token is not null and length(p_token) between 32 and 200 then
    delete from af.sessions where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---- ลงทะเบียนผู้ยืม (Role = Borrower เสมอ) ----
create or replace function public.rpc_register_user(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = af, public, extensions, pg_catalog as $$
declare
  fullname text := af.txt(p_payload, 'FullName', 120);
  uname    text := af.txt(p_payload, 'Username', 30);
  pwd      text := coalesce(p_payload ->> 'Password', '');
  dept     af.departments;
  u        af.users;
  tok      text;
  recent   int;
begin
  select count(*) into recent from af.register_attempts where at > now() - interval '1 hour';
  if recent >= 30 then
    return af.fail('มีการลงทะเบียนหนาแน่นเกินไป กรุณาลองใหม่ภายหลัง หรือติดต่อผู้ดูแลระบบ');
  end if;
  if fullname = '' then return af.fail('กรุณากรอกชื่อ-นามสกุล'); end if;
  if uname !~ '^[A-Za-z0-9_.-]{3,30}$' then
    return af.fail('Username ต้องเป็นภาษาอังกฤษ/ตัวเลข 3-30 ตัวอักษร');
  end if;
  if length(pwd) < 8 or length(pwd) > 72 then
    return af.fail('รหัสผ่านต้องยาว 8-72 ตัวอักษร');
  end if;
  select * into dept from af.departments
   where "DeptID" = af.txt(p_payload, 'DepartmentID', 30) and "Status" = 'Active';
  if not found then return af.fail('กรุณาเลือกหน่วยงาน'); end if;
  if exists (select 1 from af.users where lower("Username") = lower(uname)) then
    return af.fail('ชื่อผู้ใช้นี้ถูกใช้งานแล้ว');
  end if;

  insert into af.register_attempts default values;
  insert into af.users ("Username","PasswordHash","FullName","Email","Phone","Role","DepartmentID","LastLogin")
  values (uname, extensions.crypt(pwd, extensions.gen_salt('bf', 10)), fullname,
          af.txt(p_payload,'Email',120), af.txt(p_payload,'Phone',30), 'Borrower', dept."DeptID", af.now_th())
  returning * into u;
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into af.sessions (token_hash, user_id, expires_at)
  values (encode(extensions.digest(tok, 'sha256'), 'hex'), u."UserID", now() + interval '30 days');
  perform af.log(u, 'REGISTER', 'Auth', u."UserID", 'ลงทะเบียนผู้ใช้งานใหม่');
  return jsonb_build_object('ok', true, 'token', tok, 'user', af.user_json(u));
end $$;

-- ---- โหลดข้อมูลทั้งหมด (กรองตามสิทธิ์ที่ฝั่งเซิร์ฟเวอร์) ----
create or replace function public.rpc_get_initial_data(p_token text) returns jsonb
language plpgsql stable security definer set search_path = af, public, pg_catalog as $$
declare
  u af.users := af.auth(p_token);
  is_sa boolean; is_da boolean; is_ap boolean;
  d jsonb;
begin
  if u."UserID" is null then return af.unauth(); end if;
  is_sa := u."Role" = 'SuperAdmin';
  is_da := u."Role" = 'DeptAdmin';
  is_ap := u."Role" = 'Approver';

  d := jsonb_build_object(
    'me', af.user_json(u),
    'users', case when is_sa then
        (select coalesce(jsonb_agg(af.user_json(x) order by x."UserID"), '[]'::jsonb) from af.users x)
      else '[]'::jsonb end,
    'departments',
        (select coalesce(jsonb_agg(to_jsonb(x) order by x."DeptID"), '[]'::jsonb) from af.departments x),
    'assets',
        (select coalesce(jsonb_agg(af.asset_json(x) order by x."AssetID"), '[]'::jsonb) from af.assets x),
    'borrows',
        (select coalesce(jsonb_agg(to_jsonb(x) order by x."CreatedAt" desc, x."BorrowID" desc), '[]'::jsonb) from af.borrows x),
    'maintenances',
        (select coalesce(jsonb_agg(to_jsonb(x) order by x."ReportedAt" desc, x."MaintID" desc), '[]'::jsonb)
           from af.maintenances x
          where is_sa or is_ap
             or (is_da and x."DepartmentID" = u."DepartmentID")
             or x."ReportedBy" = u."FullName"),
    'disposals',
        (select coalesce(jsonb_agg(to_jsonb(x) order by x."DisposalID" desc), '[]'::jsonb)
           from af.disposals x
          where is_sa or is_ap or (is_da and x."DepartmentID" = u."DepartmentID")),
    'logs', case when is_sa or is_da or is_ap then
        (select coalesce(jsonb_agg(to_jsonb(x) order by x."LogID" desc), '[]'::jsonb)
           from (select * from af.logs order by "LogID" desc limit 200) x)
      else '[]'::jsonb end,
    'settings',
        (select coalesce(jsonb_object_agg("Key","Value"), '{}'::jsonb) from af.settings)
  );
  return jsonb_build_object('ok', true, 'data', d);
end $$;

-- ---- หน่วยงาน (SuperAdmin) ----
create or replace function public.rpc_save_department(p_token text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = af, public, pg_catalog as $$
declare
  u af.users := af.auth(p_token);
  id text := af.txt(p_payload, 'DeptID', 30);
  nm text := af.txt(p_payload, 'DeptName', 160);
  st text := case when p_payload ->> 'Status' = 'Inactive' then 'Inactive' else 'Active' end;
begin
  if u."UserID" is null then return af.unauth(); end if;
  if u."Role" <> 'SuperAdmin' then return af.fail('ไม่มีสิทธิ์จัดการหน่วยงาน', 'forbidden'); end if;
  if nm = '' then return af.fail('กรุณากรอกชื่อหน่วยงาน'); end if;
  if id <> '' then
    update af.departments set "DeptCode" = af.txt(p_payload,'DeptCode',30), "DeptName" = nm,
           "HeadName" = af.txt(p_payload,'HeadName',120), "Location" = af.txt(p_payload,'Location',160),
           "ContactPhone" = af.txt(p_payload,'ContactPhone',40), "Status" = st
     where "DeptID" = id;
    if not found then return af.fail('ไม่พบหน่วยงาน'); end if;
    perform af.log(u, 'UPDATE_DEPT', 'Departments', id, 'แก้ไขหน่วยงาน: ' || nm);
  else
    insert into af.departments ("DeptCode","DeptName","HeadName","Location","ContactPhone","Status")
    values (af.txt(p_payload,'DeptCode',30), nm, af.txt(p_payload,'HeadName',120),
            af.txt(p_payload,'Location',160), af.txt(p_payload,'ContactPhone',40), st)
    returning "DeptID" into id;
    perform af.log(u, 'CREATE_DEPT', 'Departments', id, 'เพิ่มหน่วยงาน: ' || nm);
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.rpc_delete_department(p_token text, p_id text) returns jsonb
language plpgsql security definer set search_path = af, public, pg_catalog as $$
declare u af.users := af.auth(p_token);
begin
  if u."UserID" is null then return af.unauth(); end if;
  if u."Role" <> 'SuperAdmin' then return af.fail('ไม่มีสิทธิ์ลบหน่วยงาน', 'forbidden'); end if;
  if exists (select 1 from af.users where "DepartmentID" = p_id)
     or exists (select 1 from af.assets where "DepartmentID" = p_id) then
    return af.fail('ลบไม่ได้ เพราะยังมีผู้ใช้งานหรือครุภัณฑ์สังกัดหน่วยงานนี้ (เปลี่ยนสถานะเป็น Inactive แทนได้)');
  end if;
  delete from af.departments where "DeptID" = p_id;
  if not found then return af.fail('ไม่พบหน่วยงาน'); end if;
  perform af.log(u, 'DELETE_DEPT', 'Departments', p_id, 'ลบหน่วยงาน ' || p_id);
  return jsonb_build_object('ok', true);
end $$;

-- ---- ผู้ใช้ (SuperAdmin) ----
create or replace function public.rpc_save_user(p_token text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = af, public, extensions, pg_catalog as $$
declare
  u af.users := af.auth(p_token);
  id text := af.txt(p_payload, 'UserID', 30);
  uname text := af.txt(p_payload, 'Username', 30);
  fullname text := af.txt(p_payload, 'FullName', 120);
  pwd text := coalesce(p_payload ->> 'Password', '');
  role text := af.txt(p_payload, 'Role', 20);
  st text := case when p_payload ->> 'Status' = 'Inactive' then 'Inactive' else 'Active' end;
  old af.users;
  other_sa int;
begin
  if u."UserID" is null then return af.unauth(); end if;
  if u."Role" <> 'SuperAdmin' then return af.fail('ไม่มีสิทธิ์จัดการผู้ใช้งาน', 'forbidden'); end if;
  if fullname = '' then return af.fail('กรุณากรอกชื่อ-นามสกุล'); end if;
  if role not in ('SuperAdmin','DeptAdmin','Approver','Borrower') then return af.fail('สิทธิ์ไม่ถูกต้อง'); end if;
  if not exists (select 1 from af.departments where "DeptID" = af.txt(p_payload,'DepartmentID',30)) then
    return af.fail('กรุณาเลือกหน่วยงาน');
  end if;
  if pwd <> '' and (length(pwd) < 8 or length(pwd) > 72) then
    return af.fail('รหัสผ่านต้องยาว 8-72 ตัวอักษร');
  end if;

  if id <> '' then
    select * into old from af.users where "UserID" = id;
    if not found then return af.fail('ไม่พบผู้ใช้'); end if;
    if uname !~ '^[A-Za-z0-9_.-]{3,30}$' then return af.fail('Username ต้องเป็นภาษาอังกฤษ/ตัวเลข 3-30 ตัวอักษร'); end if;
    if exists (select 1 from af.users where lower("Username") = lower(uname) and "UserID" <> id) then
      return af.fail('Username ซ้ำในระบบ');
    end if;
    if old."Role" = 'SuperAdmin' and (role <> 'SuperAdmin' or st <> 'Active') then
      select count(*) into other_sa from af.users where "Role" = 'SuperAdmin' and "Status" = 'Active' and "UserID" <> id;
      if other_sa = 0 then return af.fail('ต้องมีผู้ดูแลระบบสูงสุดที่ใช้งานได้อย่างน้อย 1 บัญชี'); end if;
    end if;
    update af.users set "Username" = uname, "FullName" = fullname, "Email" = af.txt(p_payload,'Email',120),
           "Phone" = af.txt(p_payload,'Phone',30), "Role" = role,
           "DepartmentID" = af.txt(p_payload,'DepartmentID',30), "Status" = st,
           "PasswordHash" = case when pwd <> '' then extensions.crypt(pwd, extensions.gen_salt('bf', 10)) else "PasswordHash" end
     where "UserID" = id;
    if pwd <> '' or st <> 'Active' or role <> old."Role" then
      delete from af.sessions where user_id = id;      -- บังคับล็อกอินใหม่
    end if;
    perform af.log(u, 'UPDATE_USER', 'Users', id, 'แก้ไขผู้ใช้ ' || fullname);
  else
    if uname !~ '^[A-Za-z0-9_.-]{3,30}$' then return af.fail('Username ต้องเป็นภาษาอังกฤษ/ตัวเลข 3-30 ตัวอักษร'); end if;
    if pwd = '' then return af.fail('กรุณากำหนดรหัสผ่าน (อย่างน้อย 8 ตัวอักษร)'); end if;
    if exists (select 1 from af.users where lower("Username") = lower(uname)) then
      return af.fail('Username ซ้ำในระบบ');
    end if;
    insert into af.users ("Username","PasswordHash","FullName","Email","Phone","Role","DepartmentID","Status")
    values (uname, extensions.crypt(pwd, extensions.gen_salt('bf', 10)), fullname,
            af.txt(p_payload,'Email',120), af.txt(p_payload,'Phone',30), role,
            af.txt(p_payload,'DepartmentID',30), st)
    returning "UserID" into id;
    perform af.log(u, 'CREATE_USER', 'Users', id, 'เพิ่มผู้ใช้ ' || fullname);
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.rpc_delete_user(p_token text, p_id text) returns jsonb
language plpgsql security definer set search_path = af, public, pg_catalog as $$
declare u af.users := af.auth(p_token); t af.users; other_sa int;
begin
  if u."UserID" is null then return af.unauth(); end if;
  if u."Role" <> 'SuperAdmin' then return af.fail('ไม่มีสิทธิ์ลบผู้ใช้งาน', 'forbidden'); end if;
  if u."UserID" = p_id then return af.fail('ไม่สามารถลบตัวเองได้'); end if;
  select * into t from af.users where "UserID" = p_id;
  if not found then return af.fail('ไม่พบผู้ใช้'); end if;
  if t."Role" = 'SuperAdmin' then
    select count(*) into other_sa from af.users where "Role" = 'SuperAdmin' and "Status" = 'Active' and "UserID" <> p_id;
    if other_sa = 0 then return af.fail('ต้องมีผู้ดูแลระบบสูงสุดที่ใช้งานได้อย่างน้อย 1 บัญชี'); end if;
  end if;
  delete from af.users where "UserID" = p_id;
  perform af.log(u, 'DELETE_USER', 'Users', p_id, 'ลบผู้ใช้ ' || t."FullName");
  return jsonb_build_object('ok', true);
end $$;

-- ---- ครุภัณฑ์ (SuperAdmin ทุกหน่วย / DeptAdmin เฉพาะหน่วยตนเอง) ----
create or replace function public.rpc_save_asset(p_token text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = af, public, pg_catalog as $$
declare
  u af.users := af.auth(p_token);
  id text := af.txt(p_payload, 'AssetID', 30);
  code text := af.txt(p_payload, 'AssetCode', 60);
  nm text := af.txt(p_payload, 'AssetName', 200);
  dept text := af.txt(p_payload, 'DepartmentID', 30);
  st text := af.txt(p_payload, 'Status', 30);
  price numeric;
  img text;
  old af.assets;
  pdate text := af.txt(p_payload, 'PurchaseDate', 10);
begin
  if u."UserID" is null then return af.unauth(); end if;
  if u."Role" not in ('SuperAdmin','DeptAdmin') then return af.fail('ไม่มีสิทธิ์จัดการครุภัณฑ์', 'forbidden'); end if;
  if code = '' or nm = '' then return af.fail('กรุณากรอกรหัสและชื่อครุภัณฑ์'); end if;
  if u."Role" = 'DeptAdmin' and dept <> u."DepartmentID" then
    return af.fail('จัดการได้เฉพาะครุภัณฑ์ของหน่วยงานตนเอง', 'forbidden');
  end if;
  if not exists (select 1 from af.departments where "DeptID" = dept) then return af.fail('กรุณาเลือกหน่วยงาน'); end if;
  if st not in ('พร้อมให้ยืม','ถูกยืม','จองแล้ว','ส่งซ่อม','รอตัดจำหน่าย','ตัดจำหน่าย') then st := 'พร้อมให้ยืม'; end if;
  begin price := greatest(0, coalesce((p_payload ->> 'Price')::numeric, 0)); exception when others then price := 0; end;
  if pdate <> '' and not af.is_date(pdate) then pdate := ''; end if;
  begin
    img := af.clean_img(coalesce(nullif(p_payload ->> 'ImageBase64',''), p_payload ->> 'ImageUrl', ''));
  exception when others then return af.fail(sqlerrm); end;

  if id <> '' then
    select * into old from af.assets where "AssetID" = id for update;
    if not found then return af.fail('ไม่พบครุภัณฑ์'); end if;
    if u."Role" = 'DeptAdmin' and old."DepartmentID" <> u."DepartmentID" then
      return af.fail('จัดการได้เฉพาะครุภัณฑ์ของหน่วยงานตนเอง', 'forbidden');
    end if;
    if exists (select 1 from af.assets where lower("AssetCode") = lower(code) and "AssetID" <> id) then
      return af.fail('รหัสครุภัณฑ์ซ้ำในระบบ');
    end if;
    update af.assets set "AssetCode" = code, "SerialNo" = af.txt(p_payload,'SerialNo',80), "AssetName" = nm,
           "Category" = af.txt(p_payload,'Category',80), "BrandModel" = af.txt(p_payload,'BrandModel',120),
           "DepartmentID" = dept, "Location" = af.txt(p_payload,'Location',160), "PurchaseDate" = pdate,
           "Price" = price, "Condition" = af.txt(p_payload,'Condition',80), "Status" = st,
           "ImageUrl" = img, "QRCodeValue" = coalesce(nullif(af.txt(p_payload,'QRCodeValue',120),''), code),
           "Notes" = af.txt(p_payload,'Notes',500), "UpdatedAt" = af.now_th()
     where "AssetID" = id;
    perform af.log(u, 'UPDATE_ASSET', 'Assets', id, 'แก้ไขครุภัณฑ์ ' || code);
  else
    if exists (select 1 from af.assets where lower("AssetCode") = lower(code)) then
      return af.fail('รหัสครุภัณฑ์ซ้ำในระบบ');
    end if;
    insert into af.assets ("AssetCode","SerialNo","AssetName","Category","BrandModel","DepartmentID","Location",
                           "PurchaseDate","Price","Condition","Status","ImageUrl","QRCodeValue","Notes")
    values (code, af.txt(p_payload,'SerialNo',80), nm, af.txt(p_payload,'Category',80),
            af.txt(p_payload,'BrandModel',120), dept, af.txt(p_payload,'Location',160), pdate, price,
            af.txt(p_payload,'Condition',80), st, img,
            coalesce(nullif(af.txt(p_payload,'QRCodeValue',120),''), code), af.txt(p_payload,'Notes',500))
    returning "AssetID" into id;
    perform af.log(u, 'CREATE_ASSET', 'Assets', id, 'เพิ่มครุภัณฑ์ ' || code);
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.rpc_delete_asset(p_token text, p_id text) returns jsonb
language plpgsql security definer set search_path = af, public, pg_catalog as $$
declare u af.users := af.auth(p_token); a af.assets;
begin
  if u."UserID" is null then return af.unauth(); end if;
  if u."Role" not in ('SuperAdmin','DeptAdmin') then return af.fail('ไม่มีสิทธิ์ลบครุภัณฑ์', 'forbidden'); end if;
  select * into a from af.assets where "AssetID" = p_id for update;
  if not found then return af.fail('ไม่พบครุภัณฑ์'); end if;
  if u."Role" = 'DeptAdmin' and a."DepartmentID" <> u."DepartmentID" then
    return af.fail('ลบได้เฉพาะครุภัณฑ์ของหน่วยงานตนเอง', 'forbidden');
  end if;
  if exists (select 1 from af.borrows where "AssetID" = p_id and "Status" in ('รออนุมัติ','อนุมัติแล้ว','กำลังยืม')) then
    return af.fail('ลบไม่ได้ เพราะยังมีรายการยืมที่ค้างอยู่');
  end if;
  delete from af.assets where "AssetID" = p_id;
  perform af.log(u, 'DELETE_ASSET', 'Assets', p_id, 'ลบครุภัณฑ์ ' || a."AssetCode");
  return jsonb_build_object('ok', true);
end $$;

-- ---- ขอยืม (ผู้ยืม = ผู้ที่ล็อกอิน เสมอ) ----
create or replace function public.rpc_create_borrow_request(p_token text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = af, public, pg_catalog as $$
declare
  u af.users := af.auth(p_token);
  a af.assets;
  bdate text := af.txt(p_payload, 'BorrowDate', 10);
  ddate text := af.txt(p_payload, 'DueDate', 10);
  need_app boolean := coalesce(af.setting('RequireApproval'), 'true') <> 'false';
  cross_ok boolean := coalesce(af.setting('AllowCrossDeptBorrow'), 'true') = 'true';
  maxd int := coalesce(nullif(af.setting('MaxBorrowDays'), '')::int, 7);
  days int;
  rid text;
  rcode text;
  st text;
  udept text;
  ddept text;
begin
  if u."UserID" is null then return af.unauth(); end if;
  if not af.is_date(bdate) or not af.is_date(ddate) then return af.fail('วันที่ยืม/กำหนดคืนไม่ถูกต้อง'); end if;
  if ddate::date < bdate::date then return af.fail('กำหนดคืนต้องไม่ก่อนวันที่ยืม'); end if;
  if bdate::date < (af.today_th()::date - 1) then return af.fail('วันที่ยืมต้องไม่ย้อนหลัง'); end if;
  days := greatest(1, (ddate::date - bdate::date));
  if days > maxd then return af.fail('ยืมได้สูงสุด ' || maxd || ' วันต่อครั้ง'); end if;
  if af.txt(p_payload, 'Purpose', 500) = '' then return af.fail('กรุณาระบุวัตถุประสงค์การยืม'); end if;

  select * into a from af.assets where "AssetID" = af.txt(p_payload, 'AssetID', 30) for update;
  if not found or a."Status" <> 'พร้อมให้ยืม' then return af.fail('ครุภัณฑ์ไม่ว่างในขณะนี้'); end if;
  if not cross_ok and a."DepartmentID" <> u."DepartmentID" and u."Role" <> 'SuperAdmin' then
    return af.fail('ระบบไม่อนุญาตให้ยืมข้ามหน่วยงาน', 'forbidden');
  end if;

  select "DeptName" into udept from af.departments where "DeptID" = u."DepartmentID";
  select "DeptName" into ddept from af.departments where "DeptID" = a."DepartmentID";
  rid := 'BRW-' || lpad(nextval('af.seq_borrow')::text, 3, '0');
  rcode := 'REQ-' || to_char(now() at time zone 'Asia/Bangkok', 'YYYY') || '-' || lpad(nextval('af.seq_reqcode')::text, 4, '0');
  st := case when need_app then 'รออนุมัติ' else 'กำลังยืม' end;

  insert into af.borrows ("BorrowID","RequestCode","AssetID","AssetCode","AssetName","BorrowerID","BorrowerName","BorrowerDept",
         "OwnerDeptID","OwnerDeptName","BorrowDate","DueDate","Purpose","LocationUse","Status","ApproverID","ApproverName",
         "ApprovedAt","ConditionBefore","Remarks","BorrowDays","ApprovalStatus")
  values (rid, rcode, a."AssetID", a."AssetCode", a."AssetName", u."UserID", u."FullName", coalesce(udept,''),
          a."DepartmentID", coalesce(ddept,''), bdate, ddate, af.txt(p_payload,'Purpose',500),
          af.txt(p_payload,'LocationUse',200), st,
          case when need_app then '' else 'SYSTEM' end,
          case when need_app then '' else 'อนุมัติอัตโนมัติ' end,
          case when need_app then '' else af.now_th() end,
          a."Condition", af.txt(p_payload,'Remarks',500), days,
          case when need_app then 'รออนุมัติ' else 'อนุมัติเรียบร้อยแล้ว' end);
  if not need_app then update af.assets set "Status" = 'ถูกยืม', "UpdatedAt" = af.now_th() where "AssetID" = a."AssetID"; end if;
  perform af.log(u, 'CREATE_BORROW', 'BorrowRequests', rid, 'ยื่นขอยืม ' || a."AssetCode");
  return jsonb_build_object('ok', true, 'requestCode', rcode, 'status', st);
end $$;

-- ---- อนุมัติ / ส่งมอบ / ปฏิเสธ / ยกเลิก / รับคืน ----
create or replace function public.rpc_process_borrow_action(p_token text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = af, public, pg_catalog as $$
declare
  u af.users := af.auth(p_token);
  act text := af.txt(p_payload, 'action', 30);
  r af.borrows;
  a af.assets;
  photo text;
  retdate text;
  ov int;
  dmg boolean := coalesce((p_payload ->> 'isDamaged')::boolean, false);
  cond_after text;
  staff boolean;
begin
  if u."UserID" is null then return af.unauth(); end if;
  select * into r from af.borrows where "BorrowID" = af.txt(p_payload, 'BorrowID', 30) for update;
  if not found then return af.fail('ไม่พบคำขอยืม'); end if;
  select * into a from af.assets where "AssetID" = r."AssetID" for update;

  begin photo := af.clean_img(p_payload ->> 'PhotoBase64'); exception when others then return af.fail(sqlerrm); end;

  -- สิทธิ์: SuperAdmin/Approver ทุกรายการ, DeptAdmin เฉพาะครุภัณฑ์ของหน่วยตนเอง
  staff := u."Role" in ('SuperAdmin','Approver')
           or (u."Role" = 'DeptAdmin' and r."OwnerDeptID" = u."DepartmentID");

  if act = 'cancel' then
    if not (staff or r."BorrowerID" = u."UserID") then return af.fail('ไม่มีสิทธิ์ยกเลิกคำขอนี้', 'forbidden'); end if;
    if r."Status" not in ('รออนุมัติ','อนุมัติแล้ว') then return af.fail('คำขอนี้ไม่สามารถยกเลิกได้ในสถานะปัจจุบัน'); end if;
    update af.borrows set "Status" = 'ยกเลิก', "ApprovalStatus" = 'ยกเลิก', "UpdatedAt" = af.now_th() where "BorrowID" = r."BorrowID";
    if a."AssetID" is not null and a."Status" = 'จองแล้ว' then
      update af.assets set "Status" = 'พร้อมให้ยืม', "UpdatedAt" = af.now_th() where "AssetID" = a."AssetID";
    end if;
    perform af.log(u, 'CANCEL_BORROW', 'BorrowRequests', r."BorrowID", 'ยกเลิก ' || r."RequestCode");
    return jsonb_build_object('ok', true);
  end if;

  if not staff then return af.fail('ไม่มีสิทธิ์ดำเนินการรายการนี้', 'forbidden'); end if;

  if act in ('approve','approve_handover') then
    if r."Status" <> 'รออนุมัติ' then return af.fail('คำขอนี้ไม่ได้อยู่ในสถานะรออนุมัติ'); end if;
    if a."AssetID" is null or a."Status" not in ('พร้อมให้ยืม','จองแล้ว') then return af.fail('ครุภัณฑ์ไม่พร้อมให้ยืม'); end if;
    update af.borrows set "ApproverID" = u."UserID", "ApproverName" = u."FullName", "ApprovedAt" = af.now_th(),
           "ConditionBefore" = coalesce(nullif(af.txt(p_payload,'ConditionBefore',200),''), a."Condition"),
           "ApprovalStatus" = 'อนุมัติเรียบร้อยแล้ว',
           "BeforePhotoUrl" = case when photo <> '' then photo else "BeforePhotoUrl" end,
           "Status" = case when act = 'approve_handover' then 'กำลังยืม' else 'อนุมัติแล้ว' end,
           "UpdatedAt" = af.now_th()
     where "BorrowID" = r."BorrowID";
    update af.assets set "Status" = case when act = 'approve_handover' then 'ถูกยืม' else 'จองแล้ว' end,
           "UpdatedAt" = af.now_th() where "AssetID" = a."AssetID";
    perform af.log(u, 'APPROVE_BORROW', 'BorrowRequests', r."BorrowID", 'อนุมัติ ' || r."RequestCode");

  elsif act = 'handover' then
    if r."Status" <> 'อนุมัติแล้ว' then return af.fail('ส่งมอบได้เฉพาะรายการที่อนุมัติแล้ว'); end if;
    update af.borrows set "Status" = 'กำลังยืม', "ApprovalStatus" = 'อนุมัติเรียบร้อยแล้ว',
           "ConditionBefore" = coalesce(nullif(af.txt(p_payload,'ConditionBefore',200),''), "ConditionBefore"),
           "BeforePhotoUrl" = case when photo <> '' then photo else "BeforePhotoUrl" end,
           "UpdatedAt" = af.now_th()
     where "BorrowID" = r."BorrowID";
    update af.assets set "Status" = 'ถูกยืม', "UpdatedAt" = af.now_th() where "AssetID" = r."AssetID";
    perform af.log(u, 'HANDOVER_ASSET', 'BorrowRequests', r."BorrowID", 'ส่งมอบ ' || r."RequestCode");

  elsif act = 'reject' then
    if r."Status" <> 'รออนุมัติ' then return af.fail('ปฏิเสธได้เฉพาะรายการรออนุมัติ'); end if;
    update af.borrows set "Status" = 'ปฏิเสธ', "ApprovalStatus" = 'ไม่อนุมัติ', "ApproverID" = u."UserID",
           "ApproverName" = u."FullName", "ApprovedAt" = af.now_th(),
           "RejectReason" = coalesce(nullif(af.txt(p_payload,'RejectReason',300),''), 'ไม่ผ่านเกณฑ์'),
           "UpdatedAt" = af.now_th()
     where "BorrowID" = r."BorrowID";
    perform af.log(u, 'REJECT_BORROW', 'BorrowRequests', r."BorrowID", 'ปฏิเสธ ' || r."RequestCode");

  elsif act = 'return' then
    if r."Status" not in ('กำลังยืม','อนุมัติแล้ว') then return af.fail('รับคืนได้เฉพาะรายการที่กำลังยืมอยู่'); end if;
    retdate := af.txt(p_payload, 'ReturnDate', 10);
    if not af.is_date(retdate) then retdate := af.today_th(); end if;
    ov := case when retdate > r."DueDate" and af.is_date(r."DueDate") then greatest(0, retdate::date - r."DueDate"::date) else 0 end;
    cond_after := coalesce(nullif(af.txt(p_payload,'ConditionAfter',200),''), 'ปกติครบชุด');
    update af.borrows set "Status" = 'คืนแล้ว', "ApprovalStatus" = 'อนุมัติเรียบร้อยแล้ว', "ReturnDate" = retdate,
           "ConditionAfter" = cond_after,
           "Remarks" = coalesce(nullif(af.txt(p_payload,'Remarks',500),''), "Remarks"),
           "ReceiverName" = u."FullName",
           "BorrowDays" = greatest(1, retdate::date - case when af.is_date("BorrowDate") then "BorrowDate"::date else retdate::date end),
           "OverdueDays" = ov,
           "OverdueStatus" = case when ov > 0 then 'เกินกำหนด (' || ov || ' วัน)' else 'ปกติ' end,
           "AfterPhotoUrl" = case when photo <> '' then photo else "AfterPhotoUrl" end,
           "UpdatedAt" = af.now_th()
     where "BorrowID" = r."BorrowID";
    if a."AssetID" is not null then
      update af.assets set "Status" = case when dmg then 'ส่งซ่อม' else 'พร้อมให้ยืม' end,
             "Condition" = case when dmg then 'ชำรุด' else cond_after end, "UpdatedAt" = af.now_th()
       where "AssetID" = a."AssetID";
    end if;
    if dmg then
      insert into af.maintenances ("AssetID","AssetCode","AssetName","DepartmentID","ReportedBy","IssueDetail","Priority","Status","AttachmentUrl")
      values (r."AssetID", r."AssetCode", r."AssetName", r."OwnerDeptID", u."FullName",
              'พบความเสียหายขณะรับคืน (' || r."RequestCode" || '): ' ||
              coalesce(nullif(af.txt(p_payload,'DamageDetail',500), ''), af.txt(p_payload,'Remarks',500)),
              'สูง', 'แจ้งซ่อม', case when photo <> '' then photo else '' end);
    end if;
    perform af.log(u, 'RETURN_ASSET', 'BorrowRequests', r."BorrowID", 'รับคืน ' || r."RequestCode");

  else
    return af.fail('คำสั่งไม่ถูกต้อง');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---- แจ้งซ่อม / อัปเดตงานซ่อม ----
create or replace function public.rpc_save_maintenance(p_token text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = af, public, pg_catalog as $$
declare
  u af.users := af.auth(p_token);
  id text := af.txt(p_payload, 'MaintID', 30);
  a af.assets;
  m af.maintenances;
  att text;
  prio text := af.txt(p_payload, 'Priority', 20);
  st text := af.txt(p_payload, 'Status', 40);
  cost numeric;
  issue text := af.txt(p_payload, 'IssueDetail', 800);
  can_manage boolean;
begin
  if u."UserID" is null then return af.unauth(); end if;
  if issue = '' then return af.fail('กรุณาระบุอาการชำรุด'); end if;
  if prio not in ('ปกติ','สูง','เร่งด่วนมาก') then prio := 'ปกติ'; end if;
  begin att := af.clean_img(coalesce(nullif(p_payload ->> 'AttachmentBase64',''), p_payload ->> 'AttachmentUrl', ''));
  exception when others then return af.fail(sqlerrm); end;
  begin cost := greatest(0, coalesce((p_payload ->> 'Cost')::numeric, 0)); exception when others then cost := 0; end;

  select * into a from af.assets where "AssetID" = af.txt(p_payload, 'AssetID', 30) for update;
  if not found then return af.fail('ไม่พบครุภัณฑ์'); end if;
  can_manage := u."Role" = 'SuperAdmin' or (u."Role" = 'DeptAdmin' and a."DepartmentID" = u."DepartmentID");

  if id <> '' then
    if not can_manage then return af.fail('ไม่มีสิทธิ์อัปเดตงานซ่อมนี้', 'forbidden'); end if;
    select * into m from af.maintenances where "MaintID" = id for update;
    if not found then return af.fail('ไม่พบรายการซ่อม'); end if;
    if st not in ('แจ้งซ่อม','กำลังซ่อม','ซ่อมเสร็จ','ซ่อมไม่ได้-รอตัดจำหน่าย') then st := m."Status"; end if;
    update af.maintenances set "IssueDetail" = issue, "Priority" = prio, "Status" = st,
           "VendorOrTechnician" = af.txt(p_payload,'VendorOrTechnician',160), "Cost" = cost,
           "AttachmentUrl" = case when att <> '' then att else "AttachmentUrl" end,
           "CompletedAt" = case when st in ('ซ่อมเสร็จ','ซ่อมไม่ได้-รอตัดจำหน่าย')
                                then coalesce(nullif("CompletedAt",''), af.now_th()) else '' end
     where "MaintID" = id;
    update af.assets set
           "Status" = case when st = 'ซ่อมเสร็จ' then 'พร้อมให้ยืม'
                           when st = 'ซ่อมไม่ได้-รอตัดจำหน่าย' then 'รอตัดจำหน่าย' else 'ส่งซ่อม' end,
           "Condition" = case when st = 'ซ่อมเสร็จ' then 'ดี' else "Condition" end,
           "UpdatedAt" = af.now_th()
     where "AssetID" = a."AssetID" and "Status" <> 'ตัดจำหน่าย';
    perform af.log(u, 'UPDATE_MAINT', 'MaintenanceLogs', id, 'อัปเดตงานซ่อม -> ' || st);
  else
    if a."Status" = 'ตัดจำหน่าย' then return af.fail('ครุภัณฑ์นี้ถูกตัดจำหน่ายแล้ว'); end if;
    insert into af.maintenances ("AssetID","AssetCode","AssetName","DepartmentID","ReportedBy","IssueDetail","Priority",
                                 "VendorOrTechnician","Cost","Status","AttachmentUrl")
    values (a."AssetID", a."AssetCode", a."AssetName", a."DepartmentID", u."FullName", issue, prio,
            case when can_manage then af.txt(p_payload,'VendorOrTechnician',160) else '' end,
            case when can_manage then cost else 0 end, 'แจ้งซ่อม', att)
    returning "MaintID" into id;
    -- เปลี่ยนสถานะครุภัณฑ์เป็น "ส่งซ่อม" เฉพาะตอนที่ว่างอยู่ (ไม่กระทบรายการที่กำลังยืม/จอง)
    update af.assets set "Status" = 'ส่งซ่อม', "Condition" = 'ต้องตรวจสอบ', "UpdatedAt" = af.now_th()
     where "AssetID" = a."AssetID" and "Status" = 'พร้อมให้ยืม';
    perform af.log(u, 'CREATE_MAINT', 'MaintenanceLogs', id, 'แจ้งซ่อม ' || a."AssetCode");
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---- ตัดจำหน่าย ----
create or replace function public.rpc_dispose_asset(p_token text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = af, public, pg_catalog as $$
declare
  u af.users := af.auth(p_token);
  a af.assets;
  ddate text := af.txt(p_payload, 'DisposalDate', 10);
  id text;
begin
  if u."UserID" is null then return af.unauth(); end if;
  if u."Role" not in ('SuperAdmin','DeptAdmin') then return af.fail('ไม่มีสิทธิ์ตัดจำหน่าย', 'forbidden'); end if;
  select * into a from af.assets where "AssetID" = af.txt(p_payload, 'AssetID', 30) for update;
  if not found then return af.fail('ไม่พบครุภัณฑ์'); end if;
  if u."Role" = 'DeptAdmin' and a."DepartmentID" <> u."DepartmentID" then
    return af.fail('ตัดจำหน่ายได้เฉพาะครุภัณฑ์ของหน่วยงานตนเอง', 'forbidden');
  end if;
  if a."Status" = 'ตัดจำหน่าย' then return af.fail('ครุภัณฑ์นี้ถูกตัดจำหน่ายแล้ว'); end if;
  if exists (select 1 from af.borrows where "AssetID" = a."AssetID" and "Status" in ('รออนุมัติ','อนุมัติแล้ว','กำลังยืม')) then
    return af.fail('ตัดจำหน่ายไม่ได้ เพราะยังมีรายการยืมค้างอยู่');
  end if;
  if af.txt(p_payload, 'Reason', 500) = '' then return af.fail('กรุณาระบุเหตุผลการตัดจำหน่าย'); end if;
  if not af.is_date(ddate) then ddate := af.today_th(); end if;
  insert into af.disposals ("AssetID","AssetCode","AssetName","DepartmentID","Reason","DisposalMethod","ApprovedBy","DisposalDate","Notes")
  values (a."AssetID", a."AssetCode", a."AssetName", a."DepartmentID", af.txt(p_payload,'Reason',500),
          af.txt(p_payload,'DisposalMethod',120), u."FullName", ddate, af.txt(p_payload,'Notes',500))
  returning "DisposalID" into id;
  update af.assets set "Status" = 'ตัดจำหน่าย', "Condition" = 'ชำรุดถาวร', "UpdatedAt" = af.now_th() where "AssetID" = a."AssetID";
  perform af.log(u, 'DISPOSE_ASSET', 'DisposalLogs', id, 'ตัดจำหน่าย ' || a."AssetCode");
  return jsonb_build_object('ok', true);
end $$;

-- ---- ตั้งค่าระบบ (SuperAdmin) ----
create or replace function public.rpc_save_settings(p_token text, p_map jsonb) returns jsonb
language plpgsql security definer set search_path = af, public, pg_catalog as $$
declare
  u af.users := af.auth(p_token);
  k text;
  v text;
  logo text;
  allowed text[] := array['AppTitle','AppSubtitle','OrgName','OrgAddress','OrgPhone','DocPrefix',
     'Signer1Name','Signer1Position','Signer2Name','Signer2Position','Signer3Name','Signer3Position',
     'MaxBorrowDays','RequireApproval','AllowCrossDeptBorrow','OverdueAlertNote'];
  n int;
begin
  if u."UserID" is null then return af.unauth(); end if;
  if u."Role" <> 'SuperAdmin' then return af.fail('ไม่มีสิทธิ์ตั้งค่าระบบ', 'forbidden'); end if;
  if jsonb_typeof(p_map) <> 'object' then return af.fail('ข้อมูลไม่ถูกต้อง'); end if;

  if af.txt(p_map, 'AppTitle', 100) = '' then return af.fail('กรุณากรอกชื่อระบบ'); end if;
  if p_map ? 'MaxBorrowDays' then
    begin n := (p_map ->> 'MaxBorrowDays')::int; exception when others then n := null; end;
    if n is null or n < 1 or n > 365 then return af.fail('จำนวนวันยืมสูงสุดต้องอยู่ระหว่าง 1-365'); end if;
  end if;
  foreach k in array array['RequireApproval','AllowCrossDeptBorrow'] loop
    if p_map ? k and (p_map ->> k) not in ('true','false') then return af.fail('ค่าตั้งค่าไม่ถูกต้อง: ' || k); end if;
  end loop;

  foreach k in array allowed loop
    if p_map ? k then
      v := left(btrim(coalesce(p_map ->> k, '')), case when k = 'OverdueAlertNote' then 500 else 200 end);
      insert into af.settings ("Key","Value") values (k, v)
      on conflict ("Key") do update set "Value" = excluded."Value";
    end if;
  end loop;

  begin
    logo := af.clean_img(coalesce(nullif(p_map ->> 'LogoBase64',''), p_map ->> 'LogoUrl', ''));
  exception when others then return af.fail(sqlerrm); end;
  if p_map ? 'LogoBase64' or p_map ? 'LogoUrl' then
    insert into af.settings ("Key","Value") values ('LogoUrl', logo)
    on conflict ("Key") do update set "Value" = excluded."Value";
  end if;

  perform af.log(u, 'UPDATE_SETTINGS', 'Settings', 'CONFIG', 'บันทึกตั้งค่าระบบและข้อมูลหน่วยงาน');
  return jsonb_build_object('ok', true, 'logoUrl', coalesce(af.setting('LogoUrl'), ''));
end $$;

-- =====================================================================
-- สิทธิ์การเรียก: เฉพาะ rpc_* เท่านั้นที่เปิดให้ API
-- =====================================================================
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'rpc\_%' escape '\'
  loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('grant execute on function %s to anon', r.sig);
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('grant execute on function %s to authenticated', r.sig);
    end if;
  end loop;
end $$;

-- =====================================================================
-- สร้างผู้ดูแลระบบคนแรก (สุ่มรหัสผ่านให้ แสดงผลครั้งเดียวด้านล่าง)
-- รันซ้ำจะไม่สร้างซ้ำและไม่แสดงรหัสผ่านอีก
-- =====================================================================
with gen as (
  select encode(extensions.gen_random_bytes(5), 'hex') as pwd
), ins as (
  insert into af.users ("Username","PasswordHash","FullName","Role","DepartmentID","Status")
  select 'admin', extensions.crypt(gen.pwd, extensions.gen_salt('bf', 10)), 'ผู้ดูแลระบบ', 'SuperAdmin',
         (select "DeptID" from af.departments order by "DeptID" limit 1), 'Active'
    from gen
   where not exists (select 1 from af.users where "Role" = 'SuperAdmin')
  returning 1
)
select 'admin' as username, gen.pwd as initial_password_write_this_down
  from gen where exists (select 1 from ins);
