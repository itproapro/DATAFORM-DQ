--query_codigo_agrupador_BISMT

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
SET v_rule_id = 15;

-- DEFINIR LA REGLA ASIGNADA A v_query: -- Código Agrupador debe tener una longitud de 6 caractéres y al menos un material agrupado (MATNR) y no debe ser nulo.
SET v_query = '''
WITH base AS (
  SELECT
    RIGHT(LPAD(CAST(MATNR AS STRING),18,'0'),5) AS MATNR,
    BISMT,
    RIGHT(LPAD(CAST(ZZSUSTITUTO AS STRING),18,'0'),5) AS ZZSUSTITUTO,
  FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr`
  WHERE MTART IN ('ZMER','ZSEC','ZFRE')
),

grupos AS (
  SELECT
    BISMT,
    COUNT(DISTINCT MATNR) AS n_materiales,
    COUNTIF(ZZSUSTITUTO IS NOT NULL) AS n_switch,
    ARRAY_AGG(DISTINCT MATNR) AS materiales_agrupados
  FROM base
  WHERE BISMT IS NOT NULL
  GROUP BY BISMT
),

marcados AS (
  SELECT
    b.*,
    
    -- Regla 1: BISMT debe tener 6 dígitos numéricos (cuando no es nulo)
    (BISMT IS NOT NULL
     AND (LENGTH(CAST(BISMT AS STRING)) != 6
          OR REGEXP_CONTAINS(CAST(BISMT AS STRING), r'[^0-9]'))) AS formato_bismt,
    
    -- Regla 2: tiene ZZSUSTITUTO, BISMT no puede ser nulo/vacío
    (ZZSUSTITUTO IS NOT NULL
     AND (BISMT IS NULL OR BISMT = '')) AS bismt_nulo_con_switch,
    
    -- Regla 3: por BISMT, debe cumplir n_materiales / n_switch = n-1
    (b.BISMT IS NOT NULL
     AND g.BISMT IS NOT NULL
     AND (
       (g.n_materiales = 1 AND g.n_switch != 0) OR
       (g.n_materiales > 1 AND g.n_switch != g.n_materiales - 1)
     )) AS grupo_n_vs_nmenos1,
    
    -- Regla 4: ZZSUSTITUTO debe existir como MATNR dentro del mismo BISMT
    (b.BISMT IS NOT NULL
     AND b.ZZSUSTITUTO IS NOT NULL
     AND (
       g.materiales_agrupados IS NULL
       OR NOT b.ZZSUSTITUTO IN UNNEST(g.materiales_agrupados)
     )) AS switch_fuera_de_grupo

  FROM base b
  LEFT JOIN grupos g
    USING (BISMT)
)

SELECT
  COUNTIF(formato_bismt OR bismt_nulo_con_switch OR grupo_n_vs_nmenos1 OR switch_fuera_de_grupo) AS registros_incorrectos  
FROM marcados;
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
    WHEN v_passed > 99  THEN 'PASSED'
    WHEN v_passed < 99  THEN 'FAILED'
    else 'ERROR'
END;

-- DETALLES (opcional), aqui pongamos lo que vemaos que aporta
SET v_details = CONCAT('Total: ', v_total, ', Failed: ', v_failed, 'Validación de código agrupador');

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
  'gs://maestromateriales-dataquality-pap/REGLA_DQ_15_MARA_',
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
    BISMT,
    RIGHT(LPAD(CAST(ZZSUSTITUTO AS STRING),18,'0'),5) AS ZZSUSTITUTO,
  FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr`
  WHERE MTART IN ('ZMER','ZSEC','ZFRE')
),

grupos AS (
  SELECT
    BISMT,
    COUNT(DISTINCT MATNR) AS n_materiales,
    COUNTIF(ZZSUSTITUTO IS NOT NULL) AS n_switch,
    ARRAY_AGG(DISTINCT MATNR) AS materiales_agrupados
  FROM base
  WHERE BISMT IS NOT NULL
  GROUP BY BISMT
),

marcados AS (
  SELECT
    b.*,
    
    -- Regla 1: BISMT debe tener 6 dígitos numéricos (cuando no es nulo)
    (BISMT IS NOT NULL
     AND (LENGTH(CAST(BISMT AS STRING)) != 6
          OR REGEXP_CONTAINS(CAST(BISMT AS STRING), r'[^0-9]'))) AS formato_bismt,
    
    -- Regla 2: tiene ZZSUSTITUTO, BISMT no puede ser nulo/vacío
    (ZZSUSTITUTO IS NOT NULL
     AND (BISMT IS NULL OR BISMT = '')) AS bismt_nulo_con_switch,
    
    -- Regla 3: por BISMT, debe cumplir n_materiales / n_switch = n-1
    (b.BISMT IS NOT NULL
     AND g.BISMT IS NOT NULL
     AND (
       (g.n_materiales = 1 AND g.n_switch != 0) OR
       (g.n_materiales > 1 AND g.n_switch != g.n_materiales - 1)
     )) AS grupo_n_vs_nmenos1,
    
    -- Regla 4: ZZSUSTITUTO debe existir como MATNR dentro del mismo BISMT
    (b.BISMT IS NOT NULL
     AND b.ZZSUSTITUTO IS NOT NULL
     AND (
       g.materiales_agrupados IS NULL
       OR NOT b.ZZSUSTITUTO IN UNNEST(g.materiales_agrupados)
     )) AS switch_fuera_de_grupo

  FROM base b
  LEFT JOIN grupos g
    USING (BISMT)
)

SELECT
  *
FROM marcados;
""", file_name);

END IF;