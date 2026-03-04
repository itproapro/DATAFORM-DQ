--query_org_ventas_KOKRS

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
SET v_rule_id = 7;

-- DEFINIR LA REGLA ASIGNADA A v_query: Organización de ventas = ES14
SET v_query = '''
WITH base AS (
  SELECT
    m.MATNR,
    MTART,
    c.KOKRS,
    LEFT(RIGHT(CAST(m.MATNR AS STRING),5),1)AS d5
  FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr` AS m
  JOIN `cf-esproapro-bic-pro-ou.SH_STG.bqt_mat_plant_attr` AS c ON m.MATNR = c.MATNR
),
eval AS (
SELECT
  MATNR,
  MTART,
  KOKRS,
  d5,
  CASE
    WHEN d5 = '1' THEN 'ZMER'
    WHEN d5 = '3' THEN 'ZFRE'
    WHEN d5 = '4' THEN 'ZSEC'
    ELSE 'TIPO DESCONOCIDO'
  END AS valor_esperado
FROM base
)
SELECT 
  COUNT(*) AS incorrectos FROM eval
    WHERE
      d5 IN ('1','3','4') 
      AND (
        (d5 = '1' AND MTART = 'ZMER') OR
        (d5 = '3' AND MTART = 'ZFRE') OR
        (d5 = '4' AND MTART = 'ZSEC')
      ) AND KOKRS <> 'ES14';
''';



-- CALCULAR TOTAL DE REGISTROS E INCUMPLIMIENTOS
-- Calculo los valores totales
SET v_total = (SELECT
  COUNT(*) 
  FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr` AS m
  JOIN `cf-esproapro-bic-pro-ou.SH_STG.bqt_mat_plant_attr` AS c ON m.MATNR = c.MATNR
  WHERE MTART IN ('ZMER','ZSEC','ZFRE'));
-- Calculo los valores que no cumplen la condición y los asigno a v_failed
EXECUTE IMMEDIATE v_query INTO v_failed;

IF v_failed IS NULL THEN
  SET v_failed = 0;
END IF;

-- CALCULAR PORCENTAJE COMPLETITUD
SET v_passed = ROUND(COALESCE((1 - SAFE_DIVIDE(v_failed, v_total))*100,100),2);


-- ESTABLECER STATUS: de acuerdo a lo que establescamos, valores críticos tienen que ser 100%
SET v_status = CASE
    WHEN v_passed > 99.5  THEN 'PASSED'
    else 'FAILED'
END;

-- DETALLES (opcional), aqui pongamos lo que vemaos que aporta
SET v_details = CONCAT('Total: ', v_total, ', Failed: ', v_failed, ' Validación campo organización de ventas');

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


IF v_status = 'FAILED' THEN
SET file_name = CONCAT(
  'gs://maestromateriales-dataquality-pap/REGLA_DQ_7_MARA_',
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
    m.MATNR,
    MTART,
    c.KOKRS,
    LEFT(RIGHT(CAST(m.MATNR AS STRING),5),1)AS d5
  FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr` AS m
  JOIN `cf-esproapro-bic-pro-ou.SH_STG.bqt_mat_plant_attr` AS c ON m.MATNR = c.MATNR
),
eval AS (
SELECT
  MATNR,
  MTART,
  KOKRS,
  d5,
  CASE
    WHEN d5 = '1' THEN 'ZMER'
    WHEN d5 = '3' THEN 'ZFRE'
    WHEN d5 = '4' THEN 'ZSEC'
    ELSE 'TIPO DESCONOCIDO'
  END AS valor_esperado
FROM base
)
SELECT 
  *
    WHERE
      d5 IN ('1','3','4') 
      AND (
        (d5 = '1' AND MTART = 'ZMER') OR
        (d5 = '3' AND MTART = 'ZFRE') OR
        (d5 = '4' AND MTART = 'ZSEC')
      ) AND KOKRS <> 'ES14';
""", file_name);

END IF;