# SurtiHogar / J&M — Sistema de Gestión Multi-Negocio, POS & Control Financiero

[![Vite](https://img.shields.io/badge/Vite-8.0-646CFF?style=flat&logo=vite&logoColor=white)](https://vitejs.dev/)
[![JavaScript](https://img.shields.io/badge/JavaScript-ESModules-F7DF1E?style=flat&logo=javascript&logoColor=black)](https://developer.mozilla.org/es/docs/Web/JavaScript)
[![Supabase](https://img.shields.io/badge/Supabase-PostgreSQL%20%2B%20RLS-3ECF8E?style=flat&logo=supabase&logoColor=white)](https://supabase.com/)
[![Capacitor](https://img.shields.io/badge/Capacitor-8.3%20Mobile-119EFF?style=flat&logo=capacitor&logoColor=white)](https://capacitorjs.com/)
[![Vitest](https://img.shields.io/badge/Tests-68%20Passed-4EAA25?style=flat&logo=vitest&logoColor=white)](https://vitest.dev/)
[![License](https://img.shields.io/badge/License-Proprietary%20%2F%20Portfolio-blue.svg)](#licencia)

Plataforma integral de punto de venta (POS), gestión de inventarios multi-sede, control financiero con cuadres de caja y auditoría laboral georreferenciada (BYOD). Diseñada con arquitectura desacoplada para operar como Single Page Application (SPA) web responsiva y aplicación móvil híbrida (Android/iOS) con sincronización en tiempo real sobre PostgreSQL y políticas estrictas de seguridad a nivel de fila (Row-Level Security).

---

## 🏛️ Arquitectura del Sistema

```
                      ┌───────────────────────────────────────────────┐
                      │             CLIENTES DE USUARIO               │
                      │   Web SPA (Vite)  /  Móvil Híbrido (Capacitor) │
                      └───────┬───────────────────────────────┬───────┘
                              │                               │
                 HTTPS / WSS  │                  GPS / BYOD   │ Capacitor Geolocation
                              ▼                               ▼
                      ┌───────────────────────────────────────────────┐
                      │              SUPABASE BACKEND                 │
                      │  - PostgreSQL 15+                             │
                      │  - Row Level Security (Multi-tenant RLS)      │
                      │  - Triggers de Integridad (SECURITY INVOKER) │
                      │  - Supabase Auth (JWT & Roles)                │
                      └───────▲───────────────────────────────▲───────┘
                              │                               │
                   SQL / API  │                   Alertas     │ HTTPS Cron
                              │                               │
                      ┌───────┴───────────────────────────────┴───────┐
                      │           MICROSERVICIO DE REPORTES           │
                      │   Node.js + Express + node-cron               │
                      │   Generador PDF (jsPDF + AutoTable)           │
                      │   Telegram Bot API (Webhook con Secret Token) │
                      └───────────────────────────────────────────────┘
```

---

## ✨ Módulos y Funcionalidades Principales

### 🛒 1. Punto de Venta (POS) & Facturación
- **Búsqueda Ultrarrápida:** Búsqueda en catálogo por nombre, código de barras o precio dinámico en tiempo real.
- **Carrito Flotante Móvil:** Experiencia optimizada para smartphones y tablets de mostrador con persistencia de pedido.
- **Multi-Método de Pago:** Soporte para transacciones en efectivo, transferencias digitales y pagos mixtos.
- **Descuentos & Validación:** Cálculo dinámico de totales, descuentos autorizados y prevención de ventas sin stock.

### 📦 2. Inventario Multi-Sede & Valorización
- **Aislamiento Multi-Negocio:** Segmentación estricta de productos por negocio/sede (ej. *SurtiHogar*, *J&M Ropa*, *El Baratillo*).
- **Control de Stock Ideal:** Comparativa entre existencia actual y stock meta para reposición automatizada por rango de fechas.
- **Márgenes Ponderados:** Valorización de inventario considerando costo de adquisición, precio de venta y margen operativo real.
- **Gestión de Productos Especiales:** Depuración de duplicados, soporte para ítems formalizados e informales y checklist de compras.

### 💰 3. Cuadre de Caja & Control Financiero
- **Cierre Diario de Caja:** Módulo de balance con arqueo físico de billetes/monedas y detección instantánea de descuadres (faltantes o sobrantes).
- **Gestión de Egresos:** Clasificación de gastos operativos por categoría y centro de costos.
- **Cálculo de Utilidad Neta:** Algoritmo que deduce costos fijos diarios de mantenimiento y costo ponderado de mercancía.
- **Reportes Vectoriales PDF:** Generación de estados financieros descargables mediante `jsPDF` y `jspdf-autotable`, sincronizados con la zona horaria oficial de Bogotá (`America/Bogota`).

### 📍 4. Control de Asistencia Georreferenciado (BYOD)
- **Validación de Geocerca (Geofencing):** Registro de turnos laborales con verificación de coordenadas GPS en tiempo real mediante `@capacitor/geolocation`.
- **Prevención de Fraude:** Bloqueo de marcaciones remotas si el colaborador se encuentra fuera del radio autorizado de la sede.
- **Programación de Turnos:** Asignación de horarios, cálculo de horas efectivas y réplica semanal automatizada de cronogramas.

### 🤖 5. Bot Operativo de Telegram & Notificaciones
- **Cierre Diario Automatizado:** Cron programado que compila el resumen financiero del día y envía el informe en PDF al canal administrativo de Telegram.
- **Alertas de Novedades:** Notificación push inmediata de cambios de turno, egresos extraordinarios o descuadres de caja.
- **Webhook Protegido:** Servidor Express preparado para recibir webhooks de Telegram verificando la cabecera `X-Telegram-Bot-Api-Secret-Token`.

---

## 🛡️ Seguridad & Endurecimiento de Base de Datos (RLS)

El sistema implementa un modelo de defensa en profundidad diseñado para entornos multi-inquilino de alta exigencia:

1. **Aislamiento Estricto por Sede (`business_id`):** Los colaboradores solo pueden consultar y registrar transacciones correspondientes al negocio al que fueron asignados formalmente.
2. **Inmutabilidad de Registros Contables:** Las ventas, transacciones y cuadres de caja cerrados no permiten edición ni eliminación arbitraria por parte de usuarios operativos.
3. **Trigger de Integridad `protect_user_sensitive_fields()`:**
   - Ejecutado como `SECURITY INVOKER` para evaluar el rol real de sesión (`authenticated` vs. `service_role`).
   - Bloquea intentos de escalada de privilegios impidiendo la modificación de 8 campos críticos: `role`, `business_id`, `is_cashier`, `can_manage_inventory`, `hourly_rate`, `active`, `email` e `id`.
4. **Validación de Usuarios Activos:** Empleados con `active = false` quedan inmediatamente inhabilitados para registrar ventas, turnos o transacciones, independientemente de la validez de su token JWT.
5. **Prevención de Recursión Infinita en RLS:** Funciones auxiliares (`is_admin()`, `get_current_user_role()`) configuradas con `SET search_path = pg_catalog, public` para mitigar secuestro de rutas de búsqueda y bucles de evaluación de políticas.

---

## 💻 Stack Tecnológico

| Capa | Tecnologías |
| :--- | :--- |
| **Frontend** | Vanilla JavaScript (ES6+ Modules), HTML5 Semántico, CSS3 Flexbox/Grid, Vite 8 |
| **Mobile Híbrido** | Capacitor 8 (Core, Android, iOS, Geolocation, Filesystem, Share) |
| **Base de Datos & Auth** | Supabase (PostgreSQL 15+, PL/pgSQL, Row Level Security, Supabase Auth) |
| **Automatización & Bot** | Node.js, Express, node-cron, Telegram Bot API, jsPDF, jspdf-autotable |
| **Calidad & Pruebas** | Vitest 4, Testing Library DOM, JSDOM (68 pruebas unitarias y de integración) |

---

## 📂 Estructura del Proyecto

```
surtihogar/
├── android/                 # Proyecto nativo generado por Capacitor Android
├── ios/                     # Proyecto nativo generado por Capacitor iOS
├── public/                  # Recursos estáticos (iconos, manifest, assets)
├── scripts/                 # Servicios de backend y automatización
│   ├── server.js            # Servidor Express (webhook Telegram + endpoints)
│   ├── telegram_bot.js      # Lógica de comandos y respuestas del bot de Telegram
│   ├── send_daily_report.js # Generador y emisor del reporte diario PDF
│   └── send_monthly_report.js # Generador y emisor del reporte mensual
├── src/                     # Código fuente de la aplicación cliente
│   ├── lib/
│   │   └── supabase.js      # Cliente configurado de Supabase JS
│   ├── services/
│   │   └── ByodComplianceService.js # Servicio de geolocalización y asistencia
│   ├── geminiAI.js          # Integración de asistencia por IA (Google Gemini)
│   ├── inventoryAI.js       # Asistente de optimización de stock
│   ├── main.js              # Controlador principal de la UI, POS y navegación
│   └── style.css            # Hoja de estilos del sistema de diseño
├── supabase/                # Infraestructura como código (IaC) de Supabase
│   ├── migrations/          # Migraciones SQL versionadas (incluye RLS hardening)
│   └── tests/               # Pruebas de integración SQL para staging
├── tests/                   # Suite de pruebas automatizadas con Vitest
│   ├── rls_validation.test.js # Validación de contratos de seguridad RLS
│   ├── security_phase2.test.js # Pruebas de regresión de seguridad
│   ├── pos.test.js          # Pruebas del motor de punto de venta
│   ├── inventory.test.js    # Pruebas del módulo de inventario
│   ├── shifts.test.js       # Pruebas de turnos y geocercas
│   └── finance.test.js      # Pruebas de balance y finanzas
├── .env.example             # Plantilla de variables de entorno seguras
├── .gitignore               # Configuración de exclusión de Git
├── package.json             # Manifiesto de dependencias y scripts npm
└── vite.config.js           # Configuración de empaquetado con Vite
```

---

## 🚀 Instalación y Puesta en Marcha

### Prerrequisitos
- [Node.js](https://nodejs.org/) v20.x o superior
- Administrador de paquetes `npm` (v10+)
- Cuenta en [Supabase](https://supabase.com/) con un proyecto activo

### 1. Clonar el repositorio
```bash
git clone https://github.com/tu-usuario/surtihogar.git
cd surtihogar
```

### 2. Instalar dependencias
```bash
npm install
```

### 3. Configurar variables de entorno
Copia el archivo de ejemplo y completa con las credenciales de tu proyecto:
```bash
cp .env.example .env
```

Edita `.env` con tus claves:
```ini
# Supabase
VITE_SUPABASE_URL=https://tu-proyecto.supabase.co
VITE_SUPABASE_ANON_KEY=tu-anon-public-jwt-key

# Bot de Telegram (Opcional para reportes automáticos)
TELEGRAM_BOT_TOKEN=tu-bot-token
TELEGRAM_ADMIN_CHAT_ID=tu-chat-id
TELEGRAM_WEBHOOK_SECRET=tu-secreto-aleatorio

# Google Gemini AI (Opcional)
VITE_GEMINI_API_KEY=tu-gemini-api-key
```

### 4. Ejecutar en modo desarrollo
Inicia el servidor local de Vite:
```bash
npm run dev
```
La aplicación estará disponible en `http://localhost:5173`.

### 5. Iniciar el microservicio de reportes y bot (Opcional)
```bash
npm start
```
Levanta el servidor Express en el puerto configurado (por defecto `3000`).

---

## 🧪 Pruebas y Control de Calidad

El proyecto cuenta con una batería de **68 pruebas automatizadas** que cubren la lógica de negocio, cálculos financieros, validaciones de permisos y contratos de seguridad:

```bash
# Ejecutar todas las pruebas una vez
npx vitest run

# Ejecutar pruebas en modo observador (watch)
npm test

# Compilación de producción (Vite build)
npm run build
```

### Resultado de la suite:
```text
 ✓ tests/inventory.test.js (4 tests)
 ✓ tests/shifts.test.js (6 tests)
 ✓ tests/weekMath.test.js (6 tests)
 ✓ tests/rls_validation.test.js (7 tests)
 ✓ tests/security_phase2.test.js (17 tests)
 ✓ tests/pos.test.js (9 tests)
 ✓ tests/inventoryAI.test.js (4 tests)
 ✓ tests/finance.test.js (4 tests)
 ✓ tests/suppliers.test.js (3 tests)
 ✓ tests/edits.test.js (3 tests)
 ✓ tests/roles.test.js (5 tests)

 Test Files  11 passed (11)
      Tests  68 passed (68)
```

---

## 📱 Compilación Móvil (Android / iOS)

Para sincronizar y generar los binarios nativos con Capacitor:

```bash
# Compilar los recursos web
npm run build

# Sincronizar con plataformas móviles
npx cap sync

# Abrir en Android Studio
npx cap open android

# Abrir en Xcode (macOS)
npx cap open ios
```

---

## 📄 Licencia

Este proyecto fue desarrollado como una solución integral de software empresarial y se presenta como pieza de portafolio técnico. Todos los derechos reservados.
