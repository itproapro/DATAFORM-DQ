--query_proveedores_funcion_interlocutor_PARVW

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
SET v_rule_id = 119;

-- DEFINIR LA REGLA ASIGNADA A v_query: -- Función interlocutor --> Abreviatura que identifica la denominación de la función de interlocutor. Sirve para identificar la dirección de pedido, el proveedor, emisor de factura, gestor/comprador..

SET v_query = '''
    WITH validacion_por_proveedor AS (
        SELECT
            LIFNR,
            COUNTIF(UPPER(TRIM(COALESCE(PARVW, ''))) = 'BA') AS NUM_DP,
            COUNTIF(UPPER(TRIM(COALESCE(PARVW, ''))) = 'LF') AS NUM_PR,
            COUNTIF(UPPER(TRIM(COALESCE(PARVW, ''))) = 'RS') AS NUM_EF,
            COUNTIF(UPPER(TRIM(COALESCE(PARVW, ''))) = 'ZE') AS NUM_ZE,
            COUNTIF(UPPER(TRIM(COALESCE(PARVW, ''))) = 'ZO') AS NUM_ZO
        FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_zwyt3` 
        GROUP BY LIFNR
        )
        SELECT
            COUNT(*)
        FROM validacion_por_proveedor
            WHERE
            (SUBSTR(LPAD(CAST(LIFNR AS STRING),10, '0'),6,1) ='1')
            AND
            (NUM_DP = 0
            OR NUM_PR = 0
            OR NUM_EF = 0
            OR NUM_ZE = 0
            OR NUM_ZO > 0);
''';

-- CALCULAR TOTAL DE REGISTROS E INCUMPLIMIENTOS
-- Calculo los valores totales
SET v_total = (SELECT COUNT(*) 
FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_zwyt3`
WHERE SUBSTR(LPAD(CAST(LIFNR AS STRING), 10, '0'), 6, 1) ='1');
-- Calculo los valores que no cumplen la condición y los asigno a v_failed
EXECUTE IMMEDIATE v_query INTO v_failed;

IF v_failed IS NULL THEN
  SET v_failed = 0;
END IF;

-- CALCULAR PORCENTAJE COMPLETITUD

SET v_passed = ROUND(COALESCE((1 - SAFE_DIVIDE(v_failed, v_total))*100,100),2);



-- ESTABLECER STATUS: de acuerdo a lo que establescamos, valores críticos tienen que ser 100%
SET v_status = CASE
    WHEN v_passed >= 95 or v_passed is null THEN 'PASSED'
    WHEN v_passed < 95 THEN 'FAILED'
    ELSE 'ERROR'
END;

-- DETALLES (opcional), aqui pongamos lo que vemaos que aporta
SET v_details = CONCAT('Total: ', v_total, ', Failed: ', v_failed, ' Validamos que cada proveedor tenga las siguientes Funciones de interlocutor ("ZE","EF","DP","PR") y que no tengan la función "ZO".');

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
  'gs://maestromateriales-dataquality-pap/REGLA_DQ_119_WYT3_',
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
    WITH validacion_por_proveedor AS (
    SELECT
      LIFNR,
      COUNTIF(UPPER(TRIM(COALESCE(PARVW, ''))) = 'BA') AS NUM_DP,
      COUNTIF(UPPER(TRIM(COALESCE(PARVW, ''))) = 'LF') AS NUM_PR,
      COUNTIF(UPPER(TRIM(COALESCE(PARVW, ''))) = 'RS') AS NUM_EF,
      COUNTIF(UPPER(TRIM(COALESCE(PARVW, ''))) = 'ZE') AS NUM_ZE,
      COUNTIF(UPPER(TRIM(COALESCE(PARVW, ''))) = 'ZO') AS NUM_ZO
    FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_zwyt3` 
    GROUP BY LIFNR
    )
    SELECT
      LIFNR,
      ARRAY_TO_STRING(
        ARRAY_CONCAT(
          IF(NUM_DP = 0, ['Falta la clave DP(BA)'], []),
          IF(NUM_PR = 0, ['Falta la clave PR(LF)'], []),
          IF(NUM_EF = 0, ['Falta la clave EF(RS)'], []),
          IF(NUM_ZE = 0, ['Falta la clave ZE'], []),
          IF(NUM_ZO > 0, ['Contiene la clave no permitida ZO'], [])
        ),
        '; '
      ) AS MOTIVO_ERROR,
      NUM_DP,
      NUM_PR,
      NUM_EF,
      NUM_ZE,
      NUM_ZO
    FROM validacion_por_proveedor
    WHERE
      (SUBSTR(LPAD(CAST(LIFNR AS STRING),10, '0'),6,1) ='1')
      AND
      (NUM_DP = 0
      OR NUM_PR = 0
      OR NUM_EF = 0
      OR NUM_ZE = 0
      OR NUM_ZO > 0)
    ORDER BY LIFNR;   
""", file_name);

END IF;