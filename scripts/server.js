import express from 'express';
import cron from 'node-cron';
import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';
import { 
  loadTelegramConfig, 
  botToken, 
  handleMessage, 
  handleCallbackQuery, 
  startBot 
} from './telegram_bot.js';
import { runDailyReport } from './send_daily_report.js';
import { runMonthlyReport } from './send_monthly_report.js';

// Cargar variables de entorno del servidor de forma explícita
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.resolve(__dirname, '../.env') });

const app = express();

// Habilitar trust proxy para extraer la IP real del cliente detrás de proxies inversos (Render / Cloudflare)
app.set('trust proxy', 1);

// Middleware de seguridad y control de tamaño de carga
app.use(express.json({ limit: '100kb' }));

// Lista de orígenes autorizados para CORS (desarrollo local, contenedor y empaquetado móvil Capacitor)
const defaultAllowedOrigins = [
  'http://localhost:5173',
  'http://localhost:4173',
  'http://127.0.0.1:5173',
  'http://localhost:3000',
  'capacitor://localhost',
  'https://localhost'
];

const customOrigins = process.env.CORS_ALLOWED_ORIGINS
  ? process.env.CORS_ALLOWED_ORIGINS.split(',').map(o => o.trim()).filter(Boolean)
  : [];

const allowedOrigins = [...defaultAllowedOrigins, ...customOrigins];

// Middleware CORS restringido: valida el encabezado Origin y previene consumo arbitrario desde cualquier web no autorizada
app.use((req, res, next) => {
  const origin = req.headers.origin;

  if (origin) {
    if (allowedOrigins.includes(origin) || allowedOrigins.includes('*')) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    } else {
      if (req.method === 'OPTIONS') {
        return res.status(403).json({ error: 'Origen no autorizado por política CORS' });
      }
    }
  }

  if (req.method === 'OPTIONS') {
    return res.sendStatus(204);
  }
  next();
});

const PORT = process.env.PORT || 3000;

/**
 * Control de frecuencia (Rate Limiting) en memoria por dirección IP.
 * Límite: Máximo 15 peticiones por minuto por IP para llamadas de IA.
 *
 * ⚠️ NOTA TÉCNICA DE ARQUITECTURA:
 * Este limitador opera a nivel de instancia local única (in-memory process).
 * No proporciona protección distribuida en clústeres multi-nodo o funciones serverless.
 * Para escalamiento horizontal en producción se requeriría un almacén compartido como Redis.
 */
const aiRateLimitMap = new Map();
const RATE_LIMIT_WINDOW_MS = 60 * 1000;
const MAX_AI_REQUESTS_PER_WINDOW = 15;

function checkAiRateLimit(ip) {
  const now = Date.now();
  const record = aiRateLimitMap.get(ip) || { count: 0, resetAt: now + RATE_LIMIT_WINDOW_MS };
  if (now > record.resetAt) {
    record.count = 1;
    record.resetAt = now + RATE_LIMIT_WINDOW_MS;
    aiRateLimitMap.set(ip, record);
    return true;
  }
  if (record.count >= MAX_AI_REQUESTS_PER_WINDOW) {
    return false;
  }
  record.count++;
  aiRateLimitMap.set(ip, record);
  return true;
}

// Limpieza periódica cada 5 minutos de registros expirados de rate limit
setInterval(() => {
  const now = Date.now();
  for (const [ip, record] of aiRateLimitMap.entries()) {
    if (now > record.resetAt) aiRateLimitMap.delete(ip);
  }
}, 5 * 60 * 1000);

// Endpoint de salud para pings / mantener activo el bot
app.get('/', (req, res) => {
  res.send('🤖 J&M Telegram Bot & Scheduler is active!');
});

