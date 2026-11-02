-- ============================================================
-- Luce Chapel Bible Reading 종합 통계 RPC 함수 (v1.3)
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
  p_base_date   DATE DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Seoul')::DATE
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
  -- 5. 완료된 읽기 기록 (KST 기준일자 이전)
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
      AND (r.updated_at AT TIME ZONE 'Asia/Seoul')::DATE <= p_base_date
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
  -- 8. 기간 범위: record 테이블의 첫 기록일 ~ 기준일자(p_base_date)
  record_range AS (
    SELECT COALESCE(MIN(read_date), p_base_date) AS start_date,
           p_base_date AS end_date
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
           ufd.ot_finished_at,
           ufd.nt_finished_at,
           ufd.all_finished_at
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
      GREATEST(1, (rr.end_date - rr.start_date + 1)) AS elapsed_days,
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
  -- 11. 일자별 트렌드
  daily_trend AS (
    SELECT COALESCE(JSONB_AGG(sub), '[]'::JSONB) AS json_val
    FROM (
      SELECT read_date::TEXT AS date, COUNT(*)::BIGINT AS chapters
      FROM tgt_records
      GROUP BY read_date
      ORDER BY read_date ASC
    ) sub
  ),
  -- 12. 최다 읽은 날 Top 5
  top_days AS (
    SELECT COALESCE(JSONB_AGG(sub), '[]'::JSONB) AS json_val
    FROM (
      SELECT ROW_NUMBER() OVER(ORDER BY COUNT(*) DESC, read_date DESC) AS rank,
             read_date::TEXT AS date,
             COUNT(*)::BIGINT AS chapters,
             CASE EXTRACT(DOW FROM read_date)::INT
               WHEN 0 THEN '일' WHEN 1 THEN '월' WHEN 2 THEN '화'
               WHEN 3 THEN '수' WHEN 4 THEN '목' WHEN 5 THEN '금' ELSE '토'
             END AS dow
      FROM tgt_records
      GROUP BY read_date
      ORDER BY chapters DESC, read_date DESC
      LIMIT 5
    ) sub
  ),
  -- 13. 최소 읽은 날 Top 5
  bottom_days AS (
    SELECT COALESCE(JSONB_AGG(sub), '[]'::JSONB) AS json_val
    FROM (
      SELECT ROW_NUMBER() OVER(ORDER BY COUNT(*) ASC, read_date ASC) AS rank,
             read_date::TEXT AS date,
             COUNT(*)::BIGINT AS chapters,
             CASE EXTRACT(DOW FROM read_date)::INT
               WHEN 0 THEN '일' WHEN 1 THEN '월' WHEN 2 THEN '화'
               WHEN 3 THEN '수' WHEN 4 THEN '목' WHEN 5 THEN '금' ELSE '토'
             END AS dow
      FROM tgt_records
      GROUP BY read_date
      ORDER BY chapters ASC, read_date ASC
      LIMIT 5
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
  -- 15. 요일별 차트 (일~토)
  dow_data AS (
    SELECT COALESCE(JSONB_AGG(sub), '[]'::JSONB) AS json_val
    FROM (
      WITH days(num, name) AS (
        VALUES (0, '일'), (1, '월'), (2, '화'), (3, '수'), (4, '목'), (5, '금'), (6, '토')
      )
      SELECT d.num, d.name AS day, COALESCE(COUNT(r.id), 0)::BIGINT AS chapters
      FROM days d
      LEFT JOIN tgt_records r ON r.dow_num = d.num
      GROUP BY d.num, d.name
      ORDER BY d.num ASC
    ) sub
  ),
  -- 16. 시간대별 차트 (0시~23시)
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
      LEFT JOIN tgt_records r ON r.hour_num = h.h
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
    'ministry', jsonb_build_object(
      'code_cd', p_ministry_cd,
      'code_nm', (SELECT ministry_nm FROM ministry_info),
      'description', (SELECT ministry_desc FROM ministry_info)
    ),
    'as_of_date', p_base_date::TEXT,
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
