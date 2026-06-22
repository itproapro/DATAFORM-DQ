--query_codigo_switch_ZZSUSTITUTO

-- DECLARO VARIABLES
DECLARE v_rule_id INT64 ;  -- ID de la regla
DECLARE v_query STRING; -- Consulta de validación, aquí va la lógica de la regla
DECLARE v_total INT64; -- Total de valores
DECLARE v_failed INT64; -- Valores que no cumplen con la regla
DECLARE v_passed FLOAT64; --% calculado entre valores totales y los que no cumplen la regla
DECLARE v_status STRING; --Status del resultado
DECLARE v_details STRING; --Detalles de la ejecución
DECLARE file_name STRING; --Nombre del archivo al bucket


-- DEFINIR ID RULE
SET v_rule_id = 16;

-- DEFINIR LA REGLA ASIGNADA A v_query: Código switch debe tener misma temperatura que al que sustituye, debe ser material del mismo código agrupador y debe tener código agrupador.


SET v_query = '''
    WITH base AS (
  SELECT
    RIGHT(LPAD(CAST(MATNR AS STRING),18,'0'),5) AS MATNR,
    RIGHT(LPAD(CAST(ZZSUSTITUTO AS STRING),18,'0'),5) AS ZZSUSTITUTO,
    BISMT,
  FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr`
),
validaciones AS (
  SELECT
    b1.MATNR,
    b1.BISMT,
    b1.ZZSUSTITUTO,
    b2.MATNR AS MATNR_SUSTITUTO,
    b2.BISMT AS BISMT_SUSTITUTO,
    SUBSTR(b1.MATNR,1,1) AS d_matnr,
    SUBSTR(b1.ZZSUSTITUTO,1,1) AS d_sustituto
  FROM base b1
  LEFT JOIN base b2
    ON b1.ZZSUSTITUTO = b2.MATNR
  WHERE b1.ZZSUSTITUTO IS NOT NULL AND b1.ZZSUSTITUTO != ''
)
SELECT 
  COUNT(*) AS total_errores 
FROM validaciones
  WHERE
    SUBSTR(MATNR,1,1) != SUBSTR(ZZSUSTITUTO,1,1)
    OR
    BISMT IS NULL OR BISMT = ''
    OR
    MATNR_SUSTITUTO IS NULL
    OR
    BISMT != BISMT_SUSTITUTO
    ;
''';



-- CALCULAR TOTAL DE REGISTROS E INCUMPLIMIENTOS
-- Calculo los valores totales
SET v_total = (SELECT
    COUNT(MATNR)
  FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr`  
WHERE 
( MTART IN ('ZMER','ZSEC','ZFRE')));
-- Calculo los valores que no cumplen la condición y los asigno a v_failed
EXECUTE IMMEDIATE v_query INTO v_failed;

IF v_failed IS NULL THEN
  SET v_failed = 0;
END IF;

-- CALCULAR PORCENTAJE COMPLETITUD
SET v_passed = ROUND(COALESCE((1 - SAFE_DIVIDE(v_failed, v_total))*100,100),2);

-- ESTABLECER STATUS: de acuerdo a lo que establescamos, valores críticos tienen que ser 100%
SET v_status = CASE
    WHEN v_passed > 99 or v_passed is null THEN 'PASSED'
    WHEN v_passed < 99 THEN 'FAILED'
    ELSE 'ERROR'
END;

-- DETALLES (opcional), aqui pongamos lo que vemaos que aporta
SET v_details = CONCAT('Total: ', v_total, ', Failed: ', v_failed, ' Validación código switch');

-- INSERTAR RESULTADO EN LA TABLA
INSERT INTO cf-esproapro-bic-pro-ou.SH_REP.FACT_DQ_RESULTS (
    RESULT_ID,
    RULE_ID,
    EXECUTION_TIME,
    TOTAL_RECORDS,
    FAILED_RECORDS,
    PASSED_PERCENTAGE,
    STATUS,
    DETAILS
)
VALUES (
    GENERATE_UUID(), --creo ID aleatorio para cada ejecución
    v_rule_id,
    CURRENT_TIMESTAMP(),
    v_total,
    v_failed,
    v_passed,
    v_status,
    v_details
);


IF v_passed != 100 THEN
SET file_name = CONCAT(
  'gs://maestromateriales-dataquality-pap/REGLA_DQ_16_MARA_',
  FORMAT_TIMESTAMP('%Y%m%d_%H%M%S', CURRENT_TIMESTAMP()),
  '_*.csv'
);

EXECUTE IMMEDIATE FORMAT("""
  EXPORT DATA OPTIONS (
    uri = '%s',
    format = 'CSV',
    header = true,
    field_delimiter = ';',
    overwrite = true
  )
  AS
    WITH base AS (
  SELECT
    RIGHT(LPAD(CAST(MATNR AS STRING),18,'0'),5) AS MATNR,
    RIGHT(LPAD(CAST(ZZSUSTITUTO AS STRING),18,'0'),5) AS ZZSUSTITUTO,
    BISMT,
  FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr`
),
validaciones AS (
  SELECT
    b1.MATNR,
    b1.BISMT,
    b1.ZZSUSTITUTO,
    b2.MATNR AS MATNR_SUSTITUTO,
    b2.BISMT AS BISMT_SUSTITUTO,
    SUBSTR(b1.MATNR,1,1) AS d_matnr,
    SUBSTR(b1.ZZSUSTITUTO,1,1) AS d_sustituto
  FROM base b1
  LEFT JOIN base b2
    ON b1.ZZSUSTITUTO = b2.MATNR
  WHERE b1.ZZSUSTITUTO IS NOT NULL AND b1.ZZSUSTITUTO != ''
)
SELECT 
  MATNR,
  BISMT,
  ZZSUSTITUTO,
  BISMT_SUSTITUTO,
  CASE
    WHEN SUBSTR(MATNR,1,1) != SUBSTR(ZZSUSTITUTO,1,1) THEN 'error_temperatura'
    WHEN BISMT IS NULL OR BISMT = '' THEN 'error_sin_codigo_agrupador'
    WHEN MATNR_SUSTITUTO IS NULL THEN 'error_sustituto_no_existe'
    WHEN BISMT != BISMT_SUSTITUTO THEN 'error_bismt_distinto'
  END AS tipo_error
FROM validaciones
WHERE
  SUBSTR(MATNR,1,1) != SUBSTR(ZZSUSTITUTO,1,1) OR BISMT IS NULL OR BISMT = '' OR MATNR_SUSTITUTO IS NULL OR BISMT != BISMT_SUSTITUTO
ORDER BY MATNR;
""", file_name);

END IF;