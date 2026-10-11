import { describe, it, expect } from 'vitest';

/**
 * Suite de Validación Funcional de Políticas RLS Corregidas
 * Simula y evalúa las reglas exactas codificadas en supabase/migrations/20260429_harden_rls_policies.sql
 * de acuerdo con los requerimientos de autorización sin conectarse a producción.
 */

// Entorno de prueba mock
const ADMIN_ID = '00000000-0000-0000-0000-000000000001';
const EMP1_ID = '00000000-0000-0000-0000-000000000002'; // Empleado Sede 1
const EMP1_PEER_ID = '00000000-0000-0000-0000-000000000004'; // Compañero Sede 1
const EMP2_ID = '00000000-0000-0000-0000-000000000003'; // Empleado Sede 2

const BIZ1_ID = '11111111-1111-1111-1111-111111111111';
const BIZ2_ID = '22222222-2222-2222-2222-222222222222';

const INACTIVE_EMP_ID = '00000000-0000-0000-0000-000000000005'; // Empleado desvinculado

const usersDb = [
  { id: ADMIN_ID, role: 'admin', business_id: BIZ1_ID, is_cashier: false, active: true },
  { id: EMP1_ID, role: 'empleado', business_id: BIZ1_ID, is_cashier: true, active: true },
  { id: EMP1_PEER_ID, role: 'empleado', business_id: BIZ1_ID, is_cashier: false, active: true },
  { id: EMP2_ID, role: 'empleado', business_id: BIZ2_ID, is_cashier: false, active: true },
  { id: INACTIVE_EMP_ID, role: 'empleado', business_id: BIZ1_ID, is_cashier: true, active: false },
];

// Helper Functions equivalentes a las de PostgreSQL con SECURITY DEFINER
const getUser = (authUid) => usersDb.find(u => u.id === authUid) || null;
const is_admin = (authUid) => {
  const u = getUser(authUid);
  return u?.role === 'admin' && (u.active === undefined || u.active === true);
};
const get_current_user_business_id = (authUid) => {
  const u = getUser(authUid);
  return (u?.active === undefined || u.active === true) ? (u?.business_id || null) : null;
};
const get_current_user_role = (authUid) => {
  const u = getUser(authUid);
  return (u?.active === undefined || u.active === true) ? (u?.role || null) : null;
};

