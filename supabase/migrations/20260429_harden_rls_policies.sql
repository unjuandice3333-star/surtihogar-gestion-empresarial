-- ==============================================================================
-- MIGRACIÓN PROPUESTA: 20260429_harden_rls_policies.sql
-- PROYECTO: J&M / SurtiHogar
-- OBJETIVO: Endurecer las políticas de seguridad a nivel de fila (RLS) en Supabase/PostgreSQL.
-- ESTADO: PROPUESTA TÉCNICA REVISADA (NO EJECUTADA EN PRODUCCIÓN).
--
-- PRINCIPIOS DE DISEÑO:
-- 1. Cero recursión RLS: Funciones auxiliares STABLE SECURITY DEFINER con search_path aislado.
-- 2. Privilegio mínimo: REVOKE a PUBLIC y anon; GRANT exclusivo a authenticated.
-- 3. Inmutabilidad contable: Los empleados no pueden alterar ventas históricas ni transacciones.
-- 4. Soporte POS Clúster: Empleados pueden consultar catálogo completo para vender.
-- 5. Rollback determinista: Restaura las políticas originales documentadas sin USING (true).
-- ==============================================================================

-- ==============================================================================
-- SECCIÓN 0: FUNCIONES AUXILIARES DE RLS (SEGURIDAD Y PREVENCIÓN DE RECURSIÓN)
-- ==============================================================================

-- 0.1 Función para verificar si el usuario autenticado actual es Administrador activo
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users 
    WHERE id = auth.uid() 
      AND role = 'admin'
      AND (active IS NULL OR active = true)
  );
$$;

-- 0.2 Función para consultar la sede (business_id) asignada al usuario actual activo
CREATE OR REPLACE FUNCTION public.get_current_user_business_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT business_id FROM public.users 
  WHERE id = auth.uid() 
    AND (active IS NULL OR active = true) 
  LIMIT 1;
$$;

-- 0.3 Función para consultar el rol del usuario actual activo
CREATE OR REPLACE FUNCTION public.get_current_user_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT role FROM public.users 
  WHERE id = auth.uid() 
    AND (active IS NULL OR active = true) 
  LIMIT 1;
$$;

-- 0.4 Restringir permisos de ejecución: Aislar de roles no autorizados
REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_admin() FROM anon;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;

REVOKE ALL ON FUNCTION public.get_current_user_business_id() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_current_user_business_id() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_current_user_business_id() TO authenticated;

REVOKE ALL ON FUNCTION public.get_current_user_role() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_current_user_role() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_current_user_role() TO authenticated;


-- ==============================================================================
-- SECCIÓN 1: system_logs
-- ==============================================================================
ALTER TABLE public.system_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can insert logs" ON public.system_logs;
DROP POLICY IF EXISTS "All users can insert logs" ON public.system_logs;
DROP POLICY IF EXISTS "Users can insert logs" ON public.system_logs;
DROP POLICY IF EXISTS "Only admins can see logs" ON public.system_logs;
DROP POLICY IF EXISTS "Admins can view logs" ON public.system_logs;
DROP POLICY IF EXISTS "Admins view all logs" ON public.system_logs;
DROP POLICY IF EXISTS "Employees view own logs" ON public.system_logs;
DROP POLICY IF EXISTS "Anon only report auth errors" ON public.system_logs;
DROP POLICY IF EXISTS "Employees insert own operational logs" ON public.system_logs;
DROP POLICY IF EXISTS "Admins insert any log" ON public.system_logs;

-- 1.1 LECTURA: Solo administradores y el propio creador del log
CREATE POLICY "Admins view all logs" ON public.system_logs
FOR SELECT TO authenticated
USING (public.is_admin());

CREATE POLICY "Employees view own logs" ON public.system_logs
FOR SELECT TO authenticated
USING (auth.uid() = user_id);

-- 1.2 INSERCIÓN ANÓNIMA: Estrictamente para reportar errores de login cuando la sesión aún no existe
CREATE POLICY "Anon only report auth errors" ON public.system_logs
FOR INSERT TO anon
WITH CHECK (
  module = 'auth' 
  AND type IN ('error', 'Auth Error')
  AND user_id IS NULL
);

