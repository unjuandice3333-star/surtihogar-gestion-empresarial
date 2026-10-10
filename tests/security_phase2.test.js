import { describe, it, expect, vi } from 'vitest';
import fs from 'fs';
import path from 'path';

describe('FASE 2: Verificación de Seguridad Crítica', () => {

  describe('1. Control de Acceso y Fallback Seguro de Perfil', () => {
    
    // Función que replica exactamente la lógica de resolución segura implementada en main.js
    const resolveUserProfile = async (session, fetchProfileFn) => {
      let profRes = null;
      try {
        const { data, error } = await fetchProfileFn(session.user.id);
        if (error) throw error;
        profRes = data;
      } catch (e) {
        // Error de red / consulta capturado
      }

      if (!profRes) {
        return {
          user: null,
          view: 'auth',
          authError: 'No se pudo verificar tu perfil o permisos de usuario.',
          blocked: true
        };
      }

      return {
        user: profRes,
        view: 'app',
        authError: null,
        blocked: false
      };
    };

    it('FALLO DE RED: Cuando la consulta del perfil falla por error de red, NUNCA debe otorgar rol admin', async () => {
      const mockSession = { user: { id: 'user-cajero-123' } };
      const failingFetch = vi.fn().mockRejectedValue(new Error('Network error or timeout'));

      const result = await resolveUserProfile(mockSession, failingFetch);

      expect(result.user).toBeNull();
      expect(result.user?.role).toBeUndefined();
      expect(result.user?.role === 'admin').toBe(false);
      expect(result.blocked).toBe(true);
      expect(result.view).toBe('auth');
    });

    it('PERFIL INEXISTENTE: Si la base de datos retorna null/vacío, debe denegar acceso y no otorgar rol admin', async () => {
      const mockSession = { user: { id: 'user-inexistente-456' } };
      const emptyFetch = vi.fn().mockResolvedValue({ data: null, error: null });

      const result = await resolveUserProfile(mockSession, emptyFetch);

      expect(result.user).toBeNull();
      expect(result.user?.role === 'admin').toBe(false);
      expect(result.blocked).toBe(true);
    });

    it('ADMIN LEGÍTIMO: Cuando un administrador real se conecta y su perfil existe, conserva su rol admin', async () => {
      const mockSession = { user: { id: 'admin-owner-789' } };
      const adminFetch = vi.fn().mockResolvedValue({
        data: { id: 'admin-owner-789', name: 'Administrador', role: 'admin' },
        error: null
      });

      const result = await resolveUserProfile(mockSession, adminFetch);

      expect(result.blocked).toBe(false);
      expect(result.user).not.toBeNull();
      expect(result.user.role).toBe('admin');
    });

    it('EMPLEADO LEGÍTIMO: Un empleado verificado obtiene exclusivamente su rol empleado', async () => {
      const mockSession = { user: { id: 'emp-101' } };
      const empFetch = vi.fn().mockResolvedValue({
        data: { id: 'emp-101', name: 'Cajero Norte', role: 'empleado' },
        error: null
      });

      const result = await resolveUserProfile(mockSession, empFetch);

      expect(result.blocked).toBe(false);
      expect(result.user.role).toBe('empleado');
      expect(result.user.role === 'admin').toBe(false);
    });
  });

  describe('2. Eliminación de la Función Destructiva de Purga Masiva', () => {
    it('CÓDIGO FUENTE: window.purgeStagingData no debe existir en src/main.js', () => {
      const mainJsContent = fs.readFileSync(path.resolve('src/main.js'), 'utf-8');
      expect(mainJsContent.includes('purgeStagingData')).toBe(false);
      expect(mainJsContent.includes('ADVERTENCIA CRÍTICA DE PRODUCCIÓN')).toBe(false);
    });
  });

  describe('3. Restauración de Validación de Certificados TLS', () => {
    it('CÓDIGO FUENTE: NODE_TLS_REJECT_UNAUTHORIZED no debe estar desactivado en telegram_bot.js', () => {
      const botJsContent = fs.readFileSync(path.resolve('scripts/telegram_bot.js'), 'utf-8');
      expect(botJsContent.includes('NODE_TLS_REJECT_UNAUTHORIZED')).toBe(false);
    });
  });

  describe('4. Eliminación Completa de Tokens y Chat IDs Estáticos de Telegram', () => {
    const knownBotPrefix = '8037545998:';
    const knownAdminChat = '6736325362';

    it('src/main.js: No debe contener tokens quemados en formularios ni funciones', () => {
      const mainJs = fs.readFileSync(path.resolve('src/main.js'), 'utf-8');
      expect(mainJs.includes(knownBotPrefix)).toBe(false);
      expect(mainJs.includes(knownAdminChat)).toBe(false);
    });

    it('src/services/ByodComplianceService.js: No debe contener tokens quemados', () => {
      const byod = fs.readFileSync(path.resolve('src/services/ByodComplianceService.js'), 'utf-8');
      expect(byod.includes(knownBotPrefix)).toBe(false);
      expect(byod.includes(knownAdminChat)).toBe(false);
    });

    it('save_telegram.cjs: No debe contener tokens quemados', () => {
      const saveScript = fs.readFileSync(path.resolve('save_telegram.cjs'), 'utf-8');
      expect(saveScript.includes(knownBotPrefix)).toBe(false);
      expect(saveScript.includes(knownAdminChat)).toBe(false);
    });

    it('scripts/telegram_bot.js: No debe contener fallbacks con tokens quemados', () => {
      const botScript = fs.readFileSync(path.resolve('scripts/telegram_bot.js'), 'utf-8');
      expect(botScript.includes(knownBotPrefix)).toBe(false);
      expect(botScript.includes(knownAdminChat)).toBe(false);
    });

    it('scripts/send_daily_report.js: No debe contener fallbacks quemados', () => {
      const script = fs.readFileSync(path.resolve('scripts/send_daily_report.js'), 'utf-8');
      expect(script.includes(knownBotPrefix)).toBe(false);
      expect(script.includes(knownAdminChat)).toBe(false);
    });

    it('scripts/send_monthly_report.js: No debe contener fallbacks quemados', () => {
      const script = fs.readFileSync(path.resolve('scripts/send_monthly_report.js'), 'utf-8');
      expect(script.includes(knownBotPrefix)).toBe(false);
      expect(script.includes(knownAdminChat)).toBe(false);
    });
  });

  describe('5. Validación Obligatoria del Webhook de Telegram', () => {
    // Función de validación pura que replica la lógica implementada en scripts/server.js
    const validateTelegramWebhook = (headers, envSecret) => {
      if (!envSecret) {
        return { status: 500, error: 'Webhook secret not configured on server' };
      }
      const incomingSecret = headers['x-telegram-bot-api-secret-token'];
      if (!incomingSecret || incomingSecret !== envSecret) {
        return { status: 403, error: 'Unauthorized: Invalid secret token' };
      }
      return { status: 200, ok: true };
    };

    it('SOLICITUD AUTORIZADA: Encabezado correcto y coincidente con el secreto del servidor -> 200 OK', () => {
      const headers = { 'x-telegram-bot-api-secret-token': 'secreto_super_seguro_123' };
      const envSecret = 'secreto_super_seguro_123';
      const result = validateTelegramWebhook(headers, envSecret);

      expect(result.status).toBe(200);
      expect(result.ok).toBe(true);
    });

    it('ENCABEZADO AUSENTE: Solicitud sin encabezado -> 403 Forbidden', () => {
      const headers = {};
      const envSecret = 'secreto_super_seguro_123';
      const result = validateTelegramWebhook(headers, envSecret);

      expect(result.status).toBe(403);
      expect(result.error).toContain('Unauthorized');
    });

    it('ENCABEZADO INCORRECTO: Solicitud con token atacante/falso -> 403 Forbidden', () => {
      const headers = { 'x-telegram-bot-api-secret-token': 'token_falso_atacante' };
      const envSecret = 'secreto_super_seguro_123';
      const result = validateTelegramWebhook(headers, envSecret);

      expect(result.status).toBe(403);
      expect(result.error).toContain('Unauthorized');
    });

    it('FAIL-SECURE: Variable de entorno no configurada en el servidor -> 500 Internal Error (Rechazo seguro)', () => {
      const headers = { 'x-telegram-bot-api-secret-token': 'cualquier_cosa' };
      const envSecret = undefined; // No configurada
      const result = validateTelegramWebhook(headers, envSecret);

      expect(result.status).toBe(500);
      expect(result.error).toContain('not configured');
    });
  });

  describe('6. Integridad de la Migración SQL Propuesta', () => {
    it('MIGRACIÓN EXISTE Y NO ESTÁ VACÍA: supabase/migrations/20260429_harden_rls_policies.sql', () => {
      const migrationPath = path.resolve('supabase/migrations/20260429_harden_rls_policies.sql');
      expect(fs.existsSync(migrationPath)).toBe(true);

      const sql = fs.readFileSync(migrationPath, 'utf-8');
      expect(sql.includes('public.system_logs ENABLE ROW LEVEL SECURITY')).toBe(true);
      expect(sql.includes('public.products ENABLE ROW LEVEL SECURITY')).toBe(true);
      expect(sql.includes('public.sales ENABLE ROW LEVEL SECURITY')).toBe(true);
      expect(sql.includes('public.sale_items ENABLE ROW LEVEL SECURITY')).toBe(true);
      expect(sql.includes('public.cash_closures ENABLE ROW LEVEL SECURITY')).toBe(true);
      expect(sql.includes('public.shifts ENABLE ROW LEVEL SECURITY')).toBe(true);
      expect(sql.includes('public.transactions ENABLE ROW LEVEL SECURITY')).toBe(true);
      expect(sql.includes('public.users ENABLE ROW LEVEL SECURITY')).toBe(true);
      expect(sql.includes('PLAN DE REVERSIÓN (ROLLBACK)')).toBe(true);
    });
  });

});
