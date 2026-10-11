/**
 * Motor de IA & Analítica Predictiva de Inventarios
 * SurtiHogar & Baratillo
 */

/**
 * Calcula la Velocidad Media Diaria (VMD) de ventas de cada producto en un rango de días.
 * @param {Array} sales - Lista de ventas de la app
 * @param {Array} saleItems - Lista de ítems vendidos
 * @param {string} businessId - ID de negocio ('all' o ID específico)
 * @param {number} periodDays - Días a analizar (por defecto 30 días)
 * @returns {Object} Mapa de productId -> VMD (unidades/día)
 */
export const calculateProductVMD = (sales = [], saleItems = [], businessId = 'all', periodDays = 30) => {
  const now = new Date();
  const cutoff = new Date(now.getTime() - (periodDays * 24 * 60 * 60 * 1000));
  
  // Filtrar ventas dentro del periodo
  const validSales = sales.filter(s => {
    const sDate = new Date(s.created_at || s.date);
    return sDate >= cutoff;
  });

  const validSaleIds = new Set(validSales.map(s => s.id));
  const vmdMap = {};

  saleItems.forEach(item => {
    if (!validSaleIds.has(item.sale_id)) return;
    
    // Filtrar por sede si aplica
    if (businessId !== 'all') {
      const prodBiz = item.products?.business_id;
      if (prodBiz && prodBiz !== businessId) return;
    }

    const prodId = item.product_id;
    const qty = Number(item.quantity) || 1;

    if (!vmdMap[prodId]) {
      vmdMap[prodId] = 0;
    }
    vmdMap[prodId] += qty;
  });

  // Convertir acumulados a velocidad diaria
  const result = {};
  Object.keys(vmdMap).forEach(pId => {
    result[pId] = parseFloat((vmdMap[pId] / periodDays).toFixed(3));
  });

  return result;
};

/**
 * Genera el diagnóstico completo de salud e IA del inventario
 * Veracidad estricta: Calcula la antigüedad real del sistema y evita falsos 99 días.
 * @param {Object} params - { products, sales, saleItems, businessId, targetDays }
 */
export const analyzeInventoryAI = ({ products = [], sales = [], saleItems = [], businessId = 'all', targetDays = 15 }) => {
  const filteredProducts = products.filter(p => businessId === 'all' || p.business_id === businessId);
  const vmdMap = calculateProductVMD(sales, saleItems, businessId, 30);

  const criticalStockouts = [];
  const stagnantProducts = [];
  const replenishmentOrders = [];
  const newProducts = [];
  
  let totalCapitalInStagnant = 0;
  let totalEstimatedReplenishmentCost = 0;
  let totalInventoryCostValue = 0;
  let totalInventorySaleValue = 0;
  let totalUnitsInStock = 0;

  const now = new Date();

  // Determinar la fecha más antigua de actividad registrada en el sistema (ventas)
  const earliestSystemTime = sales.length > 0
    ? Math.min(...sales.map(s => new Date(s.created_at || s.date || Date.now()).getTime()))
    : Date.now();
  const maxPossibleDaysInSystem = Math.max(1, Math.floor((now.getTime() - earliestSystemTime) / (1000 * 60 * 60 * 24)));

  filteredProducts.forEach(prod => {
    const stock = Number(prod.stock) || 0;
    const cost = parseFloat(prod.cost) || 0;
    const price = parseFloat(prod.price) || 0;
    const vmd = vmdMap[prod.id] || 0;

    // A. Valoración Total de Inversión y Venta
    if (stock > 0) {
      totalUnitsInStock += stock;
      totalInventoryCostValue += (stock * cost);
      totalInventorySaleValue += (stock * price);
    }

    // Calcular antigüedad del producto en el sistema (en días)
    let daysInSystem = maxPossibleDaysInSystem;

    if (prod.created_at) {
      const cDate = new Date(prod.created_at);
      if (!isNaN(cDate.getTime())) {
        daysInSystem = Math.max(0, Math.floor((now.getTime() - cDate.getTime()) / (1000 * 60 * 60 * 24)));
      }
    } else {
      // Buscar la fecha de su primera venta si aplica
      const prodItems = saleItems.filter(si => si.product_id === prod.id);
      if (prodItems.length > 0) {
        const prodSaleIds = new Set(prodItems.map(si => si.sale_id));
        const prodSales = sales.filter(s => prodSaleIds.has(s.id));
        if (prodSales.length > 0) {
          const earliestProdSaleTime = Math.min(...prodSales.map(s => new Date(s.created_at || s.date).getTime()));
          daysInSystem = Math.max(0, Math.floor((now.getTime() - earliestProdSaleTime) / (1000 * 60 * 60 * 24)));
        }
      }
    }

    // A. Días de Stock Restantes (DDS)
    const daysOfStock = vmd > 0 ? parseFloat((stock / vmd).toFixed(1)) : (stock > 0 ? 999 : 0);

    // B. Detectar Agotamiento Crítico (menos de 5 días de stock y con demanda)
    if (vmd > 0 && daysOfStock <= 5) {
      criticalStockouts.push({
        ...prod,
        vmd,
        daysOfStock,
        suggestedRestock: Math.ceil((vmd * targetDays) - stock)
      });
    }

    // C. VERACIDAD ESTRICTA: Detectar Capital Estancado 
    // Únicamente si el producto tiene stock > 0, VMD = 0 Y LLEVA 30+ DÍAS EN EL SISTEMA
    if (stock > 0 && vmd === 0) {
      if (daysInSystem >= 30) {
        const capitalEstancado = stock * cost;
        totalCapitalInStagnant += capitalEstancado;
        stagnantProducts.push({
          ...prod,
          daysInSystem,
          capitalEstancado,
          potentialRevenue: stock * price
        });
      } else {
        // Es un producto nuevo en catálogo (menos de 30 días de creado)
        newProducts.push({
          ...prod,
          daysInSystem
        });
      }
    }

    // D. Sugerido de Reabastecimiento
    const targetStock = Math.ceil(vmd * targetDays);
    if (stock < targetStock && vmd > 0) {
      const quantityToOrder = Math.max(1, targetStock - stock);
      const estimatedCost = quantityToOrder * cost;
      totalEstimatedReplenishmentCost += estimatedCost;

      replenishmentOrders.push({
        ...prod,
        vmd,
        daysOfStock,
        quantityToOrder,
        estimatedCost
      });
    }
  });

  // Ordenar alertas por prioridad
  criticalStockouts.sort((a, b) => a.daysOfStock - b.daysOfStock);
  stagnantProducts.sort((a, b) => b.capitalEstancado - a.capitalEstancado);
  replenishmentOrders.sort((a, b) => a.daysOfStock - b.daysOfStock);

  const DAILY_FIXED_COST = 137000;
  const periodFixedCosts = targetDays * DAILY_FIXED_COST;
  const totalPotentialProfit = totalInventorySaleValue - totalInventoryCostValue;
  const netEstimatedProfit = totalPotentialProfit - periodFixedCosts;

  return {
    totalProductsCount: filteredProducts.length,
    totalUnitsInStock,
    totalInventoryCostValue,
    totalInventorySaleValue,
    totalPotentialProfit,
    dailyFixedCost: DAILY_FIXED_COST,
    periodFixedCosts,
    netEstimatedProfit,
    criticalStockouts,
    stagnantProducts,
    newProducts,
    totalCapitalInStagnant,
    replenishmentOrders,
    totalEstimatedReplenishmentCost
  };
};

