# SurtiHogar / J&M — Sistema de Gestión Multi-Negocio, POS & Control Financiero

[![Vite](https://img.shields.io/badge/Vite-8.0-646CFF?style=flat&logo=vite&logoColor=white)](https://vitejs.dev/)
[![JavaScript](https://img.shields.io/badge/JavaScript-ESModules-F7DF1E?style=flat&logo=javascript&logoColor=black)](https://developer.mozilla.org/es/docs/Web/JavaScript)
[![Supabase](https://img.shields.io/badge/Supabase-PostgreSQL%20%2B%20RLS-3ECF8E?style=flat&logo=supabase&logoColor=white)](https://supabase.com/)
[![Capacitor](https://img.shields.io/badge/Capacitor-8.3%20Mobile-119EFF?style=flat&logo=capacitor&logoColor=white)](https://capacitorjs.com/)
[![Vitest](https://img.shields.io/badge/Tests-72%20Passed-4EAA25?style=flat&logo=vitest&logoColor=white)](https://vitest.dev/)
[![License](https://img.shields.io/badge/License-Proprietary%20%2F%20Portfolio-blue.svg)](#licencia)

Plataforma de software para punto de venta (POS), control de inventarios multi-sede, arqueos de caja diarios y registro laboral georreferenciado (BYOD). Construida como una Single Page Application (SPA) modular para web y aplicaciones móviles híbridas (Android/iOS con Capacitor), respaldada por PostgreSQL con Row-Level Security (RLS) en Supabase y un microservicio en Node.js para automatización de reportes contables, alertas en Telegram y proxy seguro de IA.

---

## 🎯 Problema que Resuelve

Las pequeñas y medianas cadenas comerciales minoristas (*retail*) con múltiples puntos de venta físicos enfrentan fricciones operativas críticas:
1. **Falta de visibilidad financiera en tiempo real:** Desfase entre las ventas en mostrador y los egresos diarios en efectivo (fletes, servicios, alimentación).
2. **Descuadres en cierres de caja:** Pérdidas por falta de arqueo físico estructurado al finalizar los turnos.
3. **Capital estancado en inventario:** Falta de métricas sobre qué mercancía tiene rotación nula (30+ días) frente a productos con agotamiento inminente.
4. **Fraude en control de asistencia (BYOD):** Colaboradores que marcan turno de forma remota sin estar físicamente en la sede comercial asignada.
5. **Aislamiento de sedes en modelos multi-negocio:** Riesgo de fuga de información contable entre diferentes sucursales o administradores.

**SurtiHogar** unifica estas operaciones en una interfaz ligera, accesible desde teléfonos móviles o computadores de mostrador, con persistencia y aislamiento estricto en base de datos.

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
                      │  - PostgreSQL 15+ (Esquema relacional)       │
                      │  - Row Level Security (RLS multi-tenant)      │
                      │  - Trigger Integridad (SECURITY INVOKER)     │
                      │  - Supabase Auth (JWT & Roles de usuario)     │
                      └───────▲───────────────────────────────▲───────┘
                              │                               │
                   SQL / API  │                   Alertas     │ HTTPS Cron
                              │                               │
                      ┌───────┴───────────────────────────────┴───────┐
                      │          MICROSERVICIO NODE.JS / EXPRESS      │
                      │  - Proxy seguro de Google Gemini IA           │
                      │    (GEMINI_API_KEY aislada en servidor)       │
                      │  - Generador de PDF (jsPDF + AutoTable)       │
                      │  - Webhook de Telegram con Secret Token       │
                      │  - Programador nocturno (node-cron UTC-5)     │
                      └───────────────────────────────────────────────┘
```

---

## ✨ Módulos y Funcionalidades Implementadas

### 🛒 1. Punto de Venta (POS) & Facturación
- **Búsqueda Dinámica:** Filtrado instantáneo por nombre, código de barras o rango de precios.
- **Carrito Flotante Móvil:** Interfaz táctil adaptada para teléfonos Android/iOS con persistencia local de orden.
- **Múltiples Métodos de Pago:** Soporte para efectivo, transferencias electrónicas y pagos mixtos.
- **Validaciones Comerciales:** Aplicación de descuentos autorizados y prevención de ventas en negativo.

### 📦 2. Inventario Multi-Sede & Análisis Financiero
- **Segmentación por Negocio:** Catálogos independientes por sede (`business_id`).
- **Métricas de Rotación (VMD):** Cálculo de Velocidad Media Diaria de venta para predecir días de stock restantes.
- **Detección de Capital Estancado:** Identificación de productos con más de 30 días en sistema sin ventas registradas.
- **Sugerido de Compra Inteligente:** Generación automática de listas de reposición según metas de inventario.

### 💰 3. Cuadre de Caja & Control Financiero
- **Arqueo Físico de Billetes y Monedas:** Formulario de conteo desglosado para cuadres diarios de caja.
- **Detección de Descuadres:** Cálculo automático de faltantes o sobrantes respecto a las ventas del sistema.
- **Deducción de Costos Fijos:** Algoritmo que descuenta costos de mantenimiento diario ($137.000 COP/día) para calcular la utilidad neta real.
- **Reportes Vectoriales en PDF:** Exportación de estados financieros con tablas formateadas y hora oficial de Bogotá (`America/Bogota`).

### 📍 4. Control de Asistencia Georreferenciado (BYOD)
- **Validación de Geocercas (Geofencing):** Verificación de coordenadas GPS del dispositivo mediante `@capacitor/geolocation`.
- **Prevención de Marcaciones Remotas:** Bloqueo de entrada/salida de turnos si el colaborador se encuentra fuera del radio autorizado de la sede.
- **Gestión de Turnos:** Asignación horaria y cálculo de horas efectivas laboradas.

### 🤖 5. Bot Operativo de Telegram & Automatización
- **Reporte Nocturno Automático:** Cron programado a las 10:00 PM (hora Bogotá) que consolida el día y envía el informe PDF a Telegram.
- **Webhook Protegido:** Servidor Express que valida la cabecera `X-Telegram-Bot-Api-Secret-Token` antes de procesar eventos.

### 🧠 6. Asistente Ejecutivo de Inteligencia Artificial (Google Gemini)
- **Proxy Seguro en Servidor:** Las peticiones se procesan en `/api/ai/chat` protegiendo `GEMINI_API_KEY` exclusivamente en el servidor.
- **Protección contra Abuso:** Limitación de frecuencia en memoria (máximo 15 peticiones por minuto por IP) y validación de longitud de consultas.
- **Consultor de Inventario:** Diagnóstico predictivo sobre valorización, rotación y estrategias promocionales para mover mercancía estancada.

---

## 🛡️ Seguridad y Control de Acceso (RLS)

El modelo de seguridad diseñado implementa el principio de defensa en profundidad:

1. **Aislamiento Multi-Tenant:**
   - Empleados y cajeros solo pueden consultar y registrar datos dentro de su sede asignada (`business_id`).
   - Los administradores tienen visibilidad global y capacidades de auditoría.
2. **Inmutabilidad del Historial Contable:**
   - Las ventas, transacciones y cuadres de caja cerrados no pueden ser eliminados ni alterados por personal operativo.
3. **Trigger de Protección de Perfiles (`protect_user_sensitive_fields`):**
   - Configurado como `SECURITY INVOKER` para evaluar el rol real de sesión (`authenticated` vs. `service_role`).
   - Bloquea intentos de escalada de privilegios impidiendo modificar: `role`, `business_id`, `is_cashier`, `can_manage_inventory`, `hourly_rate`, `active`, `email` e `id`.
4. **Desactivación de Usuarios:**
   - La condición `(active IS NULL OR active = true)` inhabilita inmediatamente a usuarios dados de baja para cualquier operación de escritura.
5. **Prevención de Recursión en PostgreSQL:**
   - Funciones auxiliares (`is_admin()`, `get_current_user_business_id()`, `get_current_user_role()`) con `SET search_path = pg_catalog, public` para mitigar secuestro de esquemas y bucles infinitos de evaluación.

---

## 💻 Stack Tecnológico

| Capa | Tecnologías |
| :--- | :--- |
| **Frontend** | Vanilla JavaScript (ES6+ Modules), HTML5 Semántico, CSS3 Flexbox/Grid, Vite 8 |
| **Mobile Híbrido** | Capacitor 8 (Core, Android, iOS, Geolocation, Filesystem, Share) |
| **Base de Datos & Auth** | Supabase (PostgreSQL 15+, PL/pgSQL, Row Level Security, Supabase Auth) |
| **Microservicio Backend** | Node.js, Express, node-cron, Telegram Bot API, jsPDF, jspdf-autotable |
| **Calidad & Pruebas** | Vitest 4, Testing Library DOM, JSDOM (71 pruebas unitarias y de seguridad) |

---

## 📂 Estructura del Repositorio

```
surtihogar-gestion-empresarial/
├── .github/
│   └── workflows/
│       └── ios-build.yml       # Integración continua para compilación de iOS
├── android/                    # Configuración nativa para Capacitor Android
├── ios/                        # Configuración nativa para Capacitor iOS
├── public/                     # Recursos estáticos (iconos, manifest, logos)
├── scripts/                    # Microservicio backend y automatizaciones
│   ├── server.js               # Servidor Express (webhook Telegram + proxy IA + cron)
│   ├── telegram_bot.js         # Lógica del bot operativo de Telegram
│   ├── send_daily_report.js    # Generador y despachador del PDF diario
│   └── send_monthly_report.js  # Consolidador contable mensual
├── src/                        # Código fuente de la aplicación cliente
│   ├── assets/                 # Recursos gráficos locales
│   ├── lib/
│   │   └── supabase.js         # Cliente inicializado de Supabase JS
│   ├── services/
│   │   ├── ByodComplianceService.js # Lógica de geolocalización y geocercas
│   │   ├── DatabaseService.js       # Capa de abstracción de datos
│   │   └── SupplierService.js       # Servicio de órdenes y proveedores
│   ├── views/
│   │   ├── inventoryAIView.js  # Vista del consultor de inventario con IA
│   │   ├── productsAdmin.js    # Módulo de administración de productos
│   │   └── salesHistory.js     # Historial de ventas y reportes
│   ├── geminiAI.js             # Cliente del asistente global de IA
│   ├── inventoryAI.js          # Algoritmo de rotación y análisis de stock
│   ├── main.js                 # Controlador central de UI, estado y navegación
│   ├── pos-engine.js           # Motor de cálculo del punto de venta
│   └── style.css               # Sistema de diseño y estilos visuales
├── supabase/                   # Infraestructura como Código (IaC) de Supabase
│   ├── migrations/             # Migraciones SQL versionadas (incluye RLS hardening)
│   └── tests/                  # Suite de pruebas SQL preparadas para staging
├── tests/                      # Suite de pruebas automatizadas con Vitest (71 tests)
│   ├── edits.test.js
│   ├── finance.test.js
│   ├── inventory.test.js
│   ├── inventoryAI.test.js
│   ├── pos.test.js
│   ├── rls_validation.test.js
│   ├── roles.test.js
│   ├── security_phase2.test.js
│   ├── shifts.test.js
│   ├── suppliers.test.js
│   └── weekMath.test.js
├── .env.example                # Plantilla de configuración segura
├── .gitignore                  # Reglas de exclusión de Git
├── capacitor.config.json       # Configuración de empaquetado Capacitor
├── package.json                # Manifiesto de dependencias y scripts
└── vite.config.js              # Configuración de empaquetado con Vite
```

---

## 🚀 Instalación y Puesta en Marcha

### Prerrequisitos
- [Node.js](https://nodejs.org/) v20.x o superior
- Gestor de paquetes `npm` (v10+)
- Cuenta activa en [Supabase](https://supabase.com/)

### 1. Clonar el repositorio
```bash
git clone https://github.com/unjuandice3333-star/surtihogar-gestion-empresarial.git
cd surtihogar-gestion-empresarial
```

### 2. Instalar dependencias
```bash
npm install
```

### 3. Configurar variables de entorno
Copia la plantilla de configuración:
```bash
cp .env.example .env
```

Edita `.env` distinguiendo las variables de cliente y servidor:

```ini
# --- CLIENTE (Público - Empaquetado en el navegador por Vite) ---
VITE_SUPABASE_URL=https://tu-proyecto.supabase.co
VITE_SUPABASE_ANON_KEY=tu-clave-anon-publica-de-supabase
VITE_API_URL=http://localhost:3000

# --- SERVIDOR (Privado - Exclusivo de Node.js / Express) ---
GEMINI_API_KEY=tu-clave-privada-de-google-gemini
TELEGRAM_BOT_TOKEN=tu-bot-token-de-telegram
TELEGRAM_ADMIN_CHAT_ID=tu-chat-id-de-telegram
TELEGRAM_WEBHOOK_SECRET=un-secreto-aleatorio-para-el-webhook
PORT=3000
```

> [!NOTE]
> La clave `VITE_SUPABASE_ANON_KEY` es pública por diseño y sus permisos están delimitados por las políticas RLS. Las claves privadas (`GEMINI_API_KEY`, tokens de Telegram y secretos de servicio) residen **exclusivamente en el servidor** y nunca se compilan en el cliente.

### 4. Ejecutar la aplicación en desarrollo
Inicia el servidor de desarrollo de Vite:
```bash
npm run dev
```
La aplicación web estará disponible en `http://localhost:5173`.

### 5. Iniciar el microservicio backend (Opcional - Reportes, Bot y Proxy de IA)
En una terminal secundaria:
```bash
npm start
```
El servidor Express estará activo en `http://localhost:3000`.

---

## 🧪 Pruebas y Control de Calidad

El proyecto incluye **72 pruebas automatizadas** que validan la lógica contable, los motores de rotación de inventario, los cálculos de turnos, el aislamiento multi-tenant y los contratos de seguridad:

```bash
# Ejecutar todas las pruebas unitarias y de seguridad
npx vitest run

# Compilar los recursos estáticos para producción
npm run build
```

### Resultado de la suite de pruebas:
```text
 ✓ tests/security_phase2.test.js (20 tests)
 ✓ tests/rls_validation.test.js (8 tests)
 ✓ tests/inventory.test.js (4 tests)
 ✓ tests/shifts.test.js (6 tests)
 ✓ tests/weekMath.test.js (6 tests)
 ✓ tests/pos.test.js (9 tests)
 ✓ tests/inventoryAI.test.js (4 tests)
 ✓ tests/suppliers.test.js (3 tests)
 ✓ tests/edits.test.js (3 tests)
 ✓ tests/finance.test.js (4 tests)
 ✓ tests/roles.test.js (5 tests)

 Test Files  11 passed (11)
      Tests  72 passed (72)
   Duration  964ms
```

---

## 📸 Guía para Capturas de Pantalla (`docs/screenshots/`)

Para mantener la integridad técnica del portafolio, el repositorio no incluye imágenes simuladas ni capturas artificiales. Se recomienda capturar la interfaz real en ejecución y almacenarla en la carpeta `docs/screenshots/`:

| Nombre sugerido | Módulo a capturar | Contenido clave a destacar |
| :--- | :--- | :--- |
| `01-pos-checkout.png` | Punto de Venta (POS) | Carrito flotante, búsqueda dinámica de productos y selector de método de pago. |
| `02-inventory-valuation.png` | Inventario & Rotación | Métricas de capital estancado, sugerido de compra y botón de diagnóstico con IA. |
| `03-cash-closure.png` | Cuadre de Caja | Formulario de desglose de efectivo (billetes/monedas) y cálculo de faltante/sobrante. |
| `04-byod-geofence.png` | Turnos & Asistencia | Marcación georreferenciada con validación GPS dentro del perímetro de la sede. |
| `05-pdf-financial-report.png` | Reporte Contable PDF | Documento PDF generado con tablas vectoriales y deducción de costos fijos. |
| `06-telegram-alerts.png` | Microservicio Telegram | Alerta nocturna recibida con el PDF financiero adjunto. |

---

## ⚠️ Estado de Validaciones de Seguridad y Limitaciones Conocidas

> [!IMPORTANT]
> **Divulgación de Estado Técnico:**
> 1. **Validación de Políticas RLS:** Las reglas de control de acceso, los bloqueos de escalada de privilegios y las funciones auxiliares han sido verificadas en el entorno local mediante simulaciones lógicas y pruebas de contrato con Vitest (`tests/rls_validation.test.js` y `tests/security_phase2.test.js`). La migración SQL definitiva está formulada en `supabase/migrations/20260429_harden_rls_policies.sql`.
> 2. **Paso Previo a Producción Requerido:** Antes de desplegar en producción con datos comerciales activos, la migración debe aplicarse a una base de datos PostgreSQL real (vía Supabase CLI o contenedor Docker de staging) y validarse ejecutando la suite de integración `supabase/tests/staging_rls_test.sql`.
> 3. **Conexión Externa de IA:** Si el servidor backend no se encuentra activo o no cuenta con `GEMINI_API_KEY` configurada, las funcionalidades predictivas de IA informarán al usuario de la ausencia del microservicio sin interrumpir la operación del punto de venta ni la navegación básica del catálogo.

---

## 📄 Licencia

Este proyecto fue desarrollado como solución de software para gestión comercial y se publica con fines de demostración técnica en portafolio profesional. Todos los derechos reservados.