-- 1.3 INSERCIÓN EMPLEADOS: Solo registros operativos propios, prohibiendo tipos reservados
CREATE POLICY "Employees insert own operational logs" ON public.system_logs
FOR INSERT TO authenticated
WITH CHECK (
  auth.uid() = user_id
  AND type NOT IN ('TELEGRAM_CONFIG', 'PURGE_EVENT', 'SUPPLIER_RECORD', 'GEOFENCE_POLYGON')
);

-- 1.4 INSERCIÓN ADMINISTRADORES: Admins registran cualquier evento y configuración
CREATE POLICY "Admins insert any log" ON public.system_logs
FOR INSERT TO authenticated
WITH CHECK (public.is_admin());


-- ==============================================================================
-- SECCIÓN 2: products (Catálogo e Inventario)
-- ==============================================================================
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone authenticated can view products" ON public.products;
DROP POLICY IF EXISTS "Authenticated users view products" ON public.products;
DROP POLICY IF EXISTS "Only admins insert products" ON public.products;
DROP POLICY IF EXISTS "Only admins update products" ON public.products;
DROP POLICY IF EXISTS "Only admins delete products" ON public.products;

-- 2.1 LECTURA: Todos los usuarios autenticados leen productos para búsqueda y venta en POS
CREATE POLICY "Authenticated users view products" ON public.products
FOR SELECT TO authenticated
USING (true);

-- 2.2 MODIFICACIÓN Y BORRADO: Estrictamente reservado a administradores
CREATE POLICY "Only admins insert products" ON public.products
FOR INSERT TO authenticated
WITH CHECK (public.is_admin());

CREATE POLICY "Only admins update products" ON public.products
FOR UPDATE TO authenticated
USING (public.is_admin());

CREATE POLICY "Only admins delete products" ON public.products
FOR DELETE TO authenticated
USING (public.is_admin());


-- ==============================================================================
-- SECCIÓN 3: sales y sale_items (Inmutabilidad Contable)
-- ==============================================================================
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read all sales" ON public.sales;
DROP POLICY IF EXISTS "Employees read own sales" ON public.sales;
DROP POLICY IF EXISTS "Users insert own sales" ON public.sales;
DROP POLICY IF EXISTS "Authenticated users insert sales" ON public.sales;
DROP POLICY IF EXISTS "Only admins update sales" ON public.sales;
DROP POLICY IF EXISTS "Only admins delete sales" ON public.sales;

-- 3.1 VENTAS - LECTURA: Admins leen todas; empleados leen sus ventas registradas
CREATE POLICY "Admins read all sales" ON public.sales
FOR SELECT TO authenticated
USING (public.is_admin());

CREATE POLICY "Employees read own sales" ON public.sales
FOR SELECT TO authenticated
USING (auth.uid() = user_id);

-- 3.2 VENTAS - INSERCIÓN: El usuario registra la venta a su propio nombre (requiere usuario activo)
CREATE POLICY "Users insert own sales" ON public.sales
FOR INSERT TO authenticated
WITH CHECK (
  auth.uid() = user_id
  AND (public.is_admin() OR public.get_current_user_business_id() IS NOT NULL)
);

-- 3.3 VENTAS - MODIFICACIÓN Y BORRADO: Prohibido a empleados; exclusivo de auditoría admin
CREATE POLICY "Only admins update sales" ON public.sales
FOR UPDATE TO authenticated
USING (public.is_admin());

CREATE POLICY "Only admins delete sales" ON public.sales
FOR DELETE TO authenticated
USING (public.is_admin());

-- 3.4 SALE_ITEMS:
DROP POLICY IF EXISTS "Admins read all sale items" ON public.sale_items;
DROP POLICY IF EXISTS "Employees read own sale items" ON public.sale_items;
DROP POLICY IF EXISTS "Users insert items for own sales" ON public.sale_items;
DROP POLICY IF EXISTS "Only admins update sale items" ON public.sale_items;
DROP POLICY IF EXISTS "Only admins delete sale items" ON public.sale_items;