// Endpoint seguro de proxy para Google Gemini IA
// La clave de API (GEMINI_API_KEY) reside y se utiliza EXCLUSIVAMENTE en el servidor.
app.post('/api/ai/chat', async (req, res) => {
  const clientIp = req.ip || req.socket.remoteAddress || 'unknown';

  // 1. Control de frecuencia (Abuse Protection)
  if (!checkAiRateLimit(clientIp)) {
    return res.status(429).json({
      error: 'Límite de solicitudes de IA excedido (máximo 15 consultas por minuto). Por favor espera un momento.'
    });
  }

  // 2. Validación estricta de entrada
  const { prompt } = req.body || {};
  if (!prompt || typeof prompt !== 'string' || !prompt.trim()) {
    return res.status(400).json({
      error: 'El parámetro prompt es obligatorio y debe ser una cadena de texto válida.'
    });
  }

  if (prompt.length > 6000) {
    return res.status(400).json({
      error: 'La consulta excede la longitud máxima permitida (6.000 caracteres).'
    });
  }

  // 3. Verificación de credencial en variables de entorno del servidor
  const apiKey = process.env.GEMINI_API_KEY;
  if (!apiKey) {
    return res.status(503).json({
      error: 'El servicio de IA no está configurado en el servidor (GEMINI_API_KEY no definida en variables de entorno).'
    });
  }

  // 4. Invocación segura a Google Gemini (sin exponer la clave en errores ni logs)
  const candidateModels = [
    'gemini-2.5-flash',
    'gemini-1.5-flash',
    'gemini-flash-latest'
  ];

  let lastErrorMessage = null;

  for (const model of candidateModels) {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 10000);

    try {
      const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${encodeURIComponent(apiKey)}`;
      const response = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          contents: [{ parts: [{ text: prompt }] }]
        }),
        signal: controller.signal
      });

      clearTimeout(timeoutId);

      if (response.ok) {
        const data = await response.json();
        const text = data.candidates?.[0]?.content?.parts?.[0]?.text;
        if (text) {
          return res.json({ text });
        }
      } else {
        const errData = await response.json().catch(() => ({}));
        // Sanitizar el mensaje de error para evitar reflejar la clave o parámetros de URL
        lastErrorMessage = errData.error?.message || `HTTP ${response.status}`;
      }
    } catch (e) {
      clearTimeout(timeoutId);
      lastErrorMessage = e.name === 'AbortError' ? 'Tiempo de espera agotado (timeout de 10s)' : 'Error de conexión con el proveedor';
    }
  }

  console.error("🔒 Proxy Gemini IA: Error de llamada:", lastErrorMessage);
  return res.status(502).json({
    error: 'No se pudo obtener respuesta del servicio de IA en este momento.'
  });
});


// Endpoint de Webhook para Telegram (con validación obligatoria X-Telegram-Bot-Api-Secret-Token)
app.post('/webhook', async (req, res) => {
  const expectedSecret = process.env.TELEGRAM_WEBHOOK_SECRET;

  // Fail-secure: Si el servidor no tiene configurado el secreto, se rechaza para impedir ejecución no autorizada
  if (!expectedSecret) {
    console.error("🔒 Seguridad Webhook: TELEGRAM_WEBHOOK_SECRET no configurado en el servidor. Rechazando solicitud.");
    return res.status(500).json({ error: "Webhook secret not configured on server" });
  }

  const incomingSecret = req.headers['x-telegram-bot-api-secret-token'];
  if (!incomingSecret || incomingSecret !== expectedSecret) {
    console.warn("🔒 Seguridad Webhook: Acceso denegado (Token secreto inválido o ausente).");
    return res.status(403).json({ error: "Unauthorized: Invalid secret token" });
  }

  try {
    const update = req.body;
    if (update.message) {
      await handleMessage(update.message);
    } else if (update.callback_query) {
      await handleCallbackQuery(update.callback_query);
    }
  } catch (err) {
    console.error("❌ Error procesando webhook:", err);
  }
  // Responder 200 OK a Telegram rápido
  res.sendStatus(200);
});

// Programar el reporte diario automático a las 10:00 PM (Hora de Bogotá UTC-5)
cron.schedule('0 22 * * *', async () => {
  console.log("⏰ [Cron] Iniciando generación de reporte diario (10:00 PM Bogotá)...");
  try {
    // Forzamos el reporte del día actual
    await runDailyReport();
    console.log("✅ [Cron] Reporte diario generado y enviado con éxito.");
  } catch (err) {
    console.error("❌ [Cron] Error ejecutando reporte diario automático:", err);
  }
}, {
  scheduled: true,
  timezone: "America/Bogota"
});

// Programar chequeo a las 11:30 PM para el reporte mensual automático (Último día del mes)
cron.schedule('30 23 * * *', async () => {
  const now = new Date();
  // Sumar 1 día en hora de Bogotá
  const tomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
  
  if (tomorrow.getDate() === 1) {
    console.log("⏰ [Cron] Último día del mes detectado. Iniciando reporte mensual de rendimiento (11:30 PM Bogotá)...");
    try {
      await runMonthlyReport();
      console.log("✅ [Cron] Reporte mensual de rendimiento enviado con éxito.");
    } catch (err) {
      console.error("❌ [Cron] Error ejecutando reporte mensual automático:", err);
    }
  }
}, {
  scheduled: true,
  timezone: "America/Bogota"
});

async function initialize() {
  // Cargar token y config desde Supabase
  await loadTelegramConfig();

  // Iniciar servidor Express para webhooks
  app.listen(PORT, async () => {
    console.log(`🚀 Servidor activo en puerto ${PORT}`);

    // Si está alojado en Render, configurar Webhook
    if (process.env.RENDER_EXTERNAL_URL) {
      const webhookUrl = `${process.env.RENDER_EXTERNAL_URL}/webhook`;
      const secretQuery = process.env.TELEGRAM_WEBHOOK_SECRET ? `&secret_token=${encodeURIComponent(process.env.TELEGRAM_WEBHOOK_SECRET)}` : '';
      try {
        const res = await fetch(`https://api.telegram.org/bot${botToken}/setWebhook?url=${webhookUrl}${secretQuery}`);
        const result = await res.json();
        if (result.ok) {
          console.log(`✅ Webhook de Telegram registrado con éxito: ${webhookUrl}`);
        } else {
          console.error("❌ Falló el registro de Webhook en Telegram:", result);
        }
      } catch (err) {
        console.error("❌ Error registrando Webhook en Telegram:", err);
      }
    } else {
      // Si corre localmente, usar Long Polling de respaldo para poder probar sin internet público
      console.log("ℹ️ RENDER_EXTERNAL_URL no detectado. Iniciando bucle de Long Polling local...");
      startBot();
    }
  });
}

initialize();
