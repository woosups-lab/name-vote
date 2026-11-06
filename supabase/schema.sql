-- 법인명 스티커 투표 서버 구조 (Supabase SQL Editor에서 실행). 여러 번 실행해도 안전하다.
--
-- 누구나 링크만 있으면 로그인 없이 보드를 보고 스티커를 붙인다.
--  - 스티커 위치와 개수는 공개(실시간 표시). 누가 붙였는지는 서버에도 남기지 않는다.
--  - 스티커 붙이기·옮기기·떼기와 이름 제안은 아래 함수로만 할 수 있다. 표에 직접 쓰지 못한다.
--  - 기기 하나에 스티커 한 장: 브라우저가 만든 기기 키를 해시로만 저장해 중복을 막는다.
--  - 이름 제안은 투표 대상이 아니며 관리자(vote_admins 표에 있는 계정)만 읽는다.
--  - 후보 법인명은 공개 저장소에 두지 않고 vote_polls.options 에 따로 넣는다 (README 참고).

-- 관리자: Supabase Authentication에서 만든 계정을 이 표에 넣는다 (README 참고)
create table if not exists public.vote_admins (
  user_id uuid primary key references auth.users on delete cascade
);
alter table public.vote_admins enable row level security;
revoke all on public.vote_admins from anon, authenticated;

create or replace function public.vote_is_admin() returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.vote_admins where user_id = auth.uid()) $$;
revoke all on function public.vote_is_admin() from public, anon;
grant execute on function public.vote_is_admin() to authenticated;

create table if not exists public.vote_polls (
  id text primary key,
  title text not null,
  options jsonb not null default '[]',   -- [{id, no, tagline, name, en, parts:[[굵은 글자, 설명]], meaning}]
  opens_at timestamptz,                  -- 비어 있으면 바로 시작
  closes_at timestamptz,                 -- 비어 있으면 마감 없음
  updated_at timestamptz not null default now()
);

create table if not exists public.vote_stickers (
  id uuid primary key default gen_random_uuid(),
  poll_id text not null references public.vote_polls on delete cascade,
  option_id text not null,
  x real not null check (x between 0 and 1),   -- 스티커 칸 안의 위치(비율)
  y real not null check (y between 0 and 1),
  color smallint not null default 0 check (color between 0 and 11),
  updated_at timestamptz not null default now()
);
create index if not exists vote_stickers_poll on public.vote_stickers (poll_id);

-- 비공개: 기기 키 해시 → 그 기기의 스티커. 아무도 직접 읽지 못한다.
create table if not exists public.vote_devices (
  poll_id text not null references public.vote_polls on delete cascade,
  device_hash text not null,
  sticker_id uuid references public.vote_stickers on delete set null,
  fp_hash text,        -- 기기 특징 해시 (같은 기기의 다른 브라우저 추정용, 참고만)
  ip_hash text,
  proposals int not null default 0,
  created_at timestamptz not null default now(),
  primary key (poll_id, device_hash)
);

create table if not exists public.vote_proposals (
  id uuid primary key default gen_random_uuid(),
  poll_id text not null references public.vote_polls on delete cascade,
  name text not null check (char_length(name) between 1 and 40),
  reason text check (char_length(reason) <= 500),
  proposer text check (char_length(proposer) <= 30),
  created_at timestamptz not null default now()
);

alter table public.vote_polls enable row level security;
alter table public.vote_stickers enable row level security;
alter table public.vote_devices enable row level security;
alter table public.vote_proposals enable row level security;

drop policy if exists "투표 공개 읽기" on public.vote_polls;
drop policy if exists "투표 관리자 수정" on public.vote_polls;
drop policy if exists "스티커 공개 읽기" on public.vote_stickers;
drop policy if exists "제안 관리자 읽기" on public.vote_proposals;
drop policy if exists "제안 관리자 삭제" on public.vote_proposals;
create policy "투표 공개 읽기" on public.vote_polls for select to anon, authenticated using (true);
create policy "투표 관리자 수정" on public.vote_polls for update to authenticated using (public.vote_is_admin()) with check (public.vote_is_admin());
create policy "스티커 공개 읽기" on public.vote_stickers for select to anon, authenticated using (true);
create policy "제안 관리자 읽기" on public.vote_proposals for select to authenticated using (public.vote_is_admin());
create policy "제안 관리자 삭제" on public.vote_proposals for delete to authenticated using (public.vote_is_admin());

revoke all on public.vote_polls, public.vote_stickers, public.vote_devices, public.vote_proposals from anon, authenticated;
grant select on public.vote_polls, public.vote_stickers to anon, authenticated;
grant update (opens_at, closes_at) on public.vote_polls to authenticated;
grant select, delete on public.vote_proposals to authenticated;

create or replace function public.touch_vote_poll() returns trigger
language plpgsql set search_path = ''
as $$ begin new.updated_at := now(); return new; end $$;
drop trigger if exists vote_polls_touch on public.vote_polls;
create trigger vote_polls_touch before update on public.vote_polls for each row execute function public.touch_vote_poll();

-- 내부용: 기간 확인, 기기 행 확보(잠금)
create or replace function public.vote_device(p_poll text, p_device text, p_fp text, p_need_open boolean)
returns public.vote_devices
language plpgsql security definer set search_path = ''
as $$
declare
  p public.vote_polls;
  d public.vote_devices;
  h text;
  ip text := split_part(coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''), ',', 1);
