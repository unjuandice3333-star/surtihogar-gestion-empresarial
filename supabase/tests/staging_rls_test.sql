-- ==============================================================================
-- SUITE DE PRUEBAS DE SEGURIDAD RLS EN POSTGRESQL (PARA ENTORNO DE STAGING)
-- PROYECTO: J&M / SurtiHogar
-- OBJETIVO: Validar con RLS real en PostgreSQL que las políticas y triggers
--           restringen estrictamente el acceso a datos sin riesgo de recursión.
--
-- DEPENDENCIAS Y CONDICIONES PREVIAS DE EJECUCIÓN EN STAGING:
-- 1. La migración `supabase/migrations/20260429_harden_rls_policies.sql` debe
--    haber sido aplicada previamente en el proyecto de staging.
-- 2. Tablas requeridas: businesses, users, products, sales, sale_items,
--    cash_closures, transactions, system_logs.
-- 3. NOTA SOBRE FOREIGN KEY CON auth.users: Si en el proyecto de staging
--    la tabla `public.users(id)` tiene restricción de clave foránea activa contra
--    `auth.users(id)`, asegúrese de insertar primero los UUIDs en `auth.users`
--    o utilizar IDs de usuarios de prueba ya existentes en el staging.
-- 4. Todo el script corre dentro de un bloque BEGIN ... ROLLBACK, por lo que
--    NO deja datos de prueba en la base de datos de staging.
--
-- 5. ALERTA METODOLÓGICA SOBRE CLAIMS Y POSTGREST:
--    Este script valida la lógica interna de evaluación de políticas RLS y triggers
--    dentro del motor de PostgreSQL simulando claims mediante variables de configuración
--    de sesión (GUC: `role`, `request.jwt.claim.sub`, etc.).
--    ESTA SIMULACIÓN NO SUSTITUYE LA VALIDACIÓN CRIPTOGRÁFICA DE JWTs:
--    No prueba la verificación de firmas HMAC-SHA256, expiración de tokens (`exp`),
--    ni el transporte HTTPS de PostgREST y GoTrue.
--    PRUEBAS HTTP PENDIENTES REQUERIDAS EN STAGING:
--    a) Peticiones HTTP reales contra PostgREST (/rest/v1/...) con JWT de empleado.
--    b) Peticiones con firma alterada o expirada (debe retornar HTTP 401 Unauthorized).
--    c) Peticiones con header `apikey` anónimo vs `apikey` de service_role.
-- ==============================================================================

BEGIN;

-- ------------------------------------------------------------------------------
-- 1. CONFIGURACIÓN DE IDENTIDADES DE PRUEBA
-- ------------------------------------------------------------------------------
DO $$
DECLARE
  v_biz_a UUID := '11111111-1111-1111-1111-111111111111';
  v_biz_b UUID := '22222222-2222-2222-2222-222222222222';
  
  v_admin_a UUID := 'aaaaaaaa-0000-0000-0000-000000000001';
  v_emp_a   UUID := 'aaaaaaaa-0000-0000-0000-000000000002';
  v_admin_b UUID := 'bbbbbbbb-0000-0000-0000-000000000001';
  v_emp_b   UUID := 'bbbbbbbb-0000-0000-0000-000000000002';
  v_ext_user UUID := 'eeeeeeee-0000-0000-0000-000000000001';
  v_del_user UUID := 'dddddddd-0000-0000-0000-000000000001';

  v_prod_a UUID := 'aaaaaaaa-1111-0000-0000-000000000001';
  v_prod_b UUID := 'bbbbbbbb-1111-0000-0000-000000000001';
  v_sale_a UUID := 'aaaaaaaa-2222-0000-0000-000000000001';
  v_sale_b UUID := 'bbbbbbbb-2222-0000-0000-000000000001';
  v_close_a UUID := 'aaaaaaaa-3333-0000-0000-000000000001';
  v_close_b UUID := 'bbbbbbbb-3333-0000-0000-000000000001';
  v_tx_a    UUID := 'aaaaaaaa-4444-0000-0000-000000000001';
  v_tx_b    UUID := 'bbbbbbbb-4444-0000-0000-000000000001';

  v_count INT;