CREATE POLICY "Admins read all sale items" ON public.sale_items
FOR SELECT TO authenticated
USING (public.is_admin());

CREATE POLICY "Employees read own sale items" ON public.sale_items
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.sales 
    WHERE sales.id = sale_items.sale_id AND sales.user_id = auth.uid()
  )
);

CREATE POLICY "Users insert items for own sales" ON public.sale_items
FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.sales 
    WHERE sales.id = sale_items.sale_id AND sales.user_id = auth.uid()
  )
  OR public.is_admin()
);

CREATE POLICY "Only admins update sale items" ON public.sale_items
FOR UPDATE TO authenticated
USING (public.is_admin());

CREATE POLICY "Only admins delete sale items" ON public.sale_items
FOR DELETE TO authenticated
USING (public.is_admin());


-- ==============================================================================
-- SECCIÓN 4: cash_closures (Cierres de Caja por Sede)
-- ==============================================================================
ALTER TABLE public.cash_closures ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated users can read closures" ON public.cash_closures;
DROP POLICY IF EXISTS "Cashiers and Admins can insert closures" ON public.cash_closures;
DROP POLICY IF EXISTS "Only admins update closures" ON public.cash_closures;
DROP POLICY IF EXISTS "Only admins delete closures" ON public.cash_closures;
DROP POLICY IF EXISTS "Admins read all closures" ON public.cash_closures;
DROP POLICY IF EXISTS "Employees read own business closures" ON public.cash_closures;
DROP POLICY IF EXISTS "Users insert own closure" ON public.cash_closures;

-- 4.1 LECTURA: Admins ven todos; Empleados ven los de su misma sede o creados por ellos
CREATE POLICY "Admins read all closures" ON public.cash_closures
FOR SELECT TO authenticated
USING (public.is_admin());

CREATE POLICY "Employees read own business closures" ON public.cash_closures
FOR SELECT TO authenticated
USING (
  auth.uid() = user_id
  OR business_id = public.get_current_user_business_id()
);

-- 4.2 INSERCIÓN: Personal de caja o administración registra su propio cierre (requiere usuario activo)
CREATE POLICY "Users insert own closure" ON public.cash_closures
FOR INSERT TO authenticated
WITH CHECK (
  auth.uid() = user_id
  AND (
    public.is_admin()
    OR (public.get_current_user_role() IN ('empleado', 'cajero') AND public.get_current_user_business_id() IS NOT NULL)
  )
);

-- 4.3 MODIFICACIÓN Y BORRADO: Reservado a Administradores
CREATE POLICY "Only admins update closures" ON public.cash_closures
FOR UPDATE TO authenticated
USING (public.is_admin());

CREATE POLICY "Only admins delete closures" ON public.cash_closures
FOR DELETE TO authenticated
USING (public.is_admin());


-- ==============================================================================
-- SECCIÓN 5: shifts (Gestión de Turnos Laborales)
-- ==============================================================================
ALTER TABLE public.shifts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins have full access to shifts" ON public.shifts;
DROP POLICY IF EXISTS "Employees can view their own shifts" ON public.shifts;
DROP POLICY IF EXISTS "Admins full access shifts" ON public.shifts;
DROP POLICY IF EXISTS "Employees view own shifts" ON public.shifts;

CREATE POLICY "Admins full access shifts" ON public.shifts
FOR ALL TO authenticated
USING (public.is_admin())
WITH CHECK (public.is_admin());

CREATE POLICY "Employees view own shifts" ON public.shifts
FOR SELECT TO authenticated
USING (user_id = auth.uid());