begin
  select * into p from public.vote_polls where id = p_poll;
  if not found then raise exception '투표를 찾을 수 없습니다'; end if;
  if p_need_open and p.opens_at is not null and now() < p.opens_at then raise exception '아직 투표 시작 전입니다'; end if;
  if p.closes_at is not null and now() >= p.closes_at then raise exception '투표가 마감되었습니다'; end if;
  if p_device is null or length(p_device) < 16 or length(p_device) > 100 then raise exception '기기 정보가 올바르지 않습니다'; end if;
  h := encode(sha256(convert_to(p_poll || ':' || p_device, 'UTF8')), 'hex');
  insert into public.vote_devices (poll_id, device_hash, fp_hash, ip_hash)
  values (p_poll, h, left(p_fp, 100), case when ip <> '' then encode(sha256(convert_to(p_poll || ':' || ip, 'UTF8')), 'hex') end)
  on conflict (poll_id, device_hash) do nothing;
  select * into d from public.vote_devices where poll_id = p_poll and device_hash = h for update;
  return d;
end $$;
revoke all on function public.vote_device(text, text, text, boolean) from public, anon, authenticated;

-- 스티커 붙이기. 이미 붙인 기기면 새 자리로 옮긴다. 붙은 스티커의 id를 돌려준다.
create or replace function public.vote_place(p_poll text, p_device text, p_option text, p_x real, p_y real, p_color int, p_fp text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare d public.vote_devices; sid uuid;
begin
  d := public.vote_device(p_poll, p_device, p_fp, true);
  if not exists (select 1 from public.vote_polls, jsonb_array_elements(options) o where id = p_poll and o ->> 'id' = p_option) then
    raise exception '후보를 찾을 수 없습니다';
  end if;
  p_x := least(greatest(coalesce(p_x, 0.5), 0), 1);
  p_y := least(greatest(coalesce(p_y, 0.5), 0), 1);
  p_color := least(greatest(coalesce(p_color, 0), 0), 11);
  if d.sticker_id is not null then
    update public.vote_stickers set option_id = p_option, x = p_x, y = p_y, color = p_color, updated_at = now()
     where id = d.sticker_id returning id into sid;
  end if;
  if sid is null then
    insert into public.vote_stickers (poll_id, option_id, x, y, color) values (p_poll, p_option, p_x, p_y, p_color) returning id into sid;
    update public.vote_devices set sticker_id = sid where poll_id = d.poll_id and device_hash = d.device_hash;
  end if;
  return sid;
end $$;

-- 내 스티커 떼기
create or replace function public.vote_remove(p_poll text, p_device text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare d public.vote_devices;
begin
  d := public.vote_device(p_poll, p_device, null, true);
  if d.sticker_id is not null then delete from public.vote_stickers where id = d.sticker_id; end if;
end $$;

-- 이 기기가 붙인 스티커 id (없으면 null). 기간과 상관없이 확인할 수 있다.
create or replace function public.vote_mine(p_poll text, p_device text)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select sticker_id from public.vote_devices
   where poll_id = p_poll and device_hash = encode(sha256(convert_to(p_poll || ':' || coalesce(p_device, ''), 'UTF8')), 'hex')
$$;

-- 새 이름 제안 (투표 대상 아님, 관리자만 읽음). 기기당 5건까지, 마감 전까지.
create or replace function public.vote_propose(p_poll text, p_device text, p_name text, p_reason text default null, p_proposer text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare d public.vote_devices;
begin
  d := public.vote_device(p_poll, p_device, null, false);
  if d.proposals >= 5 then raise exception '제안은 한 기기에서 5건까지 보낼 수 있습니다'; end if;
  p_name := btrim(coalesce(p_name, ''));
  if p_name = '' then raise exception '제안할 이름을 적어주세요'; end if;
  insert into public.vote_proposals (poll_id, name, reason, proposer)
  values (p_poll, left(p_name, 40), nullif(left(btrim(coalesce(p_reason, '')), 500), ''), nullif(left(btrim(coalesce(p_proposer, '')), 30), ''));
  update public.vote_devices set proposals = proposals + 1 where poll_id = d.poll_id and device_hash = d.device_hash;
end $$;

-- 관리자용 집계: 참여 기기 수와 같은 기기로 추정되는 스티커 수(같은 IP + 같은 기기 특징)
create or replace function public.vote_admin_stats(p_poll text)
returns json
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.vote_is_admin() then raise exception '관리자만 볼 수 있습니다'; end if;
  return json_build_object(
    'devices', (select count(*) from public.vote_devices where poll_id = p_poll),
    'stickers', (select count(*) from public.vote_stickers where poll_id = p_poll),
    'suspect', (select coalesce(sum(n - 1), 0) from (
                  select count(*) n from public.vote_devices
                   where poll_id = p_poll and sticker_id is not null and fp_hash is not null and ip_hash is not null
                   group by fp_hash, ip_hash having count(*) > 1) g)
  );
end $$;

revoke all on function public.vote_place(text, text, text, real, real, int, text), public.vote_remove(text, text),
  public.vote_mine(text, text), public.vote_propose(text, text, text, text, text), public.vote_admin_stats(text) from public;
grant execute on function public.vote_place(text, text, text, real, real, int, text), public.vote_remove(text, text),
  public.vote_mine(text, text), public.vote_propose(text, text, text, text, text) to anon, authenticated;
grant execute on function public.vote_admin_stats(text) to authenticated;

-- 실시간 표시: 스티커와 기간 변경을 화면에 바로 보낸다
do $$
begin
  begin alter publication supabase_realtime add table public.vote_stickers; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.vote_polls; exception when duplicate_object then null; end;
end $$;
