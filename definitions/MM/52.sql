--query_caract.planificacion_DISMM

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
SET v_rule_id = 52;

-- DEFINIR LA REGLA ASIGNADA A v_query: CARAC. PLANIFICACION --> verificamos que el campo cumpla la siguiente relación:
-- los centros '6443','6444','6445','6446','6447','6343','6344','6345','6346','6347' tienen  planificación 'ND'
SET v_query = '''
    WITH base AS (
      SELECT
        RIGHT(LPAD(CAST(m.MATNR AS STRING),18,'0'),5) AS MATNR,
        MMSTA,
        MTART,
        DISMM,
        WERKS,
        MSTAV
        FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr` AS m
        JOIN `cf-esproapro-bic-pro-ou.SH_STG.bqt_mat_plant_attr` AS c 
        ON m.MATNR = c.MATNR
    ),
    evaluacion AS (
      SELECT
          MATNR,
          MMSTA,
          DISMM,
          MTART,
          WERKS,
          MSTAV,
          CASE
            WHEN WERKS IN ('6443','6444','6445','6446','6447') AND DISMM = 'ND' THEN 'OK'
            WHEN WERKS IN ('6343','6344','6345','6346','6347') AND DISMM = 'ND' THEN 'OK'
            WHEN WERKS IN ('6440','6441','6442','4400','4300') AND DISMM IN ('ND','PD') THEN 'OK'
            WHEN WERKS IN ('6340','6341','6342','4400','4300') AND DISMM IN ('ND','PD') THEN 'OK'
            WHEN WERKS IN ('6240','6241','6242','4400','4300') AND DISMM IN ('ND','PD') THEN 'OK'
            ELSE 'REVISAR'
          END AS control_relacion
      FROM base
    )
    SELECT
      COUNTIF(control_relacion != 'OK' OR control_relacion = 'REVISAR') AS incorrectos,
    FROM evaluacion
    WHERE MTART IN ('ZMER','ZFRE','ZSEC');
''';



-- CALCULAR TOTAL DE REGISTROS E INCUMPLIMIENTOS
-- Calculo los valores totales
SET v_total = (SELECT
  COUNT(*)
  FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr` AS m
JOIN `cf-esproapro-bic-pro-ou.SH_STG.bqt_mat_plant_attr` AS c
ON m.MATNR = c.MATNR
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
    WHEN v_passed > 99 or v_passed is null THEN 'PASSED'
    WHEN v_passed < 99 THEN 'FAILED'
    ELSE 'ERROR'
END;

-- DETALLES (opcional), aqui pongamos lo que vemaos que aporta
SET v_details = CONCAT('Total: ', v_total, ', Failed: ', v_failed, ' Coherencia en el valor de planificación para los centros "virtuales".');

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
  'gs://maestromateriales-dataquality-pap/REGLA_DQ_52_MARA_',
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
        RIGHT(LPAD(CAST(m.MATNR AS STRING),18,'0'),5) AS MATNR,
        MMSTA,
        MTART,
        DISMM,
        WERKS,
        MSTAV
    FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr` AS m
    JOIN `cf-esproapro-bic-pro-ou.SH_STG.bqt_mat_plant_attr` AS c 
    ON m.MATNR = c.MATNR
    ),
    evaluacion AS (
    SELECT
        MATNR,
        MMSTA,
        DISMM,
        MTART,
        WERKS,
        MSTAV,
        CASE
            WHEN WERKS IN ('6443','6444','6445','6446','6447') AND DISMM = 'ND' THEN 'OK'
            WHEN WERKS IN ('6343','6344','6345','6346','6347') AND DISMM = 'ND' THEN 'OK'
            WHEN WERKS IN ('6440','6441','6442','4400','4300') AND DISMM IN ('ND','PD') THEN 'OK'
            WHEN WERKS IN ('6340','6341','6342','4400','4300') AND DISMM IN ('ND','PD') THEN 'OK'
            WHEN WERKS IN ('6240','6241','6242','4400','4300') AND DISMM IN ('ND','PD') THEN 'OK'
            ELSE 'REVISAR'
        END AS control_relacion
    FROM base
    )
    SELECT
        *
    FROM evaluacion
    WHERE MTART IN ('ZMER','ZFRE','ZSEC') AND (control_relacion IS NULL OR control_relacion != 'OK');
""", file_name);

END IF;