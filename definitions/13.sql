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
SET v_rule_id = 13;

-- DEFINIR LA REGLA ASIGNADA A v_query: -- UNIDAD BASE --> todo material debe tener una unidad de medida base ('ST', 'CS')
SET v_query = '''
WITH base AS (
  SELECT
    MATNR,
    MTART,
    MEINS
  FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr`
)
SELECT
  COUNT(*)
  FROM base
  WHERE
  MTART IN ('ZMER','ZFRE','ZSEC') 
  AND MEINS NOT IN ('ST','CS');
''';



-- CALCULAR TOTAL DE REGISTROS E INCUMPLIMIENTOS
-- Calculo los valores totales
SET v_total = (SELECT COUNT(*) FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr`
WHERE MTART IN ('ZMER','ZFRE', 'ZSEC'));
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
SET v_details = CONCAT('Total: ', v_total, ', Failed: ', v_failed, ' UMB: verificamos relación entre dígito de inicio del material y unidad de medida base UN o CJ');

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
  'gs://maestromateriales-dataquality-pap/REGLA_DQ_13_MARA_',
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
    MATNR,
    MTART,
    MEINS
  FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr`
  )
  SELECT
    MATNR,
    MTART,
    MEINS
    FROM base
    WHERE
    MTART IN ('ZMER','ZFRE','ZSEC') 
    AND MEINS NOT IN ('ST','CS');
    ORDER BY MATNR DESC;
""", file_name);

END IF;