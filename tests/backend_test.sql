\set ON_ERROR_STOP on
-- !!! สคริปต์นี้ "ล้างข้อมูลทุกตาราง" ใช้กับฐานข้อมูลทดสอบเท่านั้น ห้ามรันบนระบบจริง !!!
-- ต้องเปิดตัวกันพลาดก่อน:  psql -v allow=yes -f backend_test.sql  (หรือ  PGOPTIONS="-c app.allow_test_reset=yes")
select current_setting('app.allow_test_reset', true) as allowed \gset
\if :{?allow}
\else
  \set allow no
\endif
do $$ begin
  if coalesce(current_setting('app.allow_test_reset', true), 'no') <> 'yes' then
    raise exception 'ยกเลิก: ตั้ง PGOPTIONS="-c app.allow_test_reset=yes" ถ้าแน่ใจว่าเป็นฐานข้อมูลทดสอบ';
  end if;
end $$;
\pset tuples_only on
-- helper: assert
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FAIL: %', label; else raise notice 'pass: %', label; end if; end $$;

-- reset test data (test DB only)
truncate af.sessions, af.login_attempts, af.register_attempts, af.borrows, af.maintenances, af.disposals, af.logs, af.assets restart identity;
delete from af.users where "Username" <> 'admin';
delete from af.departments where "DeptID" <> (select "DeptID" from af.departments order by "DeptID" limit 1);
update af.users set "PasswordHash" = extensions.crypt('AdminPass123', extensions.gen_salt('bf',8)) where "Username"='admin';

set role anon;
select pg_temp.ok((select (rpc_get_public_branding()->>'ok')::boolean), 'public branding works for anon');
select pg_temp.ok((rpc_get_public_branding()->'settings'->>'OrgName') = 'โรงพยาบาลสันทราย', 'branding OrgName = โรงพยาบาลสันทราย');
select pg_temp.ok(not exists(select 1 from jsonb_object_keys(rpc_get_public_branding()->'settings') k where k in ('Signer1Name','OrgPhone')), 'branding exposes only public keys');

-- anon cannot touch tables or helper schema
do $$ begin
  begin perform 1 from af.users; raise exception 'FAIL: anon read af.users'; exception when insufficient_privilege then raise notice 'pass: anon cannot read af.users'; end;
  begin perform af.auth('x'); raise exception 'FAIL: anon call af.auth'; exception when insufficient_privilege then raise notice 'pass: anon cannot call af helpers'; end;
end $$;
reset role;

-- login
set role anon;
select pg_temp.ok(not (rpc_login_user('admin','wrong')->>'ok')::boolean, 'wrong password rejected');
select set_config('t.admin', rpc_login_user('admin','AdminPass123',true)->>'token', false);
select pg_temp.ok(length(current_setting('t.admin'))=64, 'admin login returns 64-char token');
select pg_temp.ok(not (rpc_login_user('admin','AdminPass123')->'user' ? 'PasswordHash'), 'login response has no PasswordHash');

-- no token / bad token
select pg_temp.ok((rpc_get_initial_data(null)->>'code')='unauthorized', 'null token unauthorized');
select pg_temp.ok((rpc_get_initial_data(repeat('a',64))->>'code')='unauthorized', 'fake token unauthorized');
select pg_temp.ok((rpc_save_asset(repeat('a',64),'{}'::jsonb)->>'code')='unauthorized', 'fake token cannot save asset');

-- departments + users
reset role;
select set_config('t.d1', (select "DeptID" from af.departments order by 1 limit 1), false);
set role anon;
select pg_temp.ok((rpc_save_department(current_setting('t.admin'), '{"DeptName":"กลุ่มงานเทคโนโลยีสารสนเทศ","DeptCode":"IT"}'))::jsonb->>'ok' = 'true', 'admin creates dept');
reset role;
select set_config('t.d2', (select "DeptID" from af.departments where "DeptCode"='IT'), false);
set role anon;