// Evaluadores de Políticas RLS Corregidas
const RlsEvaluator = {
  // --- SYSTEM LOGS ---
  canInsertLog: (authUid, log) => {
    if (!authUid) {
      return log.module === 'auth' && 
             ['error', 'Auth Error'].includes(log.type) && 
             log.user_id === null;
    }
    if (is_admin(authUid)) return true;

    const reserved = ['TELEGRAM_CONFIG', 'PURGE_EVENT', 'SUPPLIER_RECORD', 'GEOFENCE_POLYGON'];
    return log.user_id === authUid && !reserved.includes(log.type);
  },

  // --- BUSINESSES (Aislamiento de Sedes) ---
  canSelectBusiness: (authUid, business) => {
    if (!authUid) return false;
    if (is_admin(authUid)) return true;
    return business.id === get_current_user_business_id(authUid);
  },
  canModifyBusiness: (authUid) => {
    if (!authUid) return false;
    return is_admin(authUid);
  },

  // --- PRODUCTS (Catálogo POS para Clúster) ---
  canSelectProduct: (authUid, product) => {
    // Lectura abierta para todo usuario autenticado para poder vender en POS
    return Boolean(authUid);
  },

  canUpdateProduct: (authUid) => {
    return is_admin(authUid);
  },

  // --- SALES & SALE_ITEMS ---
  canInsertSale: (authUid, sale) => {
    if (!authUid) return false;
    const isAuthorized = is_admin(authUid) || Boolean(get_current_user_business_id(authUid));
    return sale.user_id === authUid && isAuthorized;
  },

  canInsertSaleItem: (authUid, saleItem, existingSales) => {
    if (!authUid) return false;
    if (is_admin(authUid)) return true;
    const parentSale = existingSales.find(s => s.id === saleItem.sale_id);
    return parentSale && parentSale.user_id === authUid;
  },

  canUpdateOrDeleteSale: (authUid) => {
    return is_admin(authUid);
  },

  // --- CASH CLOSURES ---
  canSelectCashClosure: (authUid, closure) => {
    if (!authUid) return false;
    if (is_admin(authUid)) return true;
    return closure.user_id === authUid || get_current_user_business_id(authUid) === closure.business_id;
  },

  canInsertCashClosure: (authUid, closure) => {
    if (!authUid) return false;
    const role = get_current_user_role(authUid);
    const authorizedRole = is_admin(authUid) || ['empleado', 'cajero'].includes(role);
    return closure.user_id === authUid && authorizedRole;
  },

  // --- USERS SELECT (Sin Recursión) ---
  canSelectStaffUser: (authUid, targetUser) => {
    if (!authUid) return false;
    if (is_admin(authUid)) return true;
    if (targetUser.id === authUid) return true;
    // Visibilidad de compañeros de su misma sede sin subconsultas recursivas
    return targetUser.business_id === get_current_user_business_id(authUid);
  },

  canDeleteUser: (authUid) => {
    return is_admin(authUid);
  },

  canInsertUser: (authUid) => {
    return is_admin(authUid);
  },

  // --- USERS (Trigger protect_user_sensitive_fields) ---
  evaluateUserFieldsProtectionTrigger: (authUid, oldRow, newRow, jwtRole = '', pgRole = 'authenticated') => {
    // 1. Acceso de infraestructura: PostgreSQL roles confiables
    if (['service_role', 'supabase_admin', 'postgres'].includes(pgRole)) return true;

    // 2. service_role bypass únicamente si el rol PostgreSQL de la sesión NO es 'authenticated' ni 'anon'
    if (!['authenticated', 'anon'].includes(pgRole) && jwtRole === 'service_role') return true;

    // 3. admin bypass
    if (is_admin(authUid)) return true;

    // 3. Validar campos protegidos para usuarios regulares:
    if (newRow.role !== oldRow.role) {
      throw new Error('Operación denegada: No tiene privilegios para alterar roles de usuario ("role").');
    }
    if (newRow.business_id !== oldRow.business_id) {
      throw new Error('Operación denegada: No tiene privilegios para modificar la sede asignada ("business_id").');
    }
    if (newRow.is_cashier !== oldRow.is_cashier) {
      throw new Error('Operación denegada: No tiene privilegios para alterar el permiso de cajero ("is_cashier").');
    }
    if (newRow.email !== oldRow.email) {
      throw new Error('Operación denegada: El email de acceso no puede ser modificado directamente en el perfil.');
    }
    if (newRow.id !== oldRow.id) {
      throw new Error('Operación denegada: El identificador de usuario es inmutable.');
    }
    if (newRow.can_manage_inventory !== oldRow.can_manage_inventory) {
      throw new Error('Operación denegada: No tiene privilegios para modificar el permiso de inventario ("can_manage_inventory").');
    }
    if (newRow.hourly_rate !== oldRow.hourly_rate) {
      throw new Error('Operación denegada: No tiene privilegios para alterar la tarifa horaria de nómina ("hourly_rate").');
    }
    if (newRow.active !== oldRow.active) {
      throw new Error('Operación denegada: No tiene privilegios para alterar el estado activo del usuario ("active").');
    }

    return true; // Si solo cambia name u otros campos permitidos
  }
};