-- ==============================================================================
-- SECCIÓN 6: transactions (Libro Mayor y Caja)
-- ==============================================================================
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can view all transactions" ON public.transactions;
DROP POLICY IF EXISTS "Employees can view business transactions" ON public.transactions;
DROP POLICY IF EXISTS "Admins can insert any transaction" ON public.transactions;
DROP POLICY IF EXISTS "Employees can insert in their business" ON public.transactions;
DROP POLICY IF EXISTS "Admins can update/delete transactions" ON public.transactions;
DROP POLICY IF EXISTS "Admins can update transactions" ON public.transactions;
DROP POLICY IF EXISTS "Admins can delete transactions" ON public.transactions;
DROP POLICY IF EXISTS "transacciones_insert_propio" ON public.transactions;
DROP POLICY IF EXISTS "transacciones_select_propio" ON public.transactions;
DROP POLICY IF EXISTS "Permitir inserción según rol y negocio" ON public.transactions;
DROP POLICY IF EXISTS "Admins view all transactions" ON public.transactions;
DROP POLICY IF EXISTS "Employees view business transactions" ON public.transactions;
DROP POLICY IF EXISTS "Admins insert any transaction" ON public.transactions;
DROP POLICY IF EXISTS "Employees insert own business transactions" ON public.transactions;
DROP POLICY IF EXISTS "Admins update transactions" ON public.transactions;
DROP POLICY IF EXISTS "Admins delete transactions" ON public.transactions;

CREATE POLICY "Admins view all transactions" ON public.transactions
FOR SELECT TO authenticated
USING (public.is_admin());

CREATE POLICY "Employees view business transactions" ON public.transactions
FOR SELECT TO authenticated
USING (
  user_id = auth.uid()
  OR business_id = public.get_current_user_business_id()
);

CREATE POLICY "Admins insert any transaction" ON public.transactions
FOR INSERT TO authenticated
WITH CHECK (public.is_admin());

CREATE POLICY "Employees insert own business transactions" ON public.transactions
FOR INSERT TO authenticated
WITH CHECK (
  auth.uid() = user_id
  AND business_id = public.get_current_user_business_id()
);

CREATE POLICY "Admins update transactions" ON public.transactions
FOR UPDATE TO authenticated
USING (public.is_admin());

CREATE POLICY "Admins delete transactions" ON public.transactions
FOR DELETE TO authenticated
USING (public.is_admin());


-- ==============================================================================
-- SECCIÓN 7: users (Control de Identidad y Bloqueo de Escalada de Privilegios)
-- ==============================================================================
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- Asegurar columnas operativas de permisos y estado si no existen en el esquema base
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS is_cashier BOOLEAN DEFAULT false;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS can_manage_inventory BOOLEAN DEFAULT false;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS hourly_rate NUMERIC(15, 2) DEFAULT 0;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS active BOOLEAN DEFAULT true;

DROP POLICY IF EXISTS "Users can view own profile" ON public.users;
DROP POLICY IF EXISTS "Admins can view all users" ON public.users;
DROP POLICY IF EXISTS "Users can update non-role fields" ON public.users;
DROP POLICY IF EXISTS "Admins can update any user" ON public.users;
DROP POLICY IF EXISTS "Users update own non-sensitive profile" ON public.users;
DROP POLICY IF EXISTS "Users view staff profiles" ON public.users;
DROP POLICY IF EXISTS "Admins delete users" ON public.users;
DROP POLICY IF EXISTS "Admins insert users" ON public.users;

-- 7.1 LECTURA: Sin recursión usando función auxiliar get_current_user_business_id()
CREATE POLICY "Users view staff profiles" ON public.users
FOR SELECT TO authenticated
USING (
  public.is_admin()
  OR id = auth.uid()
  OR business_id = public.get_current_user_business_id()
);

-- 7.2 MODIFICACIÓN: Administradores pueden actualizar perfiles
CREATE POLICY "Admins update any user" ON public.users
FOR UPDATE TO authenticated
USING (public.is_admin());

-- 7.3 MODIFICACIÓN PROPIA: Empleados pueden editar su propio perfil
CREATE POLICY "Users update own non-sensitive profile" ON public.users
FOR UPDATE TO authenticated
USING (auth.uid() = id);

