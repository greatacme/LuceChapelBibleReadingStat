-- 전체 완료 기록 기준 집계: 날짜 필터 없음, 기간은 최초~최종 기록일(양 끝 포함).
-- ============================================================
-- Luce Chapel Bible Reading 종합 통계 RPC 함수 (ver 1.3.2026.1103)
-- ============================================================
-- 변경 사항:
-- 1. [버그 수정] 완독 달성일(finished_at) 정확한 고정일자 산출:
--    - 기존: 기준일자(p_base_date)까지의 마지막 활동일(MAX)을 가져와 기준일이 바뀌면 완독일도 바뀌는 문제 발생
--    - 수정: 구약 929번째, 신약 260번째, 전체 1,189번째 장을 '실제 완독 달성한 날'을 고정 산출하여 기준일자가 바뀌어도 순위와 달성일이 불변 유지
-- 2. 조별 완독률 표에 [전체 / 구약 / 신약] 완독 100% 회원수 및 완독률 제공
-- 3. 순수 읽기 전용(STABLE) CTE 방식 유지 (테이블 변경/삭제 일체 없음)
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_bible_reading_stats(
  p_ministry_cd TEXT DEFAULT '0',
  -- 기존 호출 호환용 인자. 날짜 필터는 적용하지 않음.
  p_base_date   DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  WITH
  -- 1. 대상 시즌 기본 정보
  ministry_info AS (
    SELECT COALESCE(code_nm, '2026 연세대학교회 성경통독') AS ministry_nm,
           COALESCE(description, '연세대학교회') AS ministry_desc
    FROM public."COMM_CODE"
    WHERE code_group = 'ministry' AND code_cd = p_ministry_cd
    UNION ALL
    SELECT '2026 연세대학교회 성경통독', '연세대학교회'
    LIMIT 1
  ),
  -- 2. 해당 시즌 소속 그룹
  tgt_groups AS (
    SELECT g.group_code,
           COALESCE(g.group_nm, g.group_code) AS group_nm,
           COALESCE(g.plan_set_cd, '1') AS plan_set_cd
    FROM public.groups g
    WHERE g.ministry_cd = p_ministry_cd
  ),
  -- 3. 대상 사용자
  tgt_users AS (
    SELECT u.id, u.nickname, u.group_code, tg.group_nm, tg.plan_set_cd
    FROM public.users u
    JOIN tgt_groups tg ON u.group_code = tg.group_code
  ),
  -- 4. 대상 플랜 및 구약/신약 구분
  tgt_plans AS (
    SELECT pl.id, pl.date, pl.book, pl.chapter_no, pl.plan_set_cd,
           COALESCE(b.testament, 'OT') AS testament
    FROM public.plans pl
    JOIN (SELECT DISTINCT plan_set_cd FROM tgt_groups) g ON pl.plan_set_cd = g.plan_set_cd
    LEFT JOIN public.book b ON b.name_ko = pl.book
  ),
  -- 5. 해당 시즌의 전체 완료 기록 (날짜 제한 없음, KST로 날짜/시간 집계)
  tgt_records AS (
    SELECT r.id,
           r.user_id,
           r.plan_id,
           r.updated_at,
           (r.updated_at AT TIME ZONE 'Asia/Seoul')::DATE AS read_date,
           TO_CHAR(r.updated_at AT TIME ZONE 'Asia/Seoul', 'YYYY-MM') AS read_month,
           EXTRACT(DOW FROM (r.updated_at AT TIME ZONE 'Asia/Seoul'))::INT AS dow_num,
           EXTRACT(HOUR FROM (r.updated_at AT TIME ZONE 'Asia/Seoul'))::INT AS hour_num,
           u.nickname,
           u.group_code,
           u.group_nm,
           tp.testament
    FROM public.records r
    JOIN tgt_users u ON r.user_id = u.id
    JOIN tgt_plans tp ON r.plan_id = tp.id
    WHERE r.completed = true
  ),
  -- 1인 KST 하루 50장 이상인 사용자/날짜의 기록만 패턴 통계에서 제외.
  -- 개요/월별/조별/개인 진도율은 원본 tgt_records를 그대로 사용.
  user_daily_counts AS (
    SELECT user_id, read_date, COUNT(*) AS chapters
    FROM tgt_records
    GROUP BY user_id, read_date
  ),
  pattern_records AS (
    SELECT r.* FROM tgt_records r
    JOIN user_daily_counts d ON d.user_id = r.user_id AND d.read_date = r.read_date
    WHERE d.chapters < 50
  ),
  -- 6. 사용자별 구약/신약/전체 장별 완료 순번 부여 (정확한 완독 달성일 계산용)
  ranked_records AS (
    SELECT r.user_id,
           r.testament,
           r.read_date,
           ROW_NUMBER() OVER (
             PARTITION BY r.user_id, r.testament
             ORDER BY r.updated_at ASC, r.id ASC
           ) AS testament_seq,
           ROW_NUMBER() OVER (
             PARTITION BY r.user_id
             ORDER BY r.updated_at ASC, r.id ASC
           ) AS total_seq
    FROM tgt_records r
  ),
  -- 7. 사용자별 정확한 완독 달성 일자
  user_finish_dates AS (
    SELECT user_id,
           -- 구약 929번째 완료 일자
           COALESCE(
             MAX(read_date) FILTER (WHERE testament = 'OT' AND testament_seq = 929),
             MAX(read_date) FILTER (WHERE testament = 'OT')
           ) AS ot_finished_at,
           -- 신약 260번째 완료 일자
           COALESCE(
             MAX(read_date) FILTER (WHERE testament = 'NT' AND testament_seq = 260),
             MAX(read_date) FILTER (WHERE testament = 'NT')
           ) AS nt_finished_at,
           -- 전체 1,189번째 완료 일자
           COALESCE(
             MAX(read_date) FILTER (WHERE total_seq = 1189),
             MAX(read_date)
           ) AS all_finished_at
    FROM ranked_records
    GROUP BY user_id
  ),
  -- 8. 기간 범위: 대량 등록을 포함한 전체 완료 기록의 첫 기록일 ~ 마지막 기록일
  record_range AS (
    SELECT MIN(read_date) AS start_date,
           MAX(read_date) AS end_date
    FROM tgt_records
  ),
  -- 9. 사용자별 누적 완독 현황
  user_progress AS (
    SELECT u.id AS user_id,
           u.nickname,
           u.group_code,
           u.group_nm,
           COUNT(r.id) FILTER (WHERE tp.testament = 'OT') AS ot_count,
           COUNT(r.id) FILTER (WHERE tp.testament = 'NT') AS nt_count,
           COUNT(r.id) AS total_count,
           CASE WHEN COUNT(r.id) FILTER (WHERE tp.testament = 'OT') >= 929 THEN ufd.ot_finished_at END AS ot_finished_at,
           CASE WHEN COUNT(r.id) FILTER (WHERE tp.testament = 'NT') >= 260 THEN ufd.nt_finished_at END AS nt_finished_at,
           CASE WHEN COUNT(r.id) >= 1189 THEN ufd.all_finished_at END AS all_finished_at
    FROM tgt_users u
    LEFT JOIN tgt_records r ON r.user_id = u.id
    LEFT JOIN tgt_plans tp ON r.plan_id = tp.id
    LEFT JOIN user_finish_dates ufd ON ufd.user_id = u.id
    GROUP BY u.id, u.nickname, u.group_code, u.group_nm,
             ufd.ot_finished_at, ufd.nt_finished_at, ufd.all_finished_at
  ),
  -- 10. 개요 요약
  overview_data AS (
    SELECT
      rr.start_date::TEXT AS start_date,
      rr.end_date::TEXT AS end_date,
      COALESCE(rr.end_date - rr.start_date + 1, 0) AS elapsed_days,
      (SELECT COUNT(*) FROM tgt_users) AS total_users,
      (SELECT COUNT(DISTINCT user_id) FROM tgt_records) AS active_users,
      (SELECT COUNT(*) FROM tgt_records) AS total_read_chapters,
      CASE WHEN (SELECT COUNT(*) FROM tgt_users) > 0 AND (rr.end_date - rr.start_date + 1) > 0
           THEN ROUND((SELECT COUNT(*) FROM tgt_records)::NUMERIC / GREATEST(1, (rr.end_date - rr.start_date + 1)) / (SELECT COUNT(*) FROM tgt_users), 2)
           ELSE 0
      END AS daily_avg_per_user,
      (SELECT COUNT(*) FROM user_progress WHERE ot_count >= 929) AS ot_finishers_cnt,
      CASE WHEN (SELECT COUNT(*) FROM tgt_users) > 0
           THEN ROUND((SELECT COUNT(*) FROM user_progress WHERE ot_count >= 929)::NUMERIC / (SELECT COUNT(*) FROM tgt_users) * 100, 1)
           ELSE 0
      END AS ot_rate,
      (SELECT COUNT(*) FROM user_progress WHERE nt_count >= 260) AS nt_finishers_cnt,
      CASE WHEN (SELECT COUNT(*) FROM tgt_users) > 0
           THEN ROUND((SELECT COUNT(*) FROM user_progress WHERE nt_count >= 260)::NUMERIC / (SELECT COUNT(*) FROM tgt_users) * 100, 1)
           ELSE 0
      END AS nt_rate,
      (SELECT COUNT(*) FROM user_progress WHERE (ot_count >= 929 AND nt_count >= 260) OR total_count >= 1189) AS all_finishers_cnt,
      CASE WHEN (SELECT COUNT(*) FROM tgt_users) > 0
           THEN ROUND((SELECT COUNT(*) FROM user_progress WHERE (ot_count >= 929 AND nt_count >= 260) OR total_count >= 1189)::NUMERIC / (SELECT COUNT(*) FROM tgt_users) * 100, 1)
           ELSE 0
      END AS all_rate
    FROM record_range rr
  ),
  -- 기간 전체를 달력으로 생성하여 무기록일도 0장으로 포함.
  calendar_days AS (
    SELECT day::DATE AS read_date
    FROM record_range rr
    CROSS JOIN LATERAL generate_series(rr.start_date::TIMESTAMP, rr.end_date::TIMESTAMP, INTERVAL '1 day') AS day
  ),
  daily_counts AS (
    SELECT c.read_date, COUNT(r.id)::BIGINT AS chapters
    FROM calendar_days c
    LEFT JOIN pattern_records r ON r.read_date = c.read_date
    GROUP BY c.read_date
  ),
  daily_trend AS (
    SELECT COALESCE(JSONB_AGG(jsonb_build_object('date', read_date::TEXT, 'chapters', chapters) ORDER BY read_date), '[]'::JSONB) AS json_val
    FROM daily_counts
  ),
  top_days AS (
    SELECT COALESCE(JSONB_AGG(sub ORDER BY rank), '[]'::JSONB) AS json_val
    FROM (
      SELECT ROW_NUMBER() OVER (ORDER BY chapters DESC, read_date DESC) AS rank,
             read_date::TEXT AS date, chapters,
             (ARRAY['일','월','화','수','목','금','토'])[EXTRACT(DOW FROM read_date)::INT + 1] AS dow
      FROM daily_counts ORDER BY chapters DESC, read_date DESC LIMIT 5
    ) sub
  ),
  bottom_days AS (
    SELECT COALESCE(JSONB_AGG(sub ORDER BY rank), '[]'::JSONB) AS json_val
    FROM (
      SELECT ROW_NUMBER() OVER (ORDER BY chapters ASC, read_date ASC) AS rank,
             read_date::TEXT AS date, chapters,
             (ARRAY['일','월','화','수','목','금','토'])[EXTRACT(DOW FROM read_date)::INT + 1] AS dow
      FROM daily_counts ORDER BY chapters ASC, read_date ASC LIMIT 5
    ) sub
  ),
  -- 14. 월별 차트
  monthly_data AS (
    SELECT COALESCE(JSONB_AGG(sub), '[]'::JSONB) AS json_val
    FROM (
      SELECT read_month AS month, COUNT(*)::BIGINT AS chapters
      FROM tgt_records
      GROUP BY read_month
      ORDER BY read_month ASC
    ) sub
  ),
  -- 요일별 하루 평균: 제외 후 장수 / 기간 내 해당 요일 날짜 수 (0장 포함).
  dow_data AS (
    SELECT COALESCE(JSONB_AGG(sub ORDER BY num), '[]'::JSONB) AS json_val
    FROM (
      SELECT d.num, d.name AS day,
             COALESCE(SUM(c.chapters), 0) AS chapters,
             COUNT(c.read_date) AS day_count,
             COALESCE(ROUND(AVG(c.chapters), 1), 0) AS avg_chapters
      FROM (VALUES (0,'일'),(1,'월'),(2,'화'),(3,'수'),(4,'목'),(5,'금'),(6,'토')) AS d(num,name)
      LEFT JOIN daily_counts c ON EXTRACT(DOW FROM c.read_date)::INT = d.num
      GROUP BY d.num, d.name
    ) sub
  ),
  -- 16. 시간대별 차트 (0시~23시, 1인 하루 50장 이상 등록분 제외)
  hourly_data AS (
    SELECT COALESCE(JSONB_AGG(sub), '[]'::JSONB) AS json_val
    FROM (
      WITH hours AS (
        SELECT generate_series(0, 23) AS h
      )
      SELECT h.h AS hour,
             TO_CHAR(h.h, 'FM00') || '시' AS hour_label,
             COALESCE(COUNT(r.id), 0)::BIGINT AS chapters
      FROM hours h
      LEFT JOIN pattern_records r ON r.hour_num = h.h
      GROUP BY h.h
      ORDER BY h.h ASC
    ) sub
  ),
  -- 17. 조별 완독자 집계 (전체 / 구약 / 신약)
  group_finisher_stats AS (
    SELECT up.group_code,
           COUNT(*) FILTER (WHERE up.ot_count >= 929) AS ot_finishers_cnt,
           COUNT(*) FILTER (WHERE up.nt_count >= 260) AS nt_finishers_cnt,
           COUNT(*) FILTER (WHERE (up.ot_count >= 929 AND up.nt_count >= 260) OR up.total_count >= 1189) AS all_finishers_cnt
    FROM user_progress up
    GROUP BY up.group_code
  ),
  -- 18. 조별 현황 (총 장수 + 1인당 평균 + 완독률 표 데이터)
  groups_data AS (
    SELECT COALESCE(JSONB_AGG(sub), '[]'::JSONB) AS json_val
    FROM (
      SELECT g.group_code,
             g.group_nm,
             COUNT(DISTINCT u.id)::BIGINT AS user_count,
             COUNT(r.id)::BIGINT AS total_chapters,
             ROUND(COUNT(r.id)::NUMERIC / NULLIF(COUNT(DISTINCT u.id), 0), 1) AS avg_per_user,
             COALESCE(gfs.all_finishers_cnt, 0)::BIGINT AS all_finishers_cnt,
             ROUND(COALESCE(gfs.all_finishers_cnt, 0)::NUMERIC / NULLIF(COUNT(DISTINCT u.id), 0) * 100, 1) AS all_rate,
             COALESCE(gfs.ot_finishers_cnt, 0)::BIGINT AS ot_finishers_cnt,
             ROUND(COALESCE(gfs.ot_finishers_cnt, 0)::NUMERIC / NULLIF(COUNT(DISTINCT u.id), 0) * 100, 1) AS ot_rate,
             COALESCE(gfs.nt_finishers_cnt, 0)::BIGINT AS nt_finishers_cnt,
             ROUND(COALESCE(gfs.nt_finishers_cnt, 0)::NUMERIC / NULLIF(COUNT(DISTINCT u.id), 0) * 100, 1) AS nt_rate
      FROM tgt_groups g
      LEFT JOIN tgt_users u ON u.group_code = g.group_code
      LEFT JOIN tgt_records r ON r.user_id = u.id
      LEFT JOIN group_finisher_stats gfs ON gfs.group_code = g.group_code
      GROUP BY g.group_code, g.group_nm, gfs.all_finishers_cnt, gfs.ot_finishers_cnt, gfs.nt_finishers_cnt
      ORDER BY total_chapters DESC, g.group_nm ASC
    ) sub
  ),
  -- 19. 완독자 목록 (정확한 완독 달성일 기준 정렬)
  finishers_all AS (
    SELECT COALESCE(JSONB_AGG(sub), '[]'::JSONB) AS json_val
    FROM (
      SELECT nickname, group_nm, total_count AS chapters, all_finished_at::TEXT AS finished_at
      FROM user_progress
      WHERE (ot_count >= 929 AND nt_count >= 260) OR total_count >= 1189
      ORDER BY all_finished_at ASC, nickname ASC
    ) sub
  ),
  finishers_ot AS (
    SELECT COALESCE(JSONB_AGG(sub), '[]'::JSONB) AS json_val
    FROM (
      SELECT nickname, group_nm, ot_count AS chapters, ot_finished_at::TEXT AS finished_at
      FROM user_progress
      WHERE ot_count >= 929
      ORDER BY ot_finished_at ASC, nickname ASC
    ) sub
  ),
  finishers_nt AS (
    SELECT COALESCE(JSONB_AGG(sub), '[]'::JSONB) AS json_val
    FROM (
      SELECT nickname, group_nm, nt_count AS chapters, nt_finished_at::TEXT AS finished_at
      FROM user_progress
      WHERE nt_count >= 260
      ORDER BY nt_finished_at ASC, nickname ASC
    ) sub
  )
  SELECT jsonb_build_object(
    'stats_version', '1.3.2026.1103',
    'personal_progress', (SELECT COALESCE(JSONB_AGG(TO_JSONB(up) ORDER BY up.total_count DESC, up.nickname, up.user_id), '[]'::JSONB) FROM user_progress up),
    'ministry', jsonb_build_object(
      'code_cd', p_ministry_cd,
      'code_nm', (SELECT ministry_nm FROM ministry_info),
      'description', (SELECT ministry_desc FROM ministry_info)
    ),
    'period_basis', 'record_span',
    'overview', (SELECT TO_JSONB(overview_data.*) FROM overview_data),
    'daily_trend', (SELECT json_val FROM daily_trend),
    'top_days', (SELECT json_val FROM top_days),
    'bottom_days', (SELECT json_val FROM bottom_days),
    'monthly', (SELECT json_val FROM monthly_data),
    'day_of_week', (SELECT json_val FROM dow_data),
    'hourly', (SELECT json_val FROM hourly_data),
    'groups', (SELECT json_val FROM groups_data),
    'finishers', jsonb_build_object(
      'all', (SELECT json_val FROM finishers_all),
      'ot', (SELECT json_val FROM finishers_ot),
      'nt', (SELECT json_val FROM finishers_nt)
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_bible_reading_stats(TEXT, DATE) TO anon;