select pg_temp.ok((rpc_save_user(current_setting('t.admin'), jsonb_build_object('Username','dadmin','Password','Passw0rd!x','FullName','เจ้าหน้าที่ IT','Role','DeptAdmin','DepartmentID',current_setting('t.d2'))))->>'ok'='true', 'create DeptAdmin');
select pg_temp.ok((rpc_save_user(current_setting('t.admin'), jsonb_build_object('Username','appr','Password','Passw0rd!x','FullName','หัวหน้า','Role','Approver','DepartmentID',current_setting('t.d1'))))->>'ok'='true', 'create Approver');
select pg_temp.ok(not ((rpc_save_user(current_setting('t.admin'), jsonb_build_object('Username','weak','Password','1234','FullName','x','Role','Borrower','DepartmentID',current_setting('t.d1'))))->>'ok')::boolean, 'weak password (1234) rejected');
select pg_temp.ok((rpc_register_user(jsonb_build_object('FullName','พยาบาล ก','Username','nurse1','Password','Passw0rd!x','DepartmentID',current_setting('t.d1'))))->>'ok'='true', 'self-register Borrower');
select pg_temp.ok(not ((rpc_register_user(jsonb_build_object('FullName','dup','Username','NURSE1','Password','Passw0rd!x','DepartmentID',current_setting('t.d1'))))->>'ok')::boolean, 'duplicate username (case-insens) rejected');
select pg_temp.ok(not ((rpc_register_user(jsonb_build_object('FullName','hax','Username','hax1','Password','Passw0rd!x','Role','SuperAdmin','DepartmentID',current_setting('t.d1'))))->'user'->>'Role' = 'SuperAdmin'), 'register cannot self-assign SuperAdmin');

select set_config('t.da',   rpc_login_user('dadmin','Passw0rd!x')->>'token', false);
select set_config('t.appr', rpc_login_user('appr','Passw0rd!x')->>'token', false);
select set_config('t.nurse',rpc_login_user('nurse1','Passw0rd!x')->>'token', false);

-- RBAC on admin-only ops
select pg_temp.ok((rpc_save_department(current_setting('t.nurse'),'{"DeptName":"x"}')->>'code')='forbidden', 'borrower cannot save dept');
select pg_temp.ok((rpc_save_user(current_setting('t.da'),'{"Username":"zzzz","Password":"Passw0rd!x","FullName":"z","Role":"SuperAdmin"}')->>'code')='forbidden', 'DeptAdmin cannot create users');
select pg_temp.ok((rpc_save_settings(current_setting('t.appr'),'{"AppTitle":"x"}')->>'code')='forbidden', 'approver cannot change settings');
select pg_temp.ok((rpc_save_asset(current_setting('t.nurse'),'{"AssetCode":"X","AssetName":"x"}')->>'code')='forbidden', 'borrower cannot create asset');

-- assets: DeptAdmin limited to own dept
select pg_temp.ok((rpc_save_asset(current_setting('t.da'), jsonb_build_object('AssetCode','EQ-IT-001','AssetName','Notebook','DepartmentID',current_setting('t.d2'),'Price',25000,'Status','พร้อมให้ยืม')))->>'ok'='true', 'DeptAdmin creates asset in own dept');
select pg_temp.ok((rpc_save_asset(current_setting('t.da'), jsonb_build_object('AssetCode','EQ-X-002','AssetName','Other','DepartmentID',current_setting('t.d1'))))->>'code'='forbidden', 'DeptAdmin cannot create asset in other dept');
select pg_temp.ok(not ((rpc_save_asset(current_setting('t.da'), jsonb_build_object('AssetCode','eq-it-001','AssetName','Dup','DepartmentID',current_setting('t.d2'))))->>'ok')::boolean, 'duplicate asset code rejected');
select pg_temp.ok(not ((rpc_save_asset(current_setting('t.admin'), jsonb_build_object('AssetCode','EQ-BAD','AssetName','img','DepartmentID',current_setting('t.d1'),'ImageBase64','data:image/svg+xml;base64,PHN2Zz4=')))->>'ok')::boolean, 'svg data-URL rejected');
select pg_temp.ok(not ((rpc_save_asset(current_setting('t.admin'), jsonb_build_object('AssetCode','EQ-BAD2','AssetName','img','DepartmentID',current_setting('t.d1'),'ImageUrl','javascript:alert(1)')))->>'ok')::boolean, 'javascript: image URL rejected');
select pg_temp.ok((rpc_save_asset(current_setting('t.admin'), jsonb_build_object('AssetCode','EQ-OK-IMG','AssetName','img ok','DepartmentID',current_setting('t.d1'),'ImageBase64','data:image/jpeg;base64,/9j/4AAQSkZJRg==')))->>'ok'='true', 'jpeg data-URL accepted');
reset role;
select set_config('t.a1', (select "AssetID" from af.assets where "AssetCode"='EQ-IT-001'), false);
set role anon;

