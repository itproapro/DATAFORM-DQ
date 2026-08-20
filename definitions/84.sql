--query_can_umb4_UMREZ

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
SET v_rule_id = 84;

-- DEFINIR LA REGLA ASIGNADA A v_query: -- Cantidad Unidad de medida base 4 --> el valor de este campo (umb4) será múltiplo del campo cantidad de unidad de medida alternativa 4 (uma4).

SET v_query = '''
    WITH MARM AS (
        SELECT
          RIGHT(LPAD(CAST(m.MATNR AS STRING),18,'0'),5) AS MATNR,
          mr.MEINH AS MEINH_MARM,
          mr.UMREZ 
        FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr` AS m
        JOIN `cf-esproapro-bic-pro-ou.SH_STG.bqt_ztbw_marm` AS mr
        ON m.MATNR = mr.MATNR
          WHERE
            m.MTART IN ('ZMER','ZFRE','ZSEC')
            AND
            mr.MEINH IN ('PAL', 'CAP')
        ),
        pivot AS (
          SELECT
            MATNR,
            MAX(CASE WHEN MEINH_MARM = 'PAL' THEN UMREZ END) AS umrez_pal,
            MAX(CASE WHEN MEINH_MARM = 'CAP' THEN UMREZ END) AS umrez_cap
          FROM MARM 
          GROUP BY MATNR 
        )
        SELECT
          COUNT(*)
        FROM pivot 
          WHERE
            umrez_pal IS NOT NULL
            AND
            umrez_cap IS NOT NULL
            AND (
              umrez_cap = 0 OR MOD(umrez_pal,umrez_cap)!= 0);
''';



-- CALCULAR TOTAL DE REGISTROS E INCUMPLIMIENTOS
-- Calculo los valores totales
SET v_total = (SELECT
  COUNT(*)
  FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr` AS m
    JOIN `cf-esproapro-bic-pro-ou.SH_STG.bqt_ztbw_marm` AS mr
    ON m.MATNR = mr.MATNR 
    WHERE MTART IN ('ZMER','ZSEC','ZFRE')
    AND mr.MEINH IN ('PAL', 'CAP'));
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
SET v_details = CONCAT('Total: ', v_total, ', Failed: ', v_failed, ' Validamos el valor de la unidad de medida base 4 (CAP) en relación con la uma4(PAL).');

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
  'gs://maestromateriales-dataquality-pap/REGLA_DQ_84_MARA_',
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
    WITH MARM AS (
        SELECT
          RIGHT(LPAD(CAST(m.MATNR AS STRING),18,'0'),5) AS MATNR,
          mr.MEINH AS MEINH_MARM,
          mr.UMREZ 
        FROM `cf-esproapro-bic-pro-ou.SH_STG.bqt_material_attr` AS m
        JOIN `cf-esproapro-bic-pro-ou.SH_STG.bqt_ztbw_marm` AS mr
        ON m.MATNR = mr.MATNR
          WHERE
            m.MTART IN ('ZMER','ZFRE','ZSEC')
            AND
            mr.MEINH IN ('PAL', 'CAP')
        ),
        pivot AS (
          SELECT
            MATNR,
            MAX(CASE WHEN MEINH_MARM = 'PAL' THEN UMREZ END) AS umrez_pal,
            MAX(CASE WHEN MEINH_MARM = 'CAP' THEN UMREZ END) AS umrez_cap
          FROM MARM 
          GROUP BY MATNR 
        )
        SELECT
          COUNT(*)
        FROM pivot 
          WHERE
            umrez_pal IS NOT NULL
            AND
            umrez_cap IS NOT NULL
            AND (
              umrez_cap = 0 OR MOD(umrez_pal,umrez_cap)!= 0);
     
""", file_name);

END IF;