/**
 * Genera el texto formateado de la lista de compras para WhatsApp o PDF
 */
export const generateSupplierOrderText = (replenishmentOrders = [], businessName = 'Negocio') => {
  if (replenishmentOrders.length === 0) {
    return `📋 *ORDEN DE COMPRA SUGERIDA - ${businessName}*\n\n✅ Todo el inventario se encuentra optimizado. No hay requerimientos de pedido urgentes.`;
  }

  let text = `📦 *SUGERIDO DE COMPRA INTELIGENTE (IA)*\n🏢 *Sede:* ${businessName}\n📅 *Fecha:* ${new Date().toLocaleDateString('es-CO')}\n-----------------------------------\n\n`;
  
  let totalCostSum = 0;
  replenishmentOrders.forEach((item, index) => {
    const cost = item.estimatedCost || 0;
    totalCostSum += cost;
    text += `${index + 1}. *${item.name}*\n   • Cantidad Sugerida: *${item.quantityToOrder} unds*\n   • Stock Actual: ${item.stock} | Rotación: ${item.vmd}/día\n   • Costo Est.: $${cost.toLocaleString('es-CO')}\n\n`;
  });

  text += `-----------------------------------\n💰 *TOTAL ESTIMADO PEDIDO:* $${totalCostSum.toLocaleString('es-CO')}`;
  return text;
};

/**
 * Llama a la API de Google Gemini para generar el diagnóstico predictivo.
 * Por defecto, delega la consulta al backend seguro (/api/ai/chat) para no exponer GEMINI_API_KEY en el cliente.
 */