-- borrow flow
select pg_temp.ok(not ((rpc_create_borrow_request(current_setting('t.nurse'), jsonb_build_object('AssetID',current_setting('t.a1'),'BorrowDate',to_char(now(),'YYYY-MM-DD'),'DueDate',to_char(now()+interval '30 days','YYYY-MM-DD'),'Purpose','ทดสอบ')))->>'ok')::boolean, 'borrow beyond MaxBorrowDays rejected');
select pg_temp.ok((rpc_create_borrow_request(current_setting('t.nurse'), jsonb_build_object('AssetID',current_setting('t.a1'),'BorrowDate',to_char(now(),'YYYY-MM-DD'),'DueDate',to_char(now()+interval '2 days','YYYY-MM-DD'),'Purpose','ใช้ประชุม','BorrowerID','USR-001','BorrowerName','spoof')))->>'status'='รออนุมัติ', 'borrow request created (รออนุมัติ)');
reset role;
select set_config('t.b1', (select "BorrowID" from af.borrows limit 1), false);
select pg_temp.ok((select "BorrowerName" from af.borrows limit 1) = 'พยาบาล ก', 'borrower identity comes from token, not payload');
set role anon;
select pg_temp.ok((rpc_process_borrow_action(current_setting('t.nurse'), jsonb_build_object('BorrowID',current_setting('t.b1'),'action','approve')))->>'code'='forbidden', 'borrower cannot approve own request');
select pg_temp.ok((rpc_process_borrow_action(current_setting('t.appr'), jsonb_build_object('BorrowID',current_setting('t.b1'),'action','approve_handover','ConditionBefore','สมบูรณ์')))->>'ok'='true', 'approver approve+handover');
reset role;
select pg_temp.ok((select "Status" from af.assets where "AssetID"=current_setting('t.a1'))='ถูกยืม', 'asset marked ถูกยืม');
set role anon;
select pg_temp.ok(not ((rpc_process_borrow_action(current_setting('t.appr'), jsonb_build_object('BorrowID',current_setting('t.b1'),'action','approve')))->>'ok')::boolean, 'cannot approve twice');
select pg_temp.ok((rpc_process_borrow_action(current_setting('t.appr'), jsonb_build_object('BorrowID',current_setting('t.b1'),'action','return','ReturnDate',to_char(now()+interval '5 days','YYYY-MM-DD'),'ConditionAfter','ปกติ','isDamaged',true,'DamageDetail','จอแตก')))->>'ok'='true', 'return damaged asset');
reset role;
select pg_temp.ok((select "Status" from af.assets where "AssetID"=current_setting('t.a1'))='ส่งซ่อม', 'damaged return -> asset ส่งซ่อม');
select pg_temp.ok((select count(*) from af.maintenances)=1, 'maintenance auto-created on damage');
select pg_temp.ok((select "OverdueDays" from af.borrows limit 1) >= 3, 'overdue days computed server-side');
set role anon;

-- maintenance flow
reset role;
select set_config('t.m1', (select "MaintID" from af.maintenances limit 1), false);
set role anon;
select pg_temp.ok((rpc_save_maintenance(current_setting('t.nurse'), jsonb_build_object('MaintID',current_setting('t.m1'),'AssetID',current_setting('t.a1'),'IssueDetail','x','Status','ซ่อมเสร็จ')))->>'code'='forbidden', 'borrower cannot close maintenance');
select pg_temp.ok((rpc_save_maintenance(current_setting('t.da'), jsonb_build_object('MaintID',current_setting('t.m1'),'AssetID',current_setting('t.a1'),'IssueDetail','จอแตก','Status','ซ่อมเสร็จ','Cost',1500)))->>'ok'='true', 'DeptAdmin completes maintenance');
reset role;
select pg_temp.ok((select "Status" from af.assets where "AssetID"=current_setting('t.a1'))='พร้อมให้ยืม', 'repair complete -> asset available');
set role anon;