BEGIN
  RAISE NOTICE '=======================================================';
  RAISE NOTICE ' INICIANDO BATERÍA DE PRUEBAS RLS REALES EN POSTGRESQL ';
  RAISE NOTICE '=======================================================';

  -- Crear negocios de prueba (si no existen)
  INSERT INTO public.businesses (id, name) VALUES 
    (v_biz_a, 'Empresa A Test'),
    (v_biz_b, 'Empresa B Test')
  ON CONFLICT (id) DO NOTHING;

  -- Crear usuarios de prueba en public.users
  INSERT INTO public.users (id, name, email, role, business_id, is_cashier) VALUES
    (v_admin_a, 'Admin A', 'admin_a@test.com', 'admin', v_biz_a, false),
    (v_emp_a,   'Emp A',   'emp_a@test.com',   'empleado', v_biz_a, true),
    (v_admin_b, 'Admin B', 'admin_b@test.com', 'admin', v_biz_b, false),
    (v_emp_b,   'Emp B',   'emp_b@test.com',   'empleado', v_biz_b, false),
    (v_ext_user, 'Ext User', 'ext@test.com',    'empleado', NULL, false),
    (v_del_user, 'Del User', 'del@test.com',    'empleado', v_biz_a, false)
  ON CONFLICT (id) DO UPDATE SET 
    role = EXCLUDED.role, 
    business_id = EXCLUDED.business_id, 
    is_cashier = EXCLUDED.is_cashier;

  -- Crear productos de prueba
  INSERT INTO public.products (id, name, business_id, sale_price, stock) VALUES
    (v_prod_a, 'Nevera A', v_biz_a, 1000000, 10),
    (v_prod_b, 'Comedor B', v_biz_b, 800000, 5)
  ON CONFLICT (id) DO NOTHING;

  -- Crear ventas e ítems de prueba
  INSERT INTO public.sales (id, user_id, total, payment_method) VALUES
    (v_sale_a, v_emp_a, 1000000, 'Efectivo'),
    (v_sale_b, v_emp_b, 800000, 'Addi')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.sale_items (sale_id, product_id, quantity, price) VALUES
    (v_sale_a, v_prod_a, 1, 1000000),
    (v_sale_b, v_prod_b, 1, 800000)
  ON CONFLICT DO NOTHING;

  -- Crear cierres de caja de prueba
  INSERT INTO public.cash_closures (id, user_id, business_id, date, cash_amount) VALUES
    (v_close_a, v_emp_a, v_biz_a, '2026-10-09', 500000),
    (v_close_b, v_emp_b, v_biz_b, '2026-10-09', 800000)
  ON CONFLICT (id) DO NOTHING;

  -- Crear transacciones contables de prueba
  INSERT INTO public.transactions (id, business_id, user_id, type, amount, note) VALUES
    (v_tx_a, v_biz_a, v_emp_a, 'income', 100000, 'Transacción legítima Sede A'),
    (v_tx_b, v_biz_b, v_emp_b, 'income', 200000, 'Transacción legítima Sede B')
  ON CONFLICT (id) DO NOTHING;

  RAISE NOTICE '-> Datos de prueba inicializados correctamente.';
END $$;


-- ------------------------------------------------------------------------------
-- 2. PRUEBA: EMPLEADO DE EMPRESA A (Lecturas y Escrituras Legítimas)
-- ------------------------------------------------------------------------------
DO $$
DECLARE
  v_emp_a UUID := 'aaaaaaaa-0000-0000-0000-000000000002';
  v_biz_a UUID := '11111111-1111-1111-1111-111111111111';
  v_biz_b UUID := '22222222-2222-2222-2222-222222222222';
  v_new_tx_id UUID := 'aaaaaaaa-4444-0000-0000-000000000099';
  v_count INT;