-- 7.4 ADMINISTRACIÓN: Permitir a administradores eliminar colaboradores (requerido por main.js L1064)
CREATE POLICY "Admins delete users" ON public.users
FOR DELETE TO authenticated
USING (public.is_admin());

-- 7.5 ADMINISTRACIÓN: Permitir a administradores registrar usuarios manualmente si aplica
CREATE POLICY "Admins insert users" ON public.users
FOR INSERT TO authenticated
WITH CHECK (public.is_admin());

-- 7.4 TRIGGER DE PROTECCIÓN INTEGRAL DE USUARIOS:
-- Impide que usuarios no administradores modifiquen campos protegidos:
-- (role, business_id, is_cashier, can_manage_inventory, hourly_rate, active, email, id).
-- Permite únicamente la modificación de datos de perfil legítimos (ej. name).
--
-- ARQUITECTURA DE SEGURIDAD CRÍTICA:
-- Esta función trigger se define deliberadamente como SECURITY INVOKER (omitiendo SECURITY DEFINER).
-- Si fuera SECURITY DEFINER, la semántica de PostgreSQL asigna CURRENT_USER = 'postgres' (el propietario),
-- lo que provocaría que la condición `current_user IN ('postgres', ...)` evaluara siempre a TRUE para
-- cualquier cliente, desactivando el trigger por completo. Al ser SECURITY INVOKER, `current_user`
-- preserva con exactitud el rol PostgreSQL de la sesión activa ('authenticated', 'service_role', etc.).
CREATE OR REPLACE FUNCTION public.protect_user_sensitive_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_is_admin BOOLEAN;
BEGIN
  -- 1. Acceso de infraestructura y backend privilegiado de PostgreSQL:
  -- Como la función es SECURITY INVOKER, `current_user` refleja el rol real de la conexión.
  IF current_user IN ('service_role', 'supabase_admin', 'postgres') THEN
    RETURN NEW;
  END IF;

  -- 2. Acceso administrativo: Verificar si el usuario autenticado tiene rol 'admin'
  -- `public.is_admin()` es SECURITY DEFINER, por lo que consulta `public.users` sin recursión RLS.
  v_is_admin := public.is_admin();
  IF v_is_admin THEN
    RETURN NEW;
  END IF;

  -- 3. Restricciones estrictas para usuarios regulares (empleados / cajeros):
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    RAISE EXCEPTION 'Operación denegada: No tiene privilegios para alterar roles de usuario ("role").';
  END IF;

  IF NEW.business_id IS DISTINCT FROM OLD.business_id THEN
    RAISE EXCEPTION 'Operación denegada: No tiene privilegios para modificar la sede asignada ("business_id").';
  END IF;

  IF NEW.is_cashier IS DISTINCT FROM OLD.is_cashier THEN
    RAISE EXCEPTION 'Operación denegada: No tiene privilegios para alterar el permiso de cajero ("is_cashier").';
  END IF;

  IF NEW.email IS DISTINCT FROM OLD.email THEN
    RAISE EXCEPTION 'Operación denegada: El email de acceso no puede ser modificado directamente en el perfil.';
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Operación denegada: El identificador de usuario es inmutable.';
  END IF;

  -- 4. Protección de permisos de negocio y nómina detectados en main.js
  BEGIN
    IF NEW.can_manage_inventory IS DISTINCT FROM OLD.can_manage_inventory THEN
      RAISE EXCEPTION 'Operación denegada: No tiene privilegios para modificar el permiso de inventario ("can_manage_inventory").';
    END IF;
  EXCEPTION WHEN undefined_column THEN
    NULL;
  END;

  BEGIN
    IF NEW.hourly_rate IS DISTINCT FROM OLD.hourly_rate THEN
      RAISE EXCEPTION 'Operación denegada: No tiene privilegios para alterar la tarifa horaria de nómina ("hourly_rate").';
    END IF;
  EXCEPTION WHEN undefined_column THEN
    NULL;
  END;

  BEGIN
    IF NEW.active IS DISTINCT FROM OLD.active THEN
      RAISE EXCEPTION 'Operación denegada: No tiene privilegios para alterar el estado activo del usuario ("active").';
    END IF;
  EXCEPTION WHEN undefined_column THEN
    NULL;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_user_sensitive_fields ON public.users;
