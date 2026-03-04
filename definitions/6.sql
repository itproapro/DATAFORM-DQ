--query_almacen_LGORT

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
SET v_rule_id = 6;

-- DEFINIR LA REGLA ASIGNADA A v_query: Asignación correcta de almacén
SET v_query = '''
   WITH joined AS (
  SELECT
    LPAD(CAST(m.MATNR AS STRING),18,'0') AS MATNR,
    MTART,
    SUBSTR(LPAD(CAST(m.MATNR AS STRING), 18,'0'),14,1) AS d5,
    TRIM(CAST(c.WERKS AS STRING)) AS WERKS_raw,-- normalizo el campo WERKS
    NULLIF(TRIM(CAST(c.LGPRO AS STRING)), '') AS LGPRO -- normalizo el campo LGPRO
  FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr` AS m
  JOIN `cf-esproapro-bic-pro-ou.SH_STG.bqt_mat_plant_attr` AS c ON m.MATNR = c.MATNR
),
validacion AS (
  SELECT
    MATNR,
    MTART,
    d5,
    WERKS_raw,
    SAFE_CAST(NULLIF(WERKS_raw, '') AS INT64) AS WERKS,-- estos es solo para poder evaluar rangos
    LGPRO
  FROM joined
),
map AS (
  SELECT
    MATNR,
    MTART,
    d5,
    WERKS,
    LGPRO,
    CASE
      --d5 = CONGELADOS
      WHEN d5='1' AND WERKS = 4400 THEN '6444'
      WHEN d5='1' AND WERKS = 4300 THEN '6443'
      WHEN d5='1' AND WERKS BETWEEN 6440 AND 6447 THEN CAST(WERKS AS STRING)

      --d5 = REFRIGERADOS
      WHEN d5='3' AND WERKS = 4400 THEN '6244'
      WHEN d5='3' AND WERKS BETWEEN 6240 AND 6247 THEN CAST(WERKS AS STRING)

        --d5 = SECOS
      WHEN d5='4' AND WERKS = 4400  THEN '6344'
      WHEN d5='4' AND WERKS = 4300  THEN '6343'
      WHEN d5='4' AND WERKS BETWEEN 6340 AND 6347 THEN CAST(WERKS AS STRING)
      WHEN d5='4' AND WERKS = 6445 THEN '6445'

      ELSE NULL
    END AS LGPRO_esperado
  FROM validacion
),
eval AS (
SELECT 
  MATNR,
  MTART,
  d5,
  CAST(WERKS AS STRING) AS WERKS,
  LGPRO,
  LGPRO_esperado,
  CASE
    WHEN d5 NOT IN ('1','3','4') THEN 'FUERA_DE_REGLA: aplica solo a d5= 1, 3 o 4'
    WHEN LGPRO IS NULL THEN 'INCORRECTO: LGPRO nulo'
    WHEN LGPRO_esperado IS NULL THEN 'FUERA_DE_REGLA: combinación no contemplada d5/WERKS'
    WHEN LGPRO != LGPRO_esperado THEN 'INCORRECTO: LGPRO no cumple con la regla de validación'
  END AS motivo
FROM map
)
SELECT
  COUNT(*) AS incorrectos FROM eval
  WHERE 
    MTART IN ('ZMER','ZSEC','ZFRE') AND
    d5 IN ('1','3','4')
    AND (
      LGPRO IS NULL OR LGPRO_esperado IS NULL OR LGPRO != LGPRO_esperado
    )
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
SET v_passed = ROUND(COALESCE(ROUND(1 - SAFE_DIVIDE(v_failed, v_total),3)*100,100),3);

-- ESTABLECER STATUS: de acuerdo a lo que establescamos, valores críticos tienen que ser 100%
SET v_status = CASE
    WHEN v_passed > 95 THEN 'PASSED'
    WHEN v_passed < 95 THEN 'FAILED'
    ELSE 'ERROR'
END;

-- DETALLES (opcional), aqui pongamos lo que vemaos que aporta
SET v_details = CONCAT('Total: ', v_total, ', Failed: ', v_failed, ' ALMACEN: relación vs centro');

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

-- ENVIO DE CAMPOS A REVISAR POR OWNER

IF v_status = 'FAILED' THEN
SET file_name = CONCAT(
  'gs://maestromateriales-dataquality-pap/REGLA_DQ_6_MARA_',
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
    WITH joined AS (
    SELECT
        LPAD(CAST(m.MATNR AS STRING),18,'0') AS MATNR,
        MTART,
        SUBSTR(LPAD(CAST(m.MATNR AS STRING), 18,'0'),14,1) AS d5,
        TRIM(CAST(c.WERKS AS STRING)) AS WERKS_raw,-- normalizo el campo WERKS
        NULLIF(TRIM(CAST(c.LGPRO AS STRING)), '') AS LGPRO -- normalizo el campo LGPRO
    FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr` AS m
    JOIN `cf-esproapro-bic-pro-ou.SH_STG.bqt_mat_plant_attr` AS c ON m.MATNR = c.MATNR
        ),
    validacion AS (
    SELECT
        MATNR,
        MTART,
        d5,
        WERKS_raw,
        SAFE_CAST(NULLIF(WERKS_raw, '') AS INT64) AS WERKS,-- estos es solo para poder evaluar rangos
        LGPRO
    FROM joined
    ),
    map AS (
    SELECT
        MATNR,
        MTART,
        d5,
        WERKS,
        LGPRO,
        CASE
        --d5 = CONGELADOS
        WHEN d5='1' AND WERKS = 4400 THEN '6444'
        WHEN d5='1' AND WERKS = 4300 THEN '6443'
        WHEN d5='1' AND WERKS BETWEEN 6440 AND 6447 THEN CAST(WERKS AS STRING)

        --d5 = REFRIGERADOS
        WHEN d5='3' AND WERKS = 4400 THEN '6244'
        WHEN d5='3' AND WERKS BETWEEN 6240 AND 6247 THEN CAST(WERKS AS STRING)

            --d5 = SECOS
        WHEN d5='4' AND WERKS = 4400  THEN '6344'
        WHEN d5='4' AND WERKS = 4300  THEN '6343'
        WHEN d5='4' AND WERKS BETWEEN 6340 AND 6347 THEN CAST(WERKS AS STRING)
        WHEN d5='4' AND WERKS = 6445 THEN '6445'

        ELSE NULL
        END AS LGPRO_esperado
    FROM validacion
    ),
    eval AS (
    SELECT 
    MATNR,
    MTART,
    d5,
    CAST(WERKS AS STRING) AS WERKS,
    LGPRO,
    LGPRO_esperado,
    CASE
        WHEN d5 NOT IN ('1','3','4') THEN 'FUERA_DE_REGLA: aplica solo a d5= 1, 3 o 4'
        WHEN LGPRO IS NULL THEN 'INCORRECTO: LGPRO nulo'
        WHEN LGPRO_esperado IS NULL THEN 'FUERA_DE_REGLA: combinación no contemplada d5/WERKS'
        WHEN LGPRO != LGPRO_esperado THEN 'INCORRECTO: LGPRO no cumple con la regla de validación'
    END AS motivo
    FROM map
    )
    SELECT
    COUNT(*) AS incorrectos FROM eval
    WHERE 
        MTART IN ('ZMER','ZSEC','ZFRE') AND
        d5 IN ('1','3','4')
        AND (
        LGPRO IS NULL OR LGPRO_esperado IS NULL OR LGPRO != LGPRO_esperado
        )
""", file_name);


END IF;