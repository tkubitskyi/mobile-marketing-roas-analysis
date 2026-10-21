-- Mobile App Marketing Mart: daily campaign-level spend, installs, revenue and ROAS
-- Grain: report_date (install / spend date) + app_id + media_source + campaign_id
-- Revenue is attributed to the install date of the user (cohort approach).
-- Each source is aggregated separately before joining to avoid row multiplication.
-- Unattributed traffic is kept as campaign_id = -1 so totals match the raw tables.
-- D7 / D30 revenue windows + cohort maturity flags allow fair comparison of campaigns of different age.

-- Last install date in the data: used to decide which cohorts are mature for D7 / D30
WITH period_bounds AS (
  SELECT MAX(DATE(install_date)) AS max_install_date
  FROM `your_project.app_dataset.non_org_installs_report`
  WHERE DATE(install_date) BETWEEN '2026-06-01' AND '2026-07-31'
),

-- Spend: cost_table is pre-aggregated by adset and geo, so it is summed up to campaign-day level
cost_agg AS (
  SELECT
    CAST(date AS DATE) AS report_date,
    app_id, media_source, campaign_id,
    ANY_VALUE(campaign) AS campaign_name,
    SUM(cost_usd) AS cost_usd,
    SUM(impressions) AS impressions,
    SUM(clicks) AS clicks,
    TRUE AS cost_data_available
  FROM `your_project.app_dataset.cost_table`
  WHERE CAST(date AS DATE) BETWEEN '2026-06-01' AND '2026-07-31'
  GROUP BY report_date, app_id, media_source, campaign_id
),

-- Installs: one row = one install event; missing campaign_id is kept as -1 (Unattributed)
installs_agg AS (
  SELECT
    DATE(install_date) AS report_date,
    app_id, media_source,
    COALESCE(campaign_id, -1) AS campaign_id,
    COALESCE(ANY_VALUE(campaign_name), 'Unattributed / No Campaign') AS campaign_name,
    COUNT(*) AS installs
  FROM `your_project.app_dataset.non_org_installs_report`
  WHERE DATE(install_date) BETWEEN '2026-06-01' AND '2026-07-31'
  GROUP BY report_date, app_id, media_source, COALESCE(campaign_id, -1)
),

-- In-app ad revenue over the full observation period (no window), attributed to install date
ad_revenue_agg AS (
  SELECT
    DATE(install_date) AS report_date, app_id, media_source,
    COALESCE(campaign_id, -1) AS campaign_id,
    SUM(event_revenue_usd) AS ad_revenue_usd
  FROM `your_project.app_dataset.ad_revenue_raw`
  WHERE DATE(install_date) BETWEEN '2026-06-01' AND '2026-07-31'
  GROUP BY report_date, app_id, media_source, COALESCE(campaign_id, -1)
),

-- In-app purchases / subscriptions; refunds are already negative in the source
iap_revenue_agg AS (
  SELECT
    DATE(install_date) AS report_date, app_id, media_source,
    COALESCE(campaign_id, -1) AS campaign_id,
    SUM(event_revenue_usd) AS iap_revenue_usd
  FROM `your_project.app_dataset.in_app_events_report`
  WHERE DATE(install_date) BETWEEN '2026-06-01' AND '2026-07-31'
  GROUP BY report_date, app_id, media_source, COALESCE(campaign_id, -1)
),

-- Revenue ONLY within the first 7 days after install (install day = day 0)
ad_revenue_d7_agg AS (
  SELECT
    DATE(install_date) AS report_date, app_id, media_source,
    COALESCE(campaign_id, -1) AS campaign_id,
    SUM(event_revenue_usd) AS ad_revenue_usd_d7
  FROM `your_project.app_dataset.ad_revenue_raw`
  WHERE DATE(install_date) BETWEEN '2026-06-01' AND '2026-07-31'
    AND DATE_DIFF(DATE(event_date), DATE(install_date), DAY) BETWEEN 0 AND 6
  GROUP BY report_date, app_id, media_source, COALESCE(campaign_id, -1)
),

iap_revenue_d7_agg AS (
  SELECT
    DATE(install_date) AS report_date, app_id, media_source,
    COALESCE(campaign_id, -1) AS campaign_id,
    SUM(event_revenue_usd) AS iap_revenue_usd_d7
  FROM `your_project.app_dataset.in_app_events_report`
  WHERE DATE(install_date) BETWEEN '2026-06-01' AND '2026-07-31'
    AND DATE_DIFF(DATE(event_date), DATE(install_date), DAY) BETWEEN 0 AND 6
  GROUP BY report_date, app_id, media_source, COALESCE(campaign_id, -1)
),