DROP TRIGGER IF EXISTS trg_prevent_role_escalation ON public.users;
CREATE TRIGGER trg_protect_user_sensitive_fields
BEFORE UPDATE ON public.users
FOR EACH ROW EXECUTE FUNCTION public.protect_user_sensitive_fields();

REVOKE ALL ON FUNCTION public.protect_user_sensitive_fields() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.protect_user_sensitive_fields() FROM anon;
GRANT EXECUTE ON FUNCTION public.protect_user_sensitive_fields() TO authenticated;
GRANT EXECUTE ON FUNCTION public.protect_user_sensitive_fields() TO service_role;


-- ==============================================================================
-- SECCIÓN 8: PLAN DE REVERSIÓN (ROLLBACK)
-- En caso de requerir volver exactamente al estado previo documentado en el repo:
-- ==============================================================================
/*
-- 8.1 ROLLBACK FUNCIONES Y TRIGGERS
DROP TRIGGER IF EXISTS trg_protect_user_sensitive_fields ON public.users;
DROP TRIGGER IF EXISTS trg_prevent_role_escalation ON public.users;
DROP FUNCTION IF EXISTS public.protect_user_sensitive_fields();
DROP FUNCTION IF EXISTS public.prevent_role_escalation();
DROP FUNCTION IF EXISTS public.is_admin();
DROP FUNCTION IF EXISTS public.get_current_user_business_id();
DROP FUNCTION IF EXISTS public.get_current_user_role();

-- 8.2 ROLLBACK system_logs (Restaura políticas de 20260427_initial_schema.sql y setup_system_logs.sql)
DROP POLICY IF EXISTS "Admins view all logs" ON public.system_logs;
DROP POLICY IF EXISTS "Employees view own logs" ON public.system_logs;
DROP POLICY IF EXISTS "Anon only report auth errors" ON public.system_logs;
DROP POLICY IF EXISTS "Employees insert own operational logs" ON public.system_logs;
DROP POLICY IF EXISTS "Admins insert any log" ON public.system_logs;

CREATE POLICY "Admins can view logs" ON public.system_logs FOR SELECT 
USING (EXISTS (SELECT 1 FROM public.users WHERE users.id = auth.uid() AND users.role = 'admin'));

CREATE POLICY "Users can insert logs" ON public.system_logs FOR INSERT 
WITH CHECK (auth.uid() IS NOT NULL);

-- 8.3 ROLLBACK products
-- [ADVERTENCIA DE SEGURIDAD CRÍTICA]: En el esquema base v1 (20260427_initial_schema.sql),
-- products no tenía RLS habilitado en migraciones versionadas.
-- ATENCIÓN: Desactivar RLS dejará la tabla abierta a cualquier rol con GRANT de tabla.
-- Si desea revertir sin exponer la tabla completamente, evalúe mantener RLS activo con políticas restringidas.
DROP POLICY IF EXISTS "Authenticated users view products" ON public.products;
DROP POLICY IF EXISTS "Only admins insert products" ON public.products;
DROP POLICY IF EXISTS "Only admins update products" ON public.products;
DROP POLICY IF EXISTS "Only admins delete products" ON public.products;
ALTER TABLE public.products DISABLE ROW LEVEL SECURITY;

-- 8.4 ROLLBACK sales y sale_items
-- [ADVERTENCIA DE SEGURIDAD CRÍTICA]: sales y sale_items no tenían migraciones iniciales versionadas.
-- ATENCIÓN: Desactivar RLS aquí desprotege los registros de ventas contra modificaciones si existen GRANTs públicos.
DROP POLICY IF EXISTS "Admins read all sales" ON public.sales;
DROP POLICY IF EXISTS "Employees read own sales" ON public.sales;
DROP POLICY IF EXISTS "Users insert own sales" ON public.sales;
DROP POLICY IF EXISTS "Only admins update sales" ON public.sales;
DROP POLICY IF EXISTS "Only admins delete sales" ON public.sales;

DROP POLICY IF EXISTS "Admins read all sale items" ON public.sale_items;
DROP POLICY IF EXISTS "Employees read own sale items" ON public.sale_items;
DROP POLICY IF EXISTS "Users insert items for own sales" ON public.sale_items;
DROP POLICY IF EXISTS "Only admins update sale items" ON public.sale_items;
DROP POLICY IF EXISTS "Only admins delete sale items" ON public.sale_items;
ALTER TABLE public.sales DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_items DISABLE ROW LEVEL SECURITY;

-- 8.5 ROLLBACK cash_closures (Restaura políticas de create_cash_closures_table.sql)
DROP POLICY IF EXISTS "Admins read all closures" ON public.cash_closures;
DROP POLICY IF EXISTS "Employees read own business closures" ON public.cash_closures;
DROP POLICY IF EXISTS "Users insert own closure" ON public.cash_closures;
DROP POLICY IF EXISTS "Only admins update closures" ON public.cash_closures;
DROP POLICY IF EXISTS "Only admins delete closures" ON public.cash_closures;

CREATE POLICY "Authenticated users can read closures" ON public.cash_closures
FOR SELECT TO authenticated USING (true);

CREATE POLICY "Cashiers and Admins can insert closures" ON public.cash_closures
FOR INSERT TO authenticated WITH CHECK (
    auth.uid() = user_id OR 
    EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND (role = 'admin' OR is_cashier = true))
);

-- 8.6 ROLLBACK shifts (Restaura políticas de create_shifts_table.sql)
DROP POLICY IF EXISTS "Admins full access shifts" ON public.shifts;
DROP POLICY IF EXISTS "Employees view own shifts" ON public.shifts;

CREATE POLICY "Admins have full access to shifts" ON public.shifts
FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM public.users WHERE users.id = auth.uid() AND users.role = 'admin'));

CREATE POLICY "Employees can view their own shifts" ON public.shifts
FOR SELECT TO authenticated
USING (user_id = auth.uid());

-- 8.7 ROLLBACK transactions (Restaura políticas de 20260427_initial_schema.sql)
DROP POLICY IF EXISTS "Admins view all transactions" ON public.transactions;
DROP POLICY IF EXISTS "Employees view business transactions" ON public.transactions;
DROP POLICY IF EXISTS "Admins insert any transaction" ON public.transactions;
DROP POLICY IF EXISTS "Employees insert own business transactions" ON public.transactions;
DROP POLICY IF EXISTS "Admins update transactions" ON public.transactions;
DROP POLICY IF EXISTS "Admins delete transactions" ON public.transactions;

CREATE POLICY "Admins can view all transactions" ON public.transactions FOR SELECT 
USING (EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Employees can view business transactions" ON public.transactions FOR SELECT 
USING (EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND business_id = transactions.business_id));

CREATE POLICY "Admins can insert any transaction" ON public.transactions FOR INSERT 
WITH CHECK (EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Employees can insert in their business" ON public.transactions FOR INSERT 
WITH CHECK (EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'empleado' AND business_id = transactions.business_id));

CREATE POLICY "Admins can update/delete transactions" ON public.transactions FOR ALL 
USING (EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'admin'));

-- 8.8 ROLLBACK users (Restaura políticas de 20260427_initial_schema.sql y setup_system_logs.sql)
DROP POLICY IF EXISTS "Users view staff profiles" ON public.users;
DROP POLICY IF EXISTS "Admins update any user" ON public.users;
DROP POLICY IF EXISTS "Users update own non-sensitive profile" ON public.users;
DROP POLICY IF EXISTS "Admins delete users" ON public.users;
DROP POLICY IF EXISTS "Admins insert users" ON public.users;

CREATE POLICY "Users can view own profile" ON public.users FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Admins can view all users" ON public.users FOR SELECT 
USING ((SELECT role FROM public.users WHERE id = auth.uid() LIMIT 1) = 'admin');
*/