describe('Validación Funcional RLS Corregida (Local Simulation)', () => {

  it('1. Un administrador puede realizar las operaciones administrativas legítimas', () => {
    const adminLog = { module: 'sistema', type: 'TELEGRAM_CONFIG', user_id: ADMIN_ID };
    expect(RlsEvaluator.canInsertLog(ADMIN_ID, adminLog)).toBe(true);

    expect(RlsEvaluator.canUpdateProduct(ADMIN_ID)).toBe(true);
    expect(RlsEvaluator.canUpdateOrDeleteSale(ADMIN_ID)).toBe(true);

    const closureBiz2 = { user_id: EMP2_ID, business_id: BIZ2_ID };
    expect(RlsEvaluator.canSelectCashClosure(ADMIN_ID, closureBiz2)).toBe(true);

    // Admin puede cambiar el rol, sede, cajero y nómina de un usuario (Pruebas positivas)
    const oldEmp = { id: EMP1_ID, name: 'Juan', email: 'juan@jm.com', role: 'empleado', business_id: BIZ1_ID, is_cashier: false, can_manage_inventory: false, hourly_rate: 6000, active: true };
    const adminUpdatedEmp = { id: EMP1_ID, name: 'Juan', email: 'juan@jm.com', role: 'admin', business_id: BIZ2_ID, is_cashier: true, can_manage_inventory: true, hourly_rate: 8000, active: true };
    expect(RlsEvaluator.evaluateUserFieldsProtectionTrigger(ADMIN_ID, oldEmp, adminUpdatedEmp)).toBe(true);

    // Admin puede eliminar colaboradores (main.js L1064)
    expect(RlsEvaluator.canDeleteUser(ADMIN_ID)).toBe(true);
    expect(RlsEvaluator.canDeleteUser(EMP1_ID)).toBe(false);

    // Admin puede insertar usuarios
    expect(RlsEvaluator.canInsertUser(ADMIN_ID)).toBe(true);
    expect(RlsEvaluator.canInsertUser(EMP1_ID)).toBe(false);

    // service_role de infraestructura también puede actualizar campos protegidos (backend / auth hook)
    expect(RlsEvaluator.evaluateUserFieldsProtectionTrigger(null, oldEmp, adminUpdatedEmp, 'service_role', 'service_role')).toBe(true);

    // Un usuario con rol 'authenticated' que intente falsear jwtRole='service_role' debe ser bloqueado
    expect(() => {
      RlsEvaluator.evaluateUserFieldsProtectionTrigger(EMP1_ID, oldEmp, adminUpdatedEmp, 'service_role', 'authenticated');
    }).toThrow(/privilegios para alterar roles/);
  });

  it('2. Un empleado puede consultar el catálogo compartido (Clúster) y registrar ventas autorizadas', () => {
    // Producto de sede 1
    expect(RlsEvaluator.canSelectProduct(EMP1_ID, { id: 'p1', business_id: BIZ1_ID })).toBe(true);
    // Producto de sede 2 (compartido en clúster POS)
    expect(RlsEvaluator.canSelectProduct(EMP1_ID, { id: 'p2', business_id: BIZ2_ID })).toBe(true);

    const sale = { id: 'sale-1', user_id: EMP1_ID, total: 100000 };
    expect(RlsEvaluator.canInsertSale(EMP1_ID, sale)).toBe(true);

    const existingSales = [sale];
    const saleItem = { id: 'item-1', sale_id: 'sale-1', product_id: 'p1', quantity: 1 };
    expect(RlsEvaluator.canInsertSaleItem(EMP1_ID, saleItem, existingSales)).toBe(true);
  });

  it('3. Un empleado NO puede cambiar precios, modificar ventas ajenas ni alterar campos sensibles de usuario', () => {
    expect(RlsEvaluator.canUpdateProduct(EMP1_ID)).toBe(false);
    expect(RlsEvaluator.canUpdateOrDeleteSale(EMP1_ID)).toBe(false);

    const foreignSale = { id: 'sale-foreign', user_id: EMP2_ID, total: 50000 };
    const maliciousItem = { id: 'item-malicious', sale_id: 'sale-foreign', product_id: 'p1' };
    expect(RlsEvaluator.canInsertSaleItem(EMP1_ID, maliciousItem, [foreignSale])).toBe(false);

    const baseEmp = { id: EMP1_ID, name: 'Juan', email: 'juan@jm.com', role: 'empleado', business_id: BIZ1_ID, is_cashier: false, can_manage_inventory: false, hourly_rate: 6000, active: true };

    // PRUEBAS NEGATIVAS PARA CAMPOS SENSIBLES:
    // a. Intento de auto-escalar rol -> Denegado
    expect(() => {
      RlsEvaluator.evaluateUserFieldsProtectionTrigger(EMP1_ID, baseEmp, { ...baseEmp, role: 'admin' });
    }).toThrow(/privilegios para alterar roles/);

    // b. Intento de cambiar su sede (business_id) -> Denegado
    expect(() => {
      RlsEvaluator.evaluateUserFieldsProtectionTrigger(EMP1_ID, baseEmp, { ...baseEmp, business_id: BIZ2_ID });
    }).toThrow(/privilegios para modificar la sede asignada/);

    // c. Intento de auto-otorgarse permiso de cajero (is_cashier) -> Denegado
    expect(() => {
      RlsEvaluator.evaluateUserFieldsProtectionTrigger(EMP1_ID, baseEmp, { ...baseEmp, is_cashier: true });
    }).toThrow(/privilegios para alterar el permiso de cajero/);

    // d. Intento de modificar email -> Denegado
    expect(() => {
      RlsEvaluator.evaluateUserFieldsProtectionTrigger(EMP1_ID, baseEmp, { ...baseEmp, email: 'hacker@mail.com' });
    }).toThrow(/email de acceso no puede ser modificado/);

    // e. Intento de cambiar id -> Denegado
    expect(() => {
      RlsEvaluator.evaluateUserFieldsProtectionTrigger(EMP1_ID, baseEmp, { ...baseEmp, id: EMP2_ID });
    }).toThrow(/identificador de usuario es inmutable/);

    // f. Intento de autoasignarse permiso de inventario -> Denegado
    expect(() => {
      RlsEvaluator.evaluateUserFieldsProtectionTrigger(EMP1_ID, baseEmp, { ...baseEmp, can_manage_inventory: true });
    }).toThrow(/permiso de inventario/);

    // g. Intento de alterar su tarifa salarial horaria -> Denegado
    expect(() => {
      RlsEvaluator.evaluateUserFieldsProtectionTrigger(EMP1_ID, baseEmp, { ...baseEmp, hourly_rate: 15000 });
    }).toThrow(/tarifa horaria de nómina/);

    // h. Intento de reactivarse si está inactivo -> Denegado
    expect(() => {
      const inactiveEmp = { ...baseEmp, active: false };
      RlsEvaluator.evaluateUserFieldsProtectionTrigger(EMP1_ID, inactiveEmp, { ...inactiveEmp, active: true });
    }).toThrow(/estado activo del usuario/);

    // PRUEBA POSITIVA: Empleado modificando su propio nombre permitido -> Permitido
    expect(RlsEvaluator.evaluateUserFieldsProtectionTrigger(EMP1_ID, baseEmp, { ...baseEmp, name: 'Juan Carlos' })).toBe(true);
  });

  it('4. Consulta de usuarios sin recursión: Empleado ve compañeros de su sede pero no de otras', () => {
    const peerInSameBiz = usersDb.find(u => u.id === EMP1_PEER_ID);
    const workerInOtherBiz = usersDb.find(u => u.id === EMP2_ID);

    // Empleado 1 ve a su compañero de sede 1 (para nombres en arqueos de caja)
    expect(RlsEvaluator.canSelectStaffUser(EMP1_ID, peerInSameBiz)).toBe(true);

    // Empleado 1 NO ve usuarios de sede 2
    expect(RlsEvaluator.canSelectStaffUser(EMP1_ID, workerInOtherBiz)).toBe(false);

    // Administrador ve a todos los usuarios
    expect(RlsEvaluator.canSelectStaffUser(ADMIN_ID, workerInOtherBiz)).toBe(true);
  });

  it('5. Un usuario anónimo NO puede insertar configuraciones privilegiadas en system_logs', () => {
    const anonPrivilegedLog = { module: 'sistema', type: 'TELEGRAM_CONFIG', user_id: null };
    expect(RlsEvaluator.canInsertLog(null, anonPrivilegedLog)).toBe(false);

    const anonNormalLog = { module: 'byod', type: 'SECURITY_ALERT', user_id: null };
    expect(RlsEvaluator.canInsertLog(null, anonNormalLog)).toBe(false);

    const anonAuthError = { module: 'auth', type: 'error', user_id: null };
    expect(RlsEvaluator.canInsertLog(null, anonAuthError)).toBe(true);
  });

  it('6. Un empleado NO puede consultar cierres de caja de otro negocio', () => {
    const closureBiz1 = { id: 'c1', user_id: EMP1_ID, business_id: BIZ1_ID };
    expect(RlsEvaluator.canSelectCashClosure(EMP1_ID, closureBiz1)).toBe(true);

    const closureBiz2 = { id: 'c2', user_id: EMP2_ID, business_id: BIZ2_ID };
    expect(RlsEvaluator.canSelectCashClosure(EMP1_ID, closureBiz2)).toBe(false);
  });

  it('7. Una cuenta desactivada (active = false) queda bloqueada en RLS para insertar ventas o cierres', () => {
    // get_current_user_business_id retorna null para usuario inactivo
    expect(get_current_user_business_id(INACTIVE_EMP_ID)).toBe(null);

    // Intento de insertar venta por colaborador inactivo -> Denegado en RLS
    const sale = { id: 'sale-inactive', user_id: INACTIVE_EMP_ID, total: 50000 };
    expect(RlsEvaluator.canInsertSale(INACTIVE_EMP_ID, sale)).toBe(false);

    // Intento de registrar cierre por colaborador inactivo -> Denegado en RLS
    const closure = { id: 'close-inactive', user_id: INACTIVE_EMP_ID, business_id: BIZ1_ID };
    expect(RlsEvaluator.canInsertCashClosure(INACTIVE_EMP_ID, closure)).toBe(false);
  });

  it('8. Aislamiento Multi-Tenant de Sedes (businesses): Empleados solo leen su negocio y no pueden mutar sedes', () => {
    const biz1 = { id: BIZ1_ID, name: 'SurtiHogar Sede 1' };
    const biz2 = { id: BIZ2_ID, name: 'SurtiHogar Sede 2' };

    // SELECT: Empleado de Sede 1 solo puede consultar su propia sede
    expect(RlsEvaluator.canSelectBusiness(EMP1_ID, biz1)).toBe(true);
    expect(RlsEvaluator.canSelectBusiness(EMP1_ID, biz2)).toBe(false);

    // SELECT: Administrador consulta todas las sedes
    expect(RlsEvaluator.canSelectBusiness(ADMIN_ID, biz1)).toBe(true);
    expect(RlsEvaluator.canSelectBusiness(ADMIN_ID, biz2)).toBe(true);

    // SELECT: Usuario inactivo no puede consultar sedes
    expect(RlsEvaluator.canSelectBusiness(INACTIVE_EMP_ID, biz1)).toBe(false);

    // MUTACIÓN: Empleado no puede insertar, actualizar ni borrar sedes ajenas o propias
    expect(RlsEvaluator.canModifyBusiness(EMP1_ID)).toBe(false);

    // MUTACIÓN: Administrador tiene autorización completa de gestión de sedes
    expect(RlsEvaluator.canModifyBusiness(ADMIN_ID)).toBe(true);
  });

});