-- Revenue ONLY within the first 30 days after install
ad_revenue_d30_agg AS (
  SELECT
    DATE(install_date) AS report_date, app_id, media_source,
    COALESCE(campaign_id, -1) AS campaign_id,
    SUM(event_revenue_usd) AS ad_revenue_usd_d30
  FROM `your_project.app_dataset.ad_revenue_raw`
  WHERE DATE(install_date) BETWEEN '2026-06-01' AND '2026-07-31'
    AND DATE_DIFF(DATE(event_date), DATE(install_date), DAY) BETWEEN 0 AND 29
  GROUP BY report_date, app_id, media_source, COALESCE(campaign_id, -1)
),

iap_revenue_d30_agg AS (
  SELECT
    DATE(install_date) AS report_date, app_id, media_source,
    COALESCE(campaign_id, -1) AS campaign_id,
    SUM(event_revenue_usd) AS iap_revenue_usd_d30
  FROM `your_project.app_dataset.in_app_events_report`
  WHERE DATE(install_date) BETWEEN '2026-06-01' AND '2026-07-31'
    AND DATE_DIFF(DATE(event_date), DATE(install_date), DAY) BETWEEN 0 AND 29
  GROUP BY report_date, app_id, media_source, COALESCE(campaign_id, -1)
),

-- Full outer joins keep days with spend but no installs/revenue, and vice versa
base AS (
  SELECT
    report_date, app_id, media_source, campaign_id,
    COALESCE(c.campaign_name, i.campaign_name, 'Unattributed / No Campaign') AS campaign_name,
    COALESCE(c.cost_usd, 0) AS cost_usd,
    COALESCE(c.impressions, 0) AS impressions,
    COALESCE(c.clicks, 0) AS clicks,
    COALESCE(i.installs, 0) AS installs,
    COALESCE(ar.ad_revenue_usd, 0) AS ad_revenue_usd,
    COALESCE(iap.iap_revenue_usd, 0) AS iap_revenue_usd,
    COALESCE(ar.ad_revenue_usd, 0) + COALESCE(iap.iap_revenue_usd, 0) AS total_revenue_usd,
    SAFE_DIVIDE(
      COALESCE(ar.ad_revenue_usd, 0) + COALESCE(iap.iap_revenue_usd, 0),
      NULLIF(c.cost_usd, 0)
    ) AS roas,
    COALESCE(c.cost_data_available, FALSE) AS cost_data_available
  FROM cost_agg c
  FULL OUTER JOIN installs_agg i USING (report_date, app_id, media_source, campaign_id)
  FULL OUTER JOIN ad_revenue_agg ar USING (report_date, app_id, media_source, campaign_id)
  FULL OUTER JOIN iap_revenue_agg iap USING (report_date, app_id, media_source, campaign_id)
)

SELECT
  b.*,

  COALESCE(ar7.ad_revenue_usd_d7, 0) + COALESCE(iap7.iap_revenue_usd_d7, 0) AS total_revenue_usd_d7,
  SAFE_DIVIDE(
    COALESCE(ar7.ad_revenue_usd_d7, 0) + COALESCE(iap7.iap_revenue_usd_d7, 0),
    NULLIF(b.cost_usd, 0)
  ) AS roas_d7,
  (b.report_date <= DATE_SUB(pb.max_install_date, INTERVAL 7 DAY)) AS cohort_mature_d7,

  COALESCE(ar30.ad_revenue_usd_d30, 0) + COALESCE(iap30.iap_revenue_usd_d30, 0) AS total_revenue_usd_d30,
  SAFE_DIVIDE(
    COALESCE(ar30.ad_revenue_usd_d30, 0) + COALESCE(iap30.iap_revenue_usd_d30, 0),
    NULLIF(b.cost_usd, 0)
  ) AS roas_d30,
  (b.report_date <= DATE_SUB(pb.max_install_date, INTERVAL 30 DAY)) AS cohort_mature_d30

FROM base b
CROSS JOIN period_bounds pb
LEFT JOIN ad_revenue_d7_agg ar7 USING (report_date, app_id, media_source, campaign_id)
LEFT JOIN iap_revenue_d7_agg iap7 USING (report_date, app_id, media_source, campaign_id)
LEFT JOIN ad_revenue_d30_agg ar30 USING (report_date, app_id, media_source, campaign_id)
LEFT JOIN iap_revenue_d30_agg iap30 USING (report_date, app_id, media_source, campaign_id);