-- data scoping
select pg_temp.ok(jsonb_array_length(rpc_get_initial_data(current_setting('t.nurse'))->'data'->'users')=0, 'borrower receives no users list');
select pg_temp.ok(jsonb_array_length(rpc_get_initial_data(current_setting('t.nurse'))->'data'->'logs')=0, 'borrower receives no logs');
select pg_temp.ok(jsonb_array_length(rpc_get_initial_data(current_setting('t.admin'))->'data'->'users')>=4, 'admin receives users');
select pg_temp.ok(not (rpc_get_initial_data(current_setting('t.admin'))->'data'->'users'->0 ? 'PasswordHash'), 'users list never has PasswordHash');
select pg_temp.ok(rpc_get_initial_data(current_setting('t.admin'))->'data'->'assets'->0 ? 'DepartmentName', 'assets include DepartmentName');

-- dispose + guards
select pg_temp.ok((rpc_dispose_asset(current_setting('t.nurse'), jsonb_build_object('AssetID',current_setting('t.a1'),'Reason','x')))->>'code'='forbidden', 'borrower cannot dispose');
select pg_temp.ok((rpc_dispose_asset(current_setting('t.da'), jsonb_build_object('AssetID',current_setting('t.a1'),'Reason','เสื่อมสภาพ','DisposalMethod','จำหน่าย')))->>'ok'='true', 'DeptAdmin disposes own asset');
select pg_temp.ok(not ((rpc_dispose_asset(current_setting('t.da'), jsonb_build_object('AssetID',current_setting('t.a1'),'Reason','again')))->>'ok')::boolean, 'cannot dispose twice');

-- settings
select pg_temp.ok((rpc_save_settings(current_setting('t.admin'),'{"AppTitle":"ระบบยืม-คืนครุภัณฑ์","MaxBorrowDays":"10","RequireApproval":"true","EvilKey":"x"}'))->>'ok'='true', 'admin saves settings');
select pg_temp.ok(not ((rpc_save_settings(current_setting('t.admin'),'{"AppTitle":"x","MaxBorrowDays":"abc"}'))->>'ok')::boolean, 'invalid MaxBorrowDays rejected');
reset role;
select pg_temp.ok(not exists(select 1 from af.settings where "Key"='EvilKey'), 'unknown settings keys ignored');
set role anon;

-- last SuperAdmin protection + self delete
select pg_temp.ok(not ((rpc_delete_user(current_setting('t.admin'),'USR-001'))->>'ok')::boolean, 'admin cannot delete self');
reset role;
select set_config('t.adminid', (select "UserID" from af.users where "Username"='admin'), false);
set role anon;
select pg_temp.ok(not ((rpc_save_user(current_setting('t.admin'), jsonb_build_object('UserID',current_setting('t.adminid'),'Username','admin','FullName','ผู้ดูแลระบบ','Role','Borrower','DepartmentID',current_setting('t.d1'))))->>'ok')::boolean, 'cannot demote the last SuperAdmin');

-- session revoke on password change + logout
select pg_temp.ok((rpc_save_user(current_setting('t.admin'), jsonb_build_object('UserID',(select 'x'),'Username','x')))->>'ok' <> 'true', 'bad UserID update fails');
reset role;
select set_config('t.nurseid', (select "UserID" from af.users where "Username"='nurse1'), false);
set role anon;
select pg_temp.ok((rpc_save_user(current_setting('t.admin'), jsonb_build_object('UserID',current_setting('t.nurseid'),'Username','nurse1','FullName','พยาบาล ก','Role','Borrower','DepartmentID',current_setting('t.d1'),'Password','NewPassw0rd!')))->>'ok'='true', 'admin resets user password');
select pg_temp.ok((rpc_get_initial_data(current_setting('t.nurse'))->>'code')='unauthorized', 'old session revoked after password reset');
select set_config('t.nurse', rpc_login_user('nurse1','NewPassw0rd!')->>'token', false);
select pg_temp.ok((rpc_logout(current_setting('t.nurse')))->>'ok'='true', 'logout ok');
select pg_temp.ok((rpc_get_initial_data(current_setting('t.nurse'))->>'code')='unauthorized', 'token invalid after logout');

-- brute-force lock
select rpc_login_user('appr','bad1'); select rpc_login_user('appr','bad2'); select rpc_login_user('appr','bad3'); select rpc_login_user('appr','bad4'); select rpc_login_user('appr','bad5');
select pg_temp.ok((rpc_login_user('appr','Passw0rd!x')->>'code')='locked', 'account locked after 5 failures (even with right password)');
reset role;
select 'ALL TESTS PASSED';