export const fetchGeminiInventoryAnalysis = async ({ analysis, businessName, apiKey, onStatusUpdate }) => {
  const prompt = `Eres un consultor experto en optimización financiera e inventarios para la cadena SurtiHogar / Baratillo en Colombia.
Analiza con máxima veracidad los siguientes datos operativos en tiempo real y redacta un diagnóstico ejecutivo breve (máximo 4 párrafos cortos o viñetas), directo, profesional y en español:

SEDE ANALIZADA: ${businessName}
- Total productos en catálogo: ${analysis.totalProductsCount} (${analysis.totalUnitsInStock || 0} unidades físicas)
- VALOR TOTAL INVERTIDO EN MERCANCÍA (Costo): $${(analysis.totalInventoryCostValue || 0).toLocaleString('es-CO')}
- VALOR COMERCIAL TOTAL (Venta): $${(analysis.totalInventorySaleValue || 0).toLocaleString('es-CO')}
- GANANCIA BRUTA EN INVENTARIO: $${(analysis.totalPotentialProfit || 0).toLocaleString('es-CO')}
- COSTOS FIJOS DE MANTENIMIENTO BASE ($137.000/día): $${(analysis.periodFixedCosts || 0).toLocaleString('es-CO')}
- UTILIDAD NETA ESTIMADA REAL (Descontando $137.000/día): $${(analysis.netEstimatedProfit || 0).toLocaleString('es-CO')}
- Productos con rotación en riesgo de agotamiento (< 5 días): ${analysis.criticalStockouts.length}
- Productos verdaderamente estancados (más de 30 días de creados sin ventas): ${analysis.stagnantProducts.length}
- Nuevos productos en catálogo (menos de 30 días de creados): ${analysis.newProducts?.length || 0}
- Capital verdaderamente estancado: $${analysis.totalCapitalInStagnant.toLocaleString('es-CO')}
- Sugerido de compra estimado: $${analysis.totalEstimatedReplenishmentCost.toLocaleString('es-CO')} (${analysis.replenishmentOrders.length} artículos)

PRODUCTOS POR AGOTARSE RÁPIDO:
${analysis.criticalStockouts.slice(0, 5).map(p => `- ${p.name}: Quedan ${p.stock} unds (se agota en ${p.daysOfStock} días)`).join('\n') || 'Ninguno'}

MERCANCÍA VERDADERAMENTE ESTANCADA (30+ DÍAS EN SISTEMA):
${analysis.stagnantProducts.slice(0, 5).map(p => `- ${p.name}: ${p.stock} unds (${p.daysInSystem} días en sistema, $${p.capitalEstancado.toLocaleString('es-CO')} en costo)`).join('\n') || 'Ninguna'}

Entrega:
1. 📊 Estado Financiero del Inventario.
2. 💡 Estrategia para mover el capital estancado real (combos/promociones).
3. 📦 Prioridad de Reabastecimiento.`;

  // 1. Si se proporciona una clave manual en runtime (pruebas locales o usuario que ingresa su clave personal)
  const manualKey = apiKey || (typeof localStorage !== 'undefined' ? localStorage.getItem('gemini_api_key') : '');
  if (manualKey) {
    const candidateModels = [
      'gemini-2.5-flash',
      'gemini-1.5-flash',
      'gemini-flash-latest'
    ];

    let lastError = null;

    for (const model of candidateModels) {
      if (onStatusUpdate) onStatusUpdate(`⚡ Conectando con Gemini IA (${model})...`);

      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 9000);

      try {
        const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${encodeURIComponent(manualKey)}`;
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
          if (text) return text;
        } else {
          const errData = await response.json().catch(() => ({}));
          lastError = new Error(errData.error?.message || `Error HTTP ${response.status}`);
        }
      } catch (e) {
        clearTimeout(timeoutId);
        lastError = e.name === 'AbortError' ? new Error(`Tiempo de respuesta agotado (9s)`) : e;
      }
    }

    throw lastError || new Error('No se pudo obtener respuesta directa de Google Gemini.');
  }

  // 2. Ruta estándar y segura: Proxy de backend (la clave reside en el servidor)
  if (onStatusUpdate) onStatusUpdate('⚡ Consultando servicio de IA en servidor...');

  const rawBase = (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_API_URL)
    ? import.meta.env.VITE_API_URL
    : 'http://localhost:3000';
  const serverBase = String(rawBase).replace(/\/+$/, '');

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 12000);

  try {
    const response = await fetch(`${serverBase}/api/ai/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ prompt }),
      signal: controller.signal
    });

    clearTimeout(timeoutId);

    if (response.ok) {
      const data = await response.json();
      if (data.text) return data.text;
    }

    const errData = await response.json().catch(() => ({}));
    throw new Error(errData.error || `Error del servidor de IA (HTTP ${response.status})`);
  } catch (err) {
    clearTimeout(timeoutId);
    if (err.name === 'AbortError') {
      throw new Error('La consulta al servicio de IA superó el tiempo límite.');
    }
    if (err.message && (err.message.includes('Failed to fetch') || err.message.includes('NetworkError') || err.message.includes('ECONNREFUSED'))) {
      throw new Error('El microservicio backend no está en ejecución. Inicia el servidor (`npm start`) con GEMINI_API_KEY configurada, o ingresa una clave personal en la interfaz.');
    }
    throw err;
  }
};
