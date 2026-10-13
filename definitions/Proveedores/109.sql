--query_proveedores_moneda_pedido_WAERS

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
SET v_rule_id = 109;

-- DEFINIR LA REGLA ASIGNADA A v_query: --  Moneda de pedido  --> Moneda en la que se realizan los pedidos al proveedor.

SET v_query = '''
        SELECT 
          COUNT(*) 
        FROM `cf-esproapro-bic-pro-ou.bqt_zlfa1` AS lfa
        JOIN `cf-esproapro-bic-pro-ou.bqt_zlfm1` AS lfm 
        ON  lfa.LIFNR = lfm.LIFNR
        WHERE  
          (SUBSTR(LPAD(CAST(lfa.LIFNR AS STRING),10,'0'),6,1) = '1') 
          AND 
          lfm.WAERS IS NULL OR lfm.WAERS = '';
''';

-- CALCULAR TOTAL DE REGISTROS E INCUMPLIMIENTOS
-- Calculo los valores totales
SET v_total = (SELECT COUNT(*) 
FROM `cf-esproapro-bic-pro-ou.bqt_zlfa1` AS lfa
JOIN `cf-esproapro-bic-pro-ou.bqt_zlfm1` AS lfm 
ON  lfa.LIFNR = lfm.LIFNR
WHERE (SUBSTR(LPAD(CAST(LIFNR AS STRING),10,'0'),6,1) = '1'));
-- Calculo los valores que no cumplen la condición y los asigno a v_failed
EXECUTE IMMEDIATE v_query INTO v_failed;

IF v_failed IS NULL THEN
  SET v_failed = 0;
END IF;

-- CALCULAR PORCENTAJE COMPLETITUD

SET v_passed = ROUND(COALESCE((1 - SAFE_DIVIDE(v_failed, v_total))*100,100),2);



-- ESTABLECER STATUS: de acuerdo a lo que establescamos, valores críticos tienen que ser 100%
SET v_status = CASE
    WHEN v_passed >= 90 or v_passed is null THEN 'PASSED'
    WHEN v_passed < 90 THEN 'FAILED'
    ELSE 'ERROR'
END;

-- DETALLES (opcional), aqui pongamos lo que vemaos que aporta
SET v_details = CONCAT('Total: ', v_total, ', Failed: ', v_failed, ' Validamos que este cumplimentado el campo día de pedido del proveedor.');

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
  'gs://maestromateriales-dataquality-pap/REGLA_DQ_109_LFM1_',
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
     SELECT 
      LIFNR, 
      WAERS 
    FROM `cf-esproapro-bic-pro-ou.bqt_zlfa1` AS lfa
    JOIN `cf-esproapro-bic-pro-ou.bqt_zlfm1` AS lfm 
    ON  lfa.LIFNR = lfm.LIFNR
      WHERE lfm.WAERS IS NULL OR lfm.WAERS = '';   
""", file_name);

END IF;