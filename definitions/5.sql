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
SET v_rule_id = 5;

-- DEFINIR LA REGLA ASIGNADA A v_query: Asignación correcta del centro según tipo de material
SET v_query = '''
  WITH joined AS (
  SELECT
    RIGHT(LPAD(CAST(m.MATNR AS STRING),18,'0'),5) AS MATNR,
    SUBSTR(LPAD(CAST(m.MATNR AS STRING), 18,'0'),14,1) AS d5,
    NULLIF(TRIM(CAST(c.WERKS AS STRING)), '') AS WERKS -- normalizo el campo WERKS
  FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr` AS m
  JOIN `cf-esproapro-bic-pro-ou.SH_STG.bqt_mat_plant_attr` AS c ON m.MATNR = c.MATNR
),
evaluacion AS (
  SELECT
    CASE
      WHEN d5 IN ('1','3') AND WERKS IN ('6440','6441','6442', '6443','6444','6445','6446','6447','6240','6241','6242', '6243','6244','6245','6246','6247','4400','4300') THEN 'OK'
      WHEN d5= '4' AND WERKS IN ('6340','6341','6342', '6343','6344','6345','6346','6347','4400','4300') THEN 'OK'
      WHEN d5 IN ('1','3') AND (WERKS IS NULL OR WERKS NOT IN ('6440','6441','6442', '6443','6444','6445','6446','6447','6240','6241','6242', '6243','6244','6245','6246','6247','4400','4300')) THEN 'INCORRECTO'
      WHEN d5= '4' AND (WERKS IS NULL OR WERKS NOT IN ('6340','6341','6342', '6343','6344','6345','6346','6347','4400','4300')) THEN 'INCORRECTO'
      ELSE 'fuera_de_regla'
    END AS estado
  FROM joined
)
-- % CALIDAD DEL DATO

SELECT
  COUNTIF(estado = 'INCORRECTO') AS incorrectos
FROM evaluacion;
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

select v_passed;
select v_failed;
select v_total;

-- ESTABLECER STATUS: de acuerdo a lo que establescamos, valores críticos tienen que ser 100%
SET v_status = CASE
    WHEN v_passed > 100  THEN 'PASSED'
    WHEN v_passed < 100 THEN 'FAILED'
    ELSE 'ERROR'
END;

-- DETALLES (opcional), aqui pongamos lo que vemaos que aporta
SET v_details = CONCAT('Total: ', v_total, ', Failed: ', v_failed, ' CENTRO: relación entre el dígito inicial del material y su centro');

-- INSERTAR RESULTADO EN LA TABLA
INSERT INTO 	cf-esproapro-bic-pro-ou.SH_REP.FACT_DQ_RESULTS (
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
  'gs://maestromateriales-dataquality-pap/REGLA_DQ_5_MARA_',
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
    RIGHT(LPAD(CAST(m.MATNR AS STRING),18,'0'),5) AS MATNR,
    SUBSTR(LPAD(CAST(m.MATNR AS STRING), 18,'0'),14,1) AS d5,
    NULLIF(TRIM(CAST(c.WERKS AS STRING)), '') AS WERKS -- normalizo el campo WERKS
  FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr` AS m
  JOIN `cf-esproapro-bic-pro-ou.SH_STG.bqt_mat_plant_attr` AS c ON m.MATNR = c.MATNR
  ),
  evaluacion AS (
    SELECT
      CASE
        WHEN d5 IN ('1','3') AND WERKS IN ('6440','6441','6442', '6443','6444','6445','6446','6447','6240','6241','6242', '6243','6244','6245','6246','6247','4400','4300') THEN 'OK'
        WHEN d5= '4' AND WERKS IN ('6340','6341','6342', '6343','6344','6345','6346','6347','4400','4300') THEN 'OK'
        WHEN d5 IN ('1','3') AND (WERKS IS NULL OR WERKS NOT IN ('6440','6441','6442', '6443','6444','6445','6446','6447','6240','6241','6242', '6243','6244','6245','6246','6247','4400','4300')) THEN 'INCORRECTO'
        WHEN d5= '4' AND (WERKS IS NULL OR WERKS NOT IN ('6340','6341','6342', '6343','6344','6345','6346','6347','4400','4300')) THEN 'INCORRECTO'
        ELSE 'fuera_de_regla'
      END AS estado,
      MATNR,
      d5,
      WERKS
    FROM joined
  )

  SELECT
    *
  FROM evaluacion
  where estado = 'INCORRECTO'
  order by MATNR;
""", file_name);


END IF;