BEGIN
  -- Establecer contexto autenticado para Empleado A
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.sub', v_emp_a::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', v_emp_a::text)::text, true);

  -- 2.1 Verificación de Catálogo Compartido (Clúster POS)
  SELECT count(*) INTO v_count FROM public.products;
  IF v_count < 2 THEN
    RAISE EXCEPTION 'FALLO: Empleado A no puede consultar el catálogo compartido de productos.';
  END IF;
  RAISE NOTICE '✅ [PASÓ] Catálogo compartido visible para el empleado en POS.';

  -- 2.2 Verificación de Ventas Propias (Solo debe ver su venta, no la de Emp B)
  SELECT count(*) INTO v_count FROM public.sales;
  IF v_count != 1 THEN
    RAISE EXCEPTION 'FALLO: Empleado A ve % ventas (debería ver únicamente 1 venta propia).', v_count;
  END IF;
  RAISE NOTICE '✅ [PASÓ] Aislamiento de ventas: Empleado solo ve sus propias ventas.';

  -- 2.3 Verificación de Cierres de Caja (Solo debe ver los de su Sede A)
  SELECT count(*) INTO v_count FROM public.cash_closures WHERE business_id = v_biz_b;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'FALLO: Empleado A pudo ver cierres de caja de la Empresa B.';
  END IF;
  RAISE NOTICE '✅ [PASÓ] Aislamiento de cierres de caja entre empresas respetado.';

  -- 2.4 Verificación de Transacciones (Solo ve las de su sede, no las de Empresa B)
  SELECT count(*) INTO v_count FROM public.transactions WHERE business_id = v_biz_b;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'FALLO: Empleado A pudo ver transacciones de la Empresa B.';
  END IF;
  RAISE NOTICE '✅ [PASÓ] Aislamiento de transacciones financieras entre empresas respetado.';

  -- 2.5 Inserción Legítima de Transacción en Sede Propia (Prueba positiva)
  INSERT INTO public.transactions (id, user_id, business_id, amount, type, note)
  VALUES (v_new_tx_id, v_emp_a, v_biz_a, 25000, 'income', 'Venta menor mostrador');
  IF NOT EXISTS (SELECT 1 FROM public.transactions WHERE id = v_new_tx_id) THEN
    RAISE EXCEPTION 'FALLO: Empleado A no pudo registrar una transacción legítima en su propia sede.';
  END IF;
  RAISE NOTICE '✅ [PASÓ] Inserción de transacción en sede autorizada completada con éxito.';

  -- 2.6 Verificación de Consulta de Usuarios (Solo debe ver su sede)
  SELECT count(*) INTO v_count FROM public.users WHERE business_id = v_biz_b;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'FALLO: Empleado A pudo consultar usuarios pertenecientes a la Empresa B.';
  END IF;
  RAISE NOTICE '✅ [PASÓ] Consulta de usuarios por sede sin recursión RLS.';
END $$;


-- ------------------------------------------------------------------------------
-- 3. PRUEBAS NEGATIVAS: INTENTOS DE VIOLACIÓN DE ACCESO POR EMPLEADO
-- ------------------------------------------------------------------------------
DO $$
DECLARE
  v_emp_a UUID := 'aaaaaaaa-0000-0000-0000-000000000002';
  v_emp_b UUID := 'bbbbbbbb-0000-0000-0000-000000000002';
  v_biz_b UUID := '22222222-2222-2222-2222-222222222222';
  v_sale_b UUID := 'bbbbbbbb-2222-0000-0000-000000000001';
  v_prod_a UUID := 'aaaaaaaa-1111-0000-0000-000000000001';
  v_err_caught BOOLEAN := false;
  v_err_msg TEXT;
  v_err_code TEXT;
  v_rows INT;
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.sub', v_emp_a::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', v_emp_a::text)::text, true);

  -- 3.1 Intento de Autoescalada a Administrador (Debe fallar con P0001 del trigger)
  v_err_caught := false;
  v_err_code := '';
  BEGIN
    UPDATE public.users SET role = 'admin' WHERE id = v_emp_a;
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := true;
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT, v_err_code = RETURNED_SQLSTATE;
  END;
  IF NOT v_err_caught OR v_err_code != 'P0001' THEN
    RAISE EXCEPTION 'FALLO CRÍTICO: Autoescalada no arrojó la excepción P0001 esperada (Código: %, Msg: %)', v_err_code, v_err_msg;
  END IF;
  RAISE NOTICE '✅ [PASÓ] Bloqueo de autoescalada de rol verificado [P0001]: %', v_err_msg;

  -- 3.2 Intento de Cambio de Sede Comercial (business_id) (Debe fallar con P0001)
  v_err_caught := false;
  v_err_code := '';
  BEGIN
    UPDATE public.users SET business_id = v_biz_b WHERE id = v_emp_a;
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := true;
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT, v_err_code = RETURNED_SQLSTATE;
  END;
  IF NOT v_err_caught OR v_err_code != 'P0001' THEN
    RAISE EXCEPTION 'FALLO CRÍTICO: Cambio de sede no arrojó excepción P0001 (Código: %, Msg: %)', v_err_code, v_err_msg;
  END IF;
  RAISE NOTICE '✅ [PASÓ] Bloqueo de cambio de sede comercial verificado [P0001]: %', v_err_msg;

  -- 3.3 Intento de Autoasignarse Permiso de Cajero (is_cashier) (Debe fallar con P0001)
  v_err_caught := false;
  v_err_code := '';
  BEGIN
    UPDATE public.users SET is_cashier = NOT is_cashier WHERE id = v_emp_a;
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := true;
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT, v_err_code = RETURNED_SQLSTATE;
  END;
  IF NOT v_err_caught OR v_err_code != 'P0001' THEN
    RAISE EXCEPTION 'FALLO CRÍTICO: Alteración de cajero no arrojó excepción P0001 (Código: %, Msg: %)', v_err_code, v_err_msg;
  END IF;
  RAISE NOTICE '✅ [PASÓ] Bloqueo de alteración de permisos de cajero verificado [P0001]: %', v_err_msg;

  -- 3.3b Intento de Modificar Permiso de Inventario (can_manage_inventory) (Debe fallar con P0001)
  v_err_caught := false;
  v_err_code := '';
  BEGIN
    UPDATE public.users SET can_manage_inventory = true WHERE id = v_emp_a;
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := true;
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT, v_err_code = RETURNED_SQLSTATE;
  END;
  IF NOT v_err_caught OR v_err_code != 'P0001' THEN
    RAISE EXCEPTION 'FALLO CRÍTICO: Alteración de inventario no arrojó excepción P0001 (Código: %, Msg: %)', v_err_code, v_err_msg;
  END IF;
  RAISE NOTICE '✅ [PASÓ] Bloqueo de permiso de inventario verificado [P0001]: %', v_err_msg;

  -- 3.3c Intento de Alterar Tarifa Horaria de Nómina (hourly_rate) (Debe fallar con P0001)
  v_err_caught := false;
  v_err_code := '';
  BEGIN
    UPDATE public.users SET hourly_rate = 99999 WHERE id = v_emp_a;
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := true;
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT, v_err_code = RETURNED_SQLSTATE;
  END;
  IF NOT v_err_caught OR v_err_code != 'P0001' THEN
    RAISE EXCEPTION 'FALLO CRÍTICO: Alteración salarial no arrojó excepción P0001 (Código: %, Msg: %)', v_err_code, v_err_msg;
  END IF;
  RAISE NOTICE '✅ [PASÓ] Bloqueo de alteración de tarifa horaria verificado [P0001]: %', v_err_msg;

  -- 3.3d Intento de Modificar Email (Debe fallar con P0001)
  v_err_caught := false;
  v_err_code := '';
  BEGIN
    UPDATE public.users SET email = 'hacker@test.com' WHERE id = v_emp_a;
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := true;
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT, v_err_code = RETURNED_SQLSTATE;
  END;
  IF NOT v_err_caught OR v_err_code != 'P0001' THEN
    RAISE EXCEPTION 'FALLO CRÍTICO: Alteración de email no arrojó excepción P0001 (Código: %, Msg: %)', v_err_code, v_err_msg;
  END IF;
  RAISE NOTICE '✅ [PASÓ] Bloqueo de alteración de email de acceso verificado [P0001]: %', v_err_msg;

  -- 3.3f Intento de Modificar ID Inmutable (Debe fallar con P0001)
  v_err_caught := false;
  v_err_code := '';
  BEGIN
    UPDATE public.users SET id = 'ffffffff-0000-0000-0000-000000000001' WHERE id = v_emp_a;
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := true;
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT, v_err_code = RETURNED_SQLSTATE;
  END;
  IF NOT v_err_caught OR v_err_code != 'P0001' THEN
    RAISE EXCEPTION 'FALLO CRÍTICO: Alteración de id no arrojó excepción P0001 (Código: %, Msg: %)', v_err_code, v_err_msg;
  END IF;
  RAISE NOTICE '✅ [PASÓ] Bloqueo de alteración de ID inmutable verificado [P0001]: %', v_err_msg;

  -- 3.3g Intento de Modificar Estado Activo (active) (Debe fallar con P0001)
  v_err_caught := false;
  v_err_code := '';
  BEGIN
    UPDATE public.users SET active = false WHERE id = v_emp_a;
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := true;
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT, v_err_code = RETURNED_SQLSTATE;
  END;
  IF NOT v_err_caught OR v_err_code != 'P0001' THEN
    RAISE EXCEPTION 'FALLO CRÍTICO: Alteración de active no arrojó excepción P0001 (Código: %, Msg: %)', v_err_code, v_err_msg;
  END IF;
  RAISE NOTICE '✅ [PASÓ] Bloqueo de alteración de estado activo verificado [P0001]: %', v_err_msg;

  -- 3.3e Operación Permitida para Empleado: Modificar su propio nombre (Prueba positiva)
  UPDATE public.users SET name = 'Emp A Renombrado' WHERE id = v_emp_a;
  IF (SELECT name FROM public.users WHERE id = v_emp_a) != 'Emp A Renombrado' THEN
    RAISE EXCEPTION 'FALLO: Empleado no pudo modificar su propio nombre de perfil permitido.';
  END IF;
  RAISE NOTICE '✅ [PASÓ] Modificación de campo permitido (name) completada exitosamente.';

  -- 3.4 Intento de Modificar Precios de Productos (Debe actualizar 0 filas bajo RLS)
  v_rows := 0;
  BEGIN
    UPDATE public.products SET sale_price = 100 WHERE id = v_prod_a;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
  EXCEPTION WHEN OTHERS THEN
    v_rows := 0;
  END;
  IF v_rows > 0 OR (SELECT sale_price FROM public.products WHERE id = v_prod_a) = 100 THEN
    RAISE EXCEPTION 'FALLO CRÍTICO: Empleado pudo modificar el precio de un producto en catálogo.';
  END IF;
  RAISE NOTICE '✅ [PASÓ] Protección de precios de inventario contra empleados verificada (0 filas afectadas).';

  -- 3.5 Intento de Insertar Ítems en Venta Ajena (Debe fallar con 42501 de RLS)
  v_err_caught := false;
  v_err_code := '';
  BEGIN
    INSERT INTO public.sale_items (sale_id, product_id, quantity, price)
    VALUES (v_sale_b, v_prod_a, 2, 500000);
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := true;
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT, v_err_code = RETURNED_SQLSTATE;
  END;
  IF NOT v_err_caught OR v_err_code != '42501' THEN
    RAISE EXCEPTION 'FALLO CRÍTICO: Inserción de ítem ajeno no arrojó 42501 de RLS (Código: %, Msg: %)', v_err_code, v_err_msg;
  END IF;
  RAISE NOTICE '✅ [PASÓ] Bloqueo de vinculación de artículos a ventas ajenas verificado [42501]: %', v_err_msg;

  -- 3.6 Intento de Insertar Transacción en Sede Ajena (Debe fallar con 42501 de RLS)
  v_err_caught := false;
  v_err_code := '';
  BEGIN
    INSERT INTO public.transactions (user_id, business_id, amount, type, note)
    VALUES (v_emp_a, v_biz_b, 50000, 'income', 'Intento fraudulento');
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := true;
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT, v_err_code = RETURNED_SQLSTATE;
  END;
  IF NOT v_err_caught OR v_err_code != '42501' THEN
    RAISE EXCEPTION 'FALLO CRÍTICO: Inserción en sede ajena no arrojó 42501 de RLS (Código: %, Msg: %)', v_err_code, v_err_msg;
  END IF;
  RAISE NOTICE '✅ [PASÓ] Bloqueo de transacciones financieras en sedes ajenas verificado [42501]: %', v_err_msg;
END $$;


-- ------------------------------------------------------------------------------
-- 4. PRUEBA: USUARIO ANÓNIMO
-- ------------------------------------------------------------------------------
DO $$
DECLARE
  v_count INT;
  v_err_caught BOOLEAN := false;
  v_err_msg TEXT;
  v_err_code TEXT;
BEGIN
  PERFORM set_config('role', 'anon', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claim.role', 'anon', true);
  PERFORM set_config('request.jwt.claims', '{}', true);

  -- 4.1 Anon intentando leer productos -> 0 filas
  SELECT count(*) INTO v_count FROM public.products;
  IF v_count > 0 THEN
    RAISE EXCEPTION 'FALLO: Usuario anónimo pudo leer la tabla de productos.';
  END IF;

  -- 4.2 Anon intentando insertar configuración sensible en logs (Debe fallar con 42501 de RLS)
  v_err_caught := false;
  v_err_code := '';
  BEGIN
    INSERT INTO public.system_logs (module, type, message)
    VALUES ('sistema', 'TELEGRAM_CONFIG', '{"botToken":"malicioso"}');
  EXCEPTION WHEN OTHERS THEN
    v_err_caught := true;
    GET STACKED DIAGNOSTICS v_err_msg = MESSAGE_TEXT, v_err_code = RETURNED_SQLSTATE;
  END;
  IF NOT v_err_caught OR v_err_code != '42501' THEN
    RAISE EXCEPTION 'FALLO: Inserción anónima indebida no arrojó 42501 de RLS (Código: %, Msg: %)', v_err_code, v_err_msg;
  END IF;
  RAISE NOTICE '✅ [PASÓ] Restricciones para usuario anónimo verificadas con éxito [42501]: %', v_err_msg;
END $$;


-- ------------------------------------------------------------------------------
-- 5. PRUEBA: OPERACIONES LEGÍTIMAS DE ADMINISTRADOR
-- ------------------------------------------------------------------------------
DO $$
DECLARE
  v_admin_a UUID := 'aaaaaaaa-0000-0000-0000-000000000001';
  v_emp_a   UUID := 'aaaaaaaa-0000-0000-0000-000000000002';
  v_prod_a  UUID := 'aaaaaaaa-1111-0000-0000-000000000001';
  v_del_user UUID := 'dddddddd-0000-0000-0000-000000000001';
  v_count INT;
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.sub', v_admin_a::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', v_admin_a::text)::text, true);

  -- 5.1 Admin puede modificar precios
  UPDATE public.products SET sale_price = 1200000 WHERE id = v_prod_a;
  IF (SELECT sale_price FROM public.products WHERE id = v_prod_a) != 1200000 THEN
    RAISE EXCEPTION 'FALLO: Administrador no pudo actualizar el precio de un producto.';
  END IF;

  -- 5.2 Admin puede actualizar roles y permisos de personal (Prueba positiva de administración)
  UPDATE public.users SET 
    is_cashier = false, 
    can_manage_inventory = true, 
    hourly_rate = 12000, 
    role = 'admin' 
  WHERE id = v_emp_a;
  IF (SELECT hourly_rate FROM public.users WHERE id = v_emp_a) != 12000 THEN
    RAISE EXCEPTION 'FALLO: Administrador no pudo actualizar tarifa y permisos de un empleado.';
  END IF;
  RAISE NOTICE '✅ [PASÓ] Administrador actualizó rol, tarifa y permisos de empleado con éxito.';

  -- 5.3 Admin puede eliminar colaboradores (requerido por main.js L1064)
  DELETE FROM public.users WHERE id = v_del_user;
  IF EXISTS (SELECT 1 FROM public.users WHERE id = v_del_user) THEN
    RAISE EXCEPTION 'FALLO: Administrador no pudo eliminar colaborador mediante política Admins delete users.';
  END IF;
  RAISE NOTICE '✅ [PASÓ] Eliminación de usuario por administrador verificada exitosamente.';

  -- 5.4 Flujo legítimo de creación de usuarios (Simulando trigger handle_new_user / auth daemon)
  PERFORM set_config('role', 'postgres', true);
  INSERT INTO public.users (id, name, email, role, business_id)
  VALUES ('99999999-0000-0000-0000-000000000001', 'Nuevo Registrado', 'nuevo@test.com', 'empleado', v_admin_a);
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = '99999999-0000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'FALLO: Flujo de creación de usuarios por infraestructura falló.';
  END IF;
  RAISE NOTICE '✅ [PASÓ] Creación legítima de usuario (flujo Auth daemon / handle_new_user) verificada.';

  RAISE NOTICE '✅ [PASÓ] Operaciones administrativas legítimas comprobadas con éxito.';
  RAISE NOTICE '=======================================================';
  RAISE NOTICE ' TODAS LAS PRUEBAS DE SEGURIDAD RLS EN STAGING PASARON ';
  RAISE NOTICE '=======================================================';
END $$;

-- REVERSIÓN INMEDIATA PARA NO DEJAR BASURA EN LA BASE DE DATOS
ROLLBACK;
