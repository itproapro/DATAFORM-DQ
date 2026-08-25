--query_aprovisionamiento_especial_SOBSL

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
SET v_rule_id = 57;

-- DEFINIR LA REGLA ASIGNADA A v_query: APROVISIONAMIENTO ESPECIAL--> verificamos que si está centralizado en:
--Madrid (SOBSL = 42 ==> centro != 6442)
--Madrid (SOBSL = 44 ==> centro != 6342)
--Sevilla (SOBSL = Z4 ==> centro != 4400)

SET v_query = '''
        WITH base AS (
            SELECT
              RIGHT(LPAD(CAST(m.MATNR AS STRING),18,'0'),5) AS MATNR,
              MMSTA,
              MTART,
              SOBSL,
              WERKS,
              FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr` AS m
              JOIN `cf-esproapro-bic-pro-ou.SH_STG.bqt_mat_plant_attr` AS c 
              ON m.MATNR = c.MATNR
          ),
          evaluacion AS (
            SELECT
                MATNR,
                MMSTA,
                SOBSL,
                MTART,
                WERKS,
                CASE
                  WHEN WERKS IN ('6443','6444','6445','6343','6344','6345','6243','6244','6245') AND SOBSL IS NOT NULL THEN 'INCORRECTO'
                  WHEN SOBSL = '42' AND WERKS != '6442' THEN 'OK'
                  WHEN SOBSL = 'Z4' AND WERKS != '4400' THEN 'OK'
                  WHEN SOBSL = '44' AND WERKS != '6342' THEN 'OK'
                  WHEN SOBSL = '43' AND WERKS != '4300' THEN 'OK'
                  ELSE 'INCORRECTO'
                END AS resultado
            FROM base
          )
          SELECT
            COUNTIF(resultado != 'OK' OR resultado = 'INCORRECTOS') AS incorrectos,
          FROM evaluacion
          WHERE MTART IN ('ZMER','ZFRE','ZSEC') AND SOBSL IS NOT NULL AND resultado = 'INCORRECTO';
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
SET v_details = CONCAT('Total: ', v_total, ', Failed: ', v_failed, ' Coherencia entre el centro y el valor de aprovisionamiento especial (centralizado).');

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
  'gs://maestromateriales-dataquality-pap/REGLA_DQ_57_MARA_',
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
        SOBSL,
        WERKS,
        FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr` AS m
        JOIN `cf-esproapro-bic-pro-ou.SH_STG.bqt_mat_plant_attr` AS c 
        ON m.MATNR = c.MATNR
    ),
    evaluacion AS (
      SELECT
          MATNR,
          MMSTA,
          SOBSL,
          MTART,
          WERKS,
          CASE
            WHEN WERKS IN ('6443','6444','6445','6343','6344','6345','6243','6244','6245') AND SOBSL IS NOT NULL THEN 'INCORRECTO'
            WHEN SOBSL = '42' AND WERKS != '6442' THEN 'OK'
            WHEN SOBSL = 'Z4' AND WERKS != '4400' THEN 'OK'
            WHEN SOBSL = '44' AND WERKS != '6342' THEN 'OK'
            WHEN SOBSL = '43' AND WERKS != '4300' THEN 'OK'
            ELSE 'INCORRECTO'
          END AS resultado
      FROM base
    )
    SELECT
      *
    FROM evaluacion
    WHERE MTART IN ('ZMER','ZFRE','ZSEC')  AND SOBSL IS NOT NULL AND resultado = 'INCORRECTO';
""", file_name);

END IF;