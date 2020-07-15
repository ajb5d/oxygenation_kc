WITH

mortality_type AS (
SELECT
  icu.icustay_id AS icustay_id,
  CASE WHEN admissions.deathtime BETWEEN admissions.admittime and admissions.dischtime
  THEN 1 
  ELSE 0
  END AS mortality_in_Hospt, 
  CASE WHEN admissions.deathtime BETWEEN icu.intime and icu.outtime
  THEN 1
  ELSE 0
  END AS mortality_in_ICU,
  admissions.deathtime as deathtime, 
  icu.intime as ICU_intime,
  admissions.ethnicity
FROM `physionet-data.mimiciii_clinical.icustays` AS icu
INNER JOIN `physionet-data.mimiciii_clinical.admissions` AS admissions
  ON icu.hadm_id = admissions.hadm_id),


oxygen_therapy AS (
SELECT * FROM `mimic_oxygen_therapy`
)


-- Aggregate `oxygen_therapy` per ICU stay.
, o_t AS (
  SELECT
    icustay_id
    , SUM(vent_duration) AS vent_duration
    , MAX(oxygen_therapy_type) AS oxygen_therapy_type
    , MAX(supp_oxygen) AS supp_oxygen
  FROM oxygen_therapy
  GROUP BY icustay_id
)


-- Extract the SpO2 measurements that happen during oxygen therapy.
, ce AS (
  SELECT DISTINCT 
    chart.icustay_id
    , chart.valuenum as spO2_Value
    , chart.charttime
  FROM `physionet-data.mimiciii_clinical.chartevents` AS chart
    INNER JOIN oxygen_therapy ON chart.icustay_id = oxygen_therapy.icustay_id
      -- We are only interested in measurements during oxygen therapy sessions.
      AND oxygen_therapy.vent_start <= chart.charttime
      AND oxygen_therapy.vent_end >= chart.charttime
  WHERE chart.itemid in (220277, 646) 
    AND chart.valuenum IS NOT NULL
    -- exclude rows marked as error
    AND (chart.error <> 1 OR chart.error IS NULL) --chart.error IS DISTINCT FROM 1
    -- We remove oxygen measurements that are outside of the range [10, 100]
    AND chart.valuenum >= 10
    AND chart.valuenum <= 100
)


-- Computing summaries of the blood oxygen saturation (SpO2)
, SpO2 AS (
  -- Edited from https://github.com/cosgriffc/hyperoxia-sepsis
  SELECT DISTINCT
      ce.icustay_id
      -- We currently ignore the time aspect of the measurements.
      -- However, one ideally should take into account that
      -- certain measurements are less spread out than others.
    , COUNT(ce.spO2_Value) OVER(PARTITION BY ce.icustay_id) AS nOxy
    , PERCENTILE_CONT(ce.spO2_Value, 0.5) OVER(PARTITION BY ce.icustay_id) AS median
    , AVG(CAST(ce.spO2_Value < 94 AS INT64)) OVER(PARTITION BY ce.icustay_id) AS propBelow
    , AVG(CAST(ce.spO2_Value > 98 AS INT64)) OVER(PARTITION BY ce.icustay_id) AS propAbove
  FROM ce
)


-- Same as above but now only considering SpO2 measurements during the first
-- 24/48/72 hours
, SpO2_24 AS (
  -- Edited from https://github.com/cosgriffc/hyperoxia-sepsis
  SELECT DISTINCT
      ce.icustay_id
      -- We currently ignore the time aspect of the measurements.
      -- However, one ideally should take into account that
      -- certain measurements are less spread out than others.
    , COUNT(ce.spO2_Value) OVER(PARTITION BY ce.icustay_id) AS nOxy_24
    , PERCENTILE_CONT(ce.spO2_Value, 0.5) OVER(PARTITION BY ce.icustay_id) AS median_24
    , AVG(CAST(ce.spO2_Value >= 94 AND ce.spO2_Value <= 98 AS INT64)) OVER(PARTITION BY ce.icustay_id) AS prop_24
  FROM ce
    INNER JOIN oxygen_therapy ON ce.icustay_id = oxygen_therapy.icustay_id
  -- We are only interested in measurements during the first 24 hours of the oxygen therapy session.
  WHERE DATETIME_DIFF(ce.charttime, oxygen_therapy.vent_start_first, HOUR) <= 24
)


, SpO2_48 AS (
  -- Edited from https://github.com/cosgriffc/hyperoxia-sepsis
  SELECT DISTINCT
      ce.icustay_id
      -- We currently ignore the time aspect of the measurements.
      -- However, one ideally should take into account that
      -- certain measurements are less spread out than others.
    , COUNT(ce.spO2_Value) OVER(PARTITION BY ce.icustay_id) AS nOxy_48
    , PERCENTILE_CONT(ce.spO2_Value, 0.5) OVER(PARTITION BY ce.icustay_id) AS median_48
    , AVG(CAST(ce.spO2_Value >= 94 AND ce.spO2_Value <= 98 AS INT64)) OVER(PARTITION BY ce.icustay_id) AS prop_48
  FROM ce
    INNER JOIN oxygen_therapy ON ce.icustay_id = oxygen_therapy.icustay_id
  -- We are only interested in measurements during the first 48 hours of the oxygen therapy session.
  WHERE DATETIME_DIFF(ce.charttime, oxygen_therapy.vent_start_first, HOUR) <= 48
)


, SpO2_72 AS (
  -- Edited from https://github.com/cosgriffc/hyperoxia-sepsis
  SELECT DISTINCT
      ce.icustay_id
      -- We currently ignore the time aspect of the measurements.
      -- However, one ideally should take into account that
      -- certain measurements are less spread out than others.
    , COUNT(ce.spO2_Value) OVER(PARTITION BY ce.icustay_id) AS nOxy_72
    , PERCENTILE_CONT(ce.spO2_Value, 0.5) OVER(PARTITION BY ce.icustay_id) AS median_72
    , AVG(CAST(ce.spO2_Value >= 94 AND ce.spO2_Value <= 98 AS INT64)) OVER(PARTITION BY ce.icustay_id) AS prop_72
  FROM ce
    INNER JOIN oxygen_therapy ON ce.icustay_id = oxygen_therapy.icustay_id
  -- We are only interested in measurements during the first 72 hours of the oxygen therapy session.
  WHERE DATETIME_DIFF(ce.charttime, oxygen_therapy.vent_start_first, HOUR) <= 72
)



-- Edited from https://github.com/MIT-LCP/mimic-code/blob/master/concepts/demographics/HeightWeightQuery.sql
-- This query gets the first weight and height
-- for a single ICUSTAY_ID. It extracts data from the CHARTEVENTS table.
, heightweight AS (
WITH FirstVRawData AS
  (SELECT c.charttime,
    c.itemid,c.subject_id,c.icustay_id,
    CASE
      WHEN c.itemid IN (762, 763, 3723, 3580, 3581, 3582, 226512)
        THEN 'WEIGHT'
      WHEN c.itemid IN (920, 1394, 4187, 3486, 3485, 4188, 226707)
        THEN 'HEIGHT'
    END AS parameter,
    -- Ensure that all weights are in kg and heights are in centimeters
    CASE
      WHEN c.itemid   IN (3581, 226531)
        THEN c.valuenum * 0.45359237
      WHEN c.itemid   IN (3582)
        THEN c.valuenum * 0.0283495231
      WHEN c.itemid   IN (920, 1394, 4187, 3486, 226707)
        THEN c.valuenum * 2.54
      ELSE c.valuenum
    END AS valuenum
  FROM `physionet-data.mimiciii_clinical.chartevents` c
  WHERE c.valuenum   IS NOT NULL
  -- exclude rows marked as error
  AND (c.error <> 1 OR c.error IS NULL)  --c.error IS DISTINCT FROM 1
  AND ( ( c.itemid  IN (762, 763, 3723, 3580, -- Weight Kg
    3581,                                     -- Weight lb
    3582,                                     -- Weight oz
    920, 1394, 4187, 3486,                    -- Height inches
    3485, 4188                                -- Height cm
    -- Metavision
    , 226707 -- Height (measured in inches)
    , 226512 -- Admission Weight (Kg)

    -- note we intentionally ignore the below ITEMIDs in metavision
    -- these are duplicate data in a different unit
    -- , 226531 -- Admission Weight (lbs.)
    -- , 226730 -- Height (cm)
    )
  AND c.valuenum <> 0 )
    ) )
  --)

  --select * from FirstVRawData
, SingleParameters AS (
  SELECT DISTINCT subject_id,
         icustay_id,
         parameter,
         first_value(valuenum) over
            (partition BY subject_id, icustay_id, parameter
             order by charttime ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
             AS first_valuenum
    FROM FirstVRawData

--   ORDER BY subject_id,
--            icustay_id,
--            parameter
  )
--select * from SingleParameters
, PivotParameters AS (SELECT subject_id, icustay_id,
    MAX(case when parameter = 'HEIGHT' then first_valuenum else NULL end) AS height_first,
    MAX(case when parameter = 'WEIGHT' then first_valuenum else NULL end) AS weight_first
  FROM SingleParameters
  GROUP BY subject_id,
    icustay_id
  )
--select * from PivotParameters
SELECT f.icustay_id,
  f.subject_id,
  ROUND( cast(f.height_first as numeric), 2) AS height_first,
  ROUND(cast(f.weight_first as numeric), 2) AS weight_first

FROM PivotParameters f),




-- `patients` on our Google cloud setup has each ICU stay duplicated 7 times.
-- We get rid of these duplicates.
pat AS (
	SELECT DISTINCT * FROM `physionet-data.mimiciii_clinical.patients`
),


-- `icustays` has similar duplication, but the duplicates sometimes differ in the recorded careunit.
-- Note that no such duplicate care units are recorded in ICUSTAYS.csv available from Physionet.
-- We arbitrarily pick one care unit: This only affects 0.9% of ICU stays.
icu AS (SELECT *
FROM   (SELECT *,
               Row_number() OVER(PARTITION BY icustay_id ORDER BY first_careunit) rn
        FROM   `physionet-data.mimiciii_clinical.icustays`)
WHERE  rn = 1)



SELECT DISTINCT
icu.hadm_id AS HADM_id,       
icu.icustay_id AS icustay_id,       
icu.subject_id AS patient_ID,
pat.gender AS gender,
DATE_DIFF(DATE(icu.intime), DATE(pat.dob), YEAR) AS age,
DATETIME_DIFF(icu.outtime, icu.intime, HOUR) / 24 AS icu_length_of_stay,
mortality_type.* EXCEPT(icustay_id),
icd.* EXCEPT(hadm_id),
apsiii.apsiii,
elix.congestive_heart_failure, 
elix.hypertension, 
elix.chronic_pulmonary, 
elix.diabetes_uncomplicated, 
elix.diabetes_complicated, 
elix.renal_failure, 
elix.liver_disease, 
elix.lymphoma, 
elix.solid_tumor, 
elix.metastatic_cancer,
angus.angus,
sofa.sofa AS sofatotal,
mech_vent.tidal_high_count2 as tidal_count_percentage,
SAFE_CAST(heightweight.height_first AS FLOAT64) as height,
SAFE_CAST(heightweight.weight_first AS FLOAT64) as weight,
icu.first_careunit as unittype,
-- edited from https://github.com/MIT-LCP/mimic-code/blob/master/concepts/demographics/icustay-detail.sql:
DENSE_RANK() OVER (PARTITION BY icu.subject_id ORDER BY icu.intime) = 1 AS first_stay
, o_t.* EXCEPT(icustay_id)
, SpO2.* EXCEPT(icustay_id)
, SpO2_24.* EXCEPT(icustay_id)
, SpO2_48.* EXCEPT(icustay_id)
, SpO2_72.* EXCEPT(icustay_id)
FROM icu
LEFT JOIN pat
  ON icu.subject_id = pat.subject_id
LEFT JOIN mortality_type
  ON icu.icustay_id = mortality_type.icustay_id
LEFT JOIN `icd_codes` AS icd 
  ON icu.hadm_id = icd.hadm_id
LEFT JOIN `physionet-data.mimiciii_derived.elixhauser_quan` AS elix
  ON icu.hadm_id = elix.hadm_id
LEFT JOIN `physionet-data.mimiciii_derived.angus_sepsis` AS angus
 ON icu.hadm_id = angus.hadm_id
LEFT JOIN `physionet-data.mimiciii_derived.apsiii` AS apsiii
  ON icu.icustay_id = apsiii.icustay_id
LEFT JOIN `physionet-data.mimiciii_derived.sofa` sofa 
  ON icu.icustay_id = SOFA.icustay_id
LEFT JOIN `mechanical_ventilative_volume` mech_vent 
  ON icu.icustay_id = mech_vent.icustay_id
LEFT JOIN heightweight
  ON icu.icustay_id = heightweight.icustay_id
LEFT JOIN o_t
  ON icu.icustay_id = o_t.icustay_id
LEFT JOIN SpO2
  ON icu.icustay_id = SpO2.icustay_id
LEFT JOIN SpO2_24
  ON icu.icustay_id = SpO2_24.icustay_id
LEFT JOIN SpO2_48
  ON icu.icustay_id = SpO2_48.icustay_id
LEFT JOIN SpO2_72
  ON icu.icustay_id = SpO2_72.icustay_id