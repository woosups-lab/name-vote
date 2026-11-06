# 법인명 스티커 투표 보드

남동공단 데이터센터 법인명 후보 중 마음에 드는 이름에 스티커를 붙이는 온라인 투표 보드입니다.
실제 보드에 스티커를 붙이는 방식과 같습니다. 링크만 있으면 로그인 없이 카톡이나 이메일에서 바로 참여할 수 있습니다.

- 후보 카드의 스티커 칸을 누르면 누른 자리에 스티커가 붙고, 모든 사람 화면에 실시간으로 나타납니다.
- 기기 하나에 스티커 한 장입니다. 마감 전까지 옮기거나 뗄 수 있습니다.
- 투표 결과는 법인명 선정에 참고만 합니다. 가장 많이 받은 이름이 반드시 선정되는 것은 아닙니다.
- 새 이름 제안은 투표 대상이 아니며 관리자만 볼 수 있습니다.
- 관리자는 화면 맨 아래 `관리자`에서 투표 기간을 정하고 제안을 확인합니다.

## 구성

| 경로 | 내용 |
| --- | --- |
| `index.html` | 투표 보드 |
| `og.png` | 카톡·메일 링크 미리보기 이미지 |
| `vendor/supabase.js` | Supabase 클라이언트 |
| `supabase/schema.sql` | 서버 구조와 권한 규칙 |
| `scripts/serve.mjs` | 개발용 서버 (`node scripts/serve.mjs`, http://localhost:8123/) |
| `.github/workflows/deploy.yml` | GitHub Pages 배포 |

## 처음 설정

1. **Supabase 프로젝트**: 새로 만들거나 기존 프로젝트를 함께 씁니다. 표 이름이 모두 `vote_`로 시작해서 겹치지 않습니다.
2. **서버 구조**: SQL Editor에서 `supabase/schema.sql`을 실행합니다.
3. **후보 넣기**: 후보를 넣는 SQL을 실행합니다. 후보 법인명은 공개 저장소에 두지 않으므로 SQL은 따로 보관합니다.
   형식은 아래 예시를 참고합니다.
4. **관리자 등록**: Authentication > Users에서 관리자 계정을 만든 뒤 SQL Editor에서 등록합니다.
   ```sql
   insert into public.vote_admins (user_id) select id from auth.users where email = '관리자@회사.com';
   ```
5. **GitHub 설정**
   - Settings > Secrets and variables > Actions에 `SUPABASE_URL`, `SUPABASE_KEY`(anon 공개 키)를 넣습니다.
   - Settings > Pages의 Source를 `GitHub Actions`로 둡니다.
   - main에 올리면 배포됩니다. 주소는 `https://<계정>.github.io/<저장소>/`입니다.

후보 넣기 SQL 형식:

```sql
insert into public.vote_polls (id, title, options) values ('namdong', '법인명 선정', $json$[
  {"id":"1","no":"1안","tagline":"한 줄 설명","name":"후보 이름","en":"ENGLISH NAME",
   "parts":[["AX","AI 전환"],["DX","디지털 전환"]], "meaning":"이름의 의미"}
]$json$::jsonb)
on conflict (id) do update set title = excluded.title, options = excluded.options;
```

다시 실행하면 후보 내용만 바뀌고 붙은 스티커는 그대로 남습니다.

## 중복 투표

- 브라우저에 저장한 무작위 기기 키로 구별하며, 서버에는 해시만 남습니다.
- 시크릿 창이나 다른 브라우저로 열면 다른 기기로 셀 수 있습니다.
  같은 폰의 카톡 안 브라우저와 크롬도 다른 기기로 셀 수 있습니다.
- 회사 PC는 같은 기종이 많아 기기 특징만으로 막으면 다른 사람이 막힐 수 있습니다.
  그래서 막지 않고, 관리자 화면에 같은 인터넷 주소와 같은 기기 특징으로 붙은 의심 수만 보여줍니다.

## 미리보기

서버 없이 화면만 보려면 `node scripts/serve.mjs` 후 http://localhost:8123/?demo 로 엽니다.
`demo.json`에 후보 목록(위 options 배열)을 두면 그 후보로 보입니다. 이 파일은 저장소에 올리지 않습니다.
`?demo&fill=30`을 붙이면 예시 스티커 30장이 보입니다.

## 운영 메모

- Supabase 무료 플랜은 1주일 동안 접속이 없으면 일시정지됩니다. 투표 기간 중에는 접속이 있어 괜찮지만, 시작 전에 오래 비워 두었다면 대시보드에서 다시 켭니다.
- 투표를 새로 하려면 `?poll=다른ID` 링크와 새 `vote_polls` 행을 쓰면 됩니다.
