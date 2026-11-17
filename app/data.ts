export type OperationStage = "negociacion" | "produccion" | "logistica" | "atrasado" | "pospuesto" | "cancelado" | "reorganizando" | "completado";
export type DeliveryStatus = "programada" | "en_transito" | "parcial" | "completa" | "fallida" | "rechazada";
export type OrderUpdateKind = "cambio" | "entrega" | "direccion" | "despacho" | "incidencia";
export type ProductionSource = "internal" | "sawmill" | "import";
export type TransportSource = "internal" | "external";
export type CapacityOperation = "assembly" | "treatment" | "marking" | "ht";
export type CapacityStatus = "estimated" | "confirmed";
export type ProductionAllocationStatus = "draft" | "confirmed" | "completed" | "cancelled";
export type ShipmentStatus = "planned" | "ready" | "loaded" | "dispatched" | "delivered" | "cancelled";
export type RescheduleReason = "production" | "logistics" | "client" | "weather" | "other";
export type OrderOperationalStatus = "planned" | "produced" | "ht_planning" | "ht_confirmed" | "shipped" | "delivered" | "cancelled";

export interface ProductionAllocation {
  id: number | string;
  orderLineId: string;
  resourceId?: string;
  productionResourceId?: number | string;
  capacityRuleId?: number | string;
  plannedDate: string;
  plannedQuantity: number;
  actualQuantity?: number;
  actualDate?: string;
  resultDestination?: "client" | "stock";
  status: ProductionAllocationStatus;
  note?: string;
  completedAt?: string;
  completionNote?: string;
  createdAt: string;
  updatedAt: string;
}

export interface ShipmentLine {
  id: number | string;
  shipmentId: number | string;
  orderLineId: string;
  product: string;
  plannedQuantity: number;
  loadedQuantity?: number;
  deliveredQuantity: number;
}

export interface ShipmentEvent {
  id: number | string;
  shipmentId: number | string;
  eventType: "created" | "transition" | "rescheduled" | "incident" | "remittance_corrected";
  previousStatus?: ShipmentStatus;
  nextStatus?: ShipmentStatus;
  previousDate?: string;
  nextDate?: string;
  reason?: RescheduleReason;
  note?: string;
  previousRemittance?: string;
  nextRemittance?: string;
  responsible: string;
  createdAt: string;
}

export interface Shipment {
  id: number | string;
  orderId: string;
  plannedDate: string;
  status: ShipmentStatus;
  transportSource: TransportSource;
  transportProviderId?: string;
  transportLabel: string;
  remittance?: string;
  sharedRemittanceReason?: string;
  deliveryAddressSnapshot?: string;
  loadedAt?: string;
  dispatchedAt?: string;
  deliveredAt?: string;
  createdAt: string;
  updatedAt: string;
  lines: ShipmentLine[];
  events: ShipmentEvent[];
}

export interface OrderLine {
  id: string;
  product: string;
  productId?: string;
  clientProductId?: number | string;
  quantity: number;
  preparation?: string;
  requiresTreatment?: boolean;
  treatedQuantity?: number;
  treatmentPendingQuantity?: number;
  readyReservedQuantity?: number;
  productionAllocations?: ProductionAllocation[];
  /** Unidades de esta línea programadas en el secadero, por día. */
  dryingAllocations?: Array<{ date: string; quantity: number }>;
}

export interface OperationOrder {
  id: string;
  reference: string;
  client: string;
  clientId?: string;
  product: string;
  productId?: string;
  clientProductId?: number | string;
  requested: number;
  delivered: number;
  pending: number;
  stage?: OperationStage;
  dateLabel: string;
  plannedDate?: string;
  originalPlannedDate?: string;
  orderDate?: string;
  requestedDeliveryDate?: string;
  transport: string;
  transportSource?: TransportSource;
  transportProviderId?: string;
  productionSource?: ProductionSource;
  producerProviderId?: string;
  productionDate?: string;
  importArrivalDate?: string;
  requiredOperations?: CapacityOperation[];
  deliveryDateNote?: string;
  productionDefined?: boolean;
  productionEndDate?: string;
  transportDefined?: boolean;
  dryingStartDate?: string;
  dryingEndDate?: string;
  dryingNote?: string;
  supply: string;
  preparation: string;
  logistics: string;
  delivery: string;
  action: string;
  remittance?: string;
  deliveryAddress?: string;
  notes?: string;
  deliveryStatus?: DeliveryStatus;
  dispatchedAt?: string;
  deliveredAt?: string;
  lines: OrderLine[];
  shipments?: Shipment[];
  source: string;
}

export interface OrderChange {
  id: string;
  changedAt: string;
  kind?: OrderUpdateKind;
  note?: string;
  changes: Array<{ field: string; from: string; to: string }>;
}

export const stageLabels: Record<OperationStage, string> = {
  negociacion: "Negociación",
  produccion: "Producción",
  logistica: "Logística",
  atrasado: "Atrasado",
  pospuesto: "Pospuesto",
  cancelado: "Cancelado",
  reorganizando: "Reorganizando",
  completado: "Completado",
};

export function getOrderStage(order: OperationOrder): OperationStage {
  if (order.stage) return order.stage;
  return "negociacion";
}

export const orderOperationalStatusLabels: Record<OrderOperationalStatus, string> = {
  planned: "Planificando",
  produced: "Produciendo",
  ht_planning: "Produciendo",
  ht_confirmed: "Produciendo",
  shipped: "Enviando",
  delivered: "Entregado",
  cancelled: "Cancelado",
};

const lineRequiresHeat = (line: OrderLine) => Boolean(line.requiresTreatment) || /\bCon HT\b/i.test(line.product);

/** Palets del pedido repartidos por etapa. Cada palet cuenta una sola vez, en la etapa más avanzada que alcanzó. */
export function getOrderPalletStages(order: OperationOrder) {
  let produced = 0, heatProduced = 0, heatTreated = 0;
  for (const line of order.lines) {
    const fromProduction = (line.productionAllocations ?? [])
      .filter((allocation) => allocation.status === "completed" && allocation.resultDestination !== "stock")
      .reduce((sum, allocation) => sum + Math.max(allocation.actualQuantity ?? allocation.plannedQuantity, 0), 0);
    const lineProduced = Math.min(Math.max(fromProduction, line.readyReservedQuantity ?? 0), line.quantity);
    produced += lineProduced;
    if (lineRequiresHeat(line)) {
      heatProduced += lineProduced;
      heatTreated += Math.min(line.treatedQuantity ?? 0, lineProduced);
    }
  }
  const shipments = (order.shipments ?? []).filter((shipment) => shipment.status !== "cancelled");
  const sentByShipments = shipments.filter((shipment) => ["dispatched", "delivered"].includes(shipment.status))
    .flatMap((shipment) => shipment.lines).reduce((sum, line) => sum + Math.max(line.deliveredQuantity, line.loadedQuantity ?? line.plannedQuantity), 0);
  const legacySent = (order.dispatchedAt || order.deliveryStatus === "en_transito") && sentByShipments === 0 ? order.requested : 0;
  let shipped = Math.min(Math.max(order.delivered, sentByShipments, legacySent), order.requested);
  const buckets = { planned: Math.max(order.requested - produced, 0), htPlanning: heatProduced - heatTreated, htConfirmed: heatTreated, produced: produced - heatProduced, shipped: 0 };
  for (const key of ["produced", "htConfirmed", "htPlanning", "planned"] as const) {
    const taken = Math.min(buckets[key], shipped);
    buckets[key] -= taken;
    shipped -= taken;
  }
  buckets.shipped = Math.min(Math.max(order.delivered, sentByShipments, legacySent), order.requested);
  return buckets;
}

export function getOrderOperationalStatus(order: OperationOrder): OrderOperationalStatus {
  if (getOrderStage(order) === "cancelado") return "cancelled";

  const shipments = (order.shipments ?? []).filter((shipment) => shipment.status !== "cancelled");
  const deliveredByShipments = shipments.flatMap((shipment) => shipment.lines).reduce((sum, line) => sum + line.deliveredQuantity, 0);
  const delivered = Math.max(order.delivered, deliveredByShipments);
  if (Math.max(order.requested - delivered, 0) === 0) return "delivered";

  // La etiqueta muestra la etapa más adelantada que alcanzó alguna parte del pedido.
  const stages = getOrderPalletStages(order);
  if (stages.shipped > 0 || shipments.some((shipment) => ["dispatched", "delivered"].includes(shipment.status))) return "shipped";
  if (stages.htConfirmed > 0) return "ht_confirmed";
  if (stages.htPlanning > 0 || (order.dryingStartDate && order.lines.some(lineRequiresHeat))) return "ht_planning";
  if (stages.produced > 0) return "produced";
  return "planned";
}

export function isOrderClosed(order: OperationOrder) {
  return ["delivered", "cancelled"].includes(getOrderOperationalStatus(order));
}

export function isOrderOverdue(order: OperationOrder, today = new Date()) {
  if (isOrderClosed(order)) return false;
  // Atrasado: ya pasó la fecha para la que se pidió y el pedido sigue abierto, aunque se haya reprogramado la entrega.
  const plannedDate = getOrderRequestedDate(order);
  const todayKey = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, "0")}-${String(today.getDate()).padStart(2, "0")}`;
  return plannedDate < todayKey;
}

function dateFromLabel(label: string) {
  const day = Number(label.match(/\d+/)?.[0]);
  if (!Number.isFinite(day)) return "2026-08-10";
  return label.toLocaleLowerCase("es").includes("julio")
    ? `2026-07-${String(day).padStart(2, "0")}`
    : `2026-08-${String(day).padStart(2, "0")}`;
}

/** Fecha para la que se pidió el pedido; no cambia aunque la entrega real se mueva. */
export function getOrderRequestedDate(order: OperationOrder) {
  return order.requestedDeliveryDate ?? order.originalPlannedDate ?? getOrderPlannedDate(order);
}

export function getOrderPlannedDate(order: OperationOrder) {
  return order.plannedDate ?? dateFromLabel(order.dateLabel);
}

export function formatPlannedDate(date: string) {
  const value = new Date(`${date}T12:00:00`);
  return new Intl.DateTimeFormat("es-UY", { weekday: "long", day: "numeric", month: "long" }).format(value);
}

export type ProviderType = "Aserradero" | "Transporte" | "Importador";

export interface Provider {
  id: string;
  name: string;
  type: ProviderType;
  supplies: string;
  internalTransport?: boolean;
}

export function isActiveProvider({ id }: Pick<Provider, "id">) {
  return id !== "linares";
}

export interface Client {
  id: string;
  name: string;
  address?: string;
  department?: string;
  active?: boolean;
  updatedAt?: string;
}

export type ProductKind = "Pallet" | "Piso" | "Bin";

export interface Product {
  id: string;
  kind: ProductKind;
  measure?: string;
  heightCm?: number;
  requiresTreatment: boolean;
  stockName?: string;
  code?: string;
  stockActive?: boolean;
  clientNames?: string[];
  /** Valor por nivel (entrada, taco, refuerzo, exportación, tratamiento…). Ver classification.ts. Los productos viejos no lo tienen. */
  attributes?: Record<string, string>;
}

/** Ordena los códigos por su valor numérico (2 antes que 10), no por el texto. */
export function compareProductsByCode(left: Pick<Product, "code" | "stockName" | "id">, right: Pick<Product, "code" | "stockName" | "id">) {
  const codeNumber = (code?: string) => {
    const match = code?.match(/\d+/);
    return match ? Number(match[0]) : Number.POSITIVE_INFINITY;
  };
  const leftNumber = codeNumber(left.code);
  const rightNumber = codeNumber(right.code);
  if (leftNumber !== rightNumber) return leftNumber - rightNumber;

  return (left.code ?? "").localeCompare(right.code ?? "", "es", { numeric: true, sensitivity: "base" })
    || (left.stockName ?? "").localeCompare(right.stockName ?? "", "es", { sensitivity: "base" })
    || left.id.localeCompare(right.id, "es", { sensitivity: "base" });
}

export const providers: Provider[] = [
  { id: "blanc", name: "Blanc", type: "Aserradero", supplies: "Pallets y mercadería de terceros" },
  { id: "mirasol", name: "Mirasol", type: "Aserradero", supplies: "Pallets y mercadería de terceros" },
  { id: "linares", name: "Linares", type: "Transporte", supplies: "Transporte interno", internalTransport: true },
  { id: "susalla", name: "Susalla", type: "Transporte", supplies: "Transporte interno", internalTransport: true },
  { id: "giossa", name: "Giossa", type: "Transporte", supplies: "Transporte interno", internalTransport: true },
  { id: "milton", name: "Milton", type: "Transporte", supplies: "Traslado y entrega de pedidos" },
  { id: "matias", name: "Matías", type: "Transporte", supplies: "Traslado y entrega de pedidos" },
];

/** Productos de ejemplo para la tienda en memoria (pruebas y desarrollo). La base real tiene su propio catálogo. */
export const products: Product[] = [
  { id: "producto-01", kind: "Pallet", measure: "106 × 119", requiresTreatment: true, stockName: "Cristal PET", code: "1", stockActive: true },
  { id: "producto-02", kind: "Pallet", measure: "120 × 100", requiresTreatment: true, stockName: "Palets Citrus", code: "2", stockActive: true },
  { id: "producto-04", kind: "Pallet", measure: "106 × 106", requiresTreatment: false, stockName: "Saint Gobain", code: "4", stockActive: true },
  { id: "producto-05", kind: "Pallet", measure: "122 × 102", requiresTreatment: true, stockName: "Pallet", code: "5", stockActive: true },
  { id: "producto-09", kind: "Piso", requiresTreatment: true, stockName: "Pisos exportación", code: "9", stockActive: true },
  { id: "producto-15", kind: "Bin", requiresTreatment: true, stockName: "Bins X3 exportación", code: "15", stockActive: true },
  { id: "producto-40", kind: "Pallet", measure: "100 × 80", requiresTreatment: true, stockName: "Pallet", code: "40", stockActive: true },
];

export const orders: OperationOrder[] = [
  {
    id: "frutura-74",
    reference: "Plan 74",
    client: "Frutura",
    product: "Pallet 122 × 102",
    requested: 600,
    delivered: 0,
    pending: 600,
    stage: "produccion",
    dateLabel: "Viernes 14",
    transport: "Linares",
    supply: "Los pallets previstos no llegaron",
    preparation: "HT requerido",
    logistics: "Viaje con Linares detenido",
    delivery: "0 de 600 entregados",
    action: "Reprogramar la entrega cuando ingrese la mercadería.",
    lines: [{ id: "frutura-74-1", product: "Pallet 122 × 102", quantity: 600, preparation: "HT" }],
    source: "Plan semanal · fila 74",
  },
  {
    id: "proquimur-63",
    reference: "Plan 63",
    client: "Proquimur",
    product: "Pallet 120 × 100 Mercosur",
    requested: 600,
    delivered: 0,
    pending: 600,
    stage: "produccion",
    dateLabel: "Martes 11",
    transport: "Linares",
    supply: "600 en stock · 300 con HT y 300 sin HT",
    preparation: "300 con HT · 300 sin HT",
    logistics: "Linares asignado",
    delivery: "Pedido en coordinación",
    action: "Coordinar fecha con el cliente y reservar el viaje.",
    lines: [
      { id: "proquimur-63-1", product: "Pallet 120 × 100 Mercosur", quantity: 300, preparation: "Con HT" },
      { id: "proquimur-63-2", product: "Pallet 120 × 100 Mercosur", quantity: 300, preparation: "Sin HT" },
    ],
    source: "Plan semanal · fila 63",
  },
  {
    id: "pamer-184833",
    reference: "Orden 184833",
    client: "Pamer",
    product: "Cinco líneas de pallets",
    requested: 500,
    delivered: 500,
    pending: 0,
    stage: "completado",
    dateLabel: "28 de julio",
    transport: "No registrado",
    supply: "Orden despachada en cinco líneas",
    preparation: "380 sin HT · 120 con HT",
    logistics: "Remito 603",
    delivery: "500 entregados · saldo 0",
    action: "Pedido cerrado.",
    remittance: "603",
    lines: [
      { id: "184833-1", product: "Pallet 100 × 100 doble entrada", quantity: 100, preparation: "Sin HT" },
      { id: "184833-2", product: "Pallet 100 × 100", quantity: 20, preparation: "Con HT" },
      { id: "184833-3", product: "Pallet 120 × 80 doble entrada", quantity: 180, preparation: "Sin HT" },
      { id: "184833-4", product: "Pallet 120 × 130", quantity: 100, preparation: "Sin HT" },
      { id: "184833-5", product: "Pallet 100 × 120 Mercosur", quantity: 100, preparation: "Con HT" },
    ],
    source: "Órdenes Pamer · filas 4–8",
  },
  {
    id: "pamer-641",
    reference: "Remito 641",
    client: "Pamer",
    product: "Seis líneas de pallets",
    requested: 360,
    delivered: 360,
    pending: 0,
    stage: "completado",
    dateLabel: "12 de agosto",
    transport: "Propio",
    supply: "Seis líneas despachadas",
    preparation: "200 sin HT · 160 con HT",
    logistics: "Transporte propio · remito 641",
    delivery: "360 entregados · saldo 0",
    action: "Pedido cerrado.",
    remittance: "641",
    lines: [
      { id: "641-1", product: "Pallet 216 × 110 simple", quantity: 100, preparation: "Con HT" },
      { id: "641-2", product: "Pallet 216 × 110 simple", quantity: 41, preparation: "Sin HT" },
      { id: "641-3", product: "Pallet 100 × 80", quantity: 100, preparation: "Sin HT" },
      { id: "641-4", product: "Pallet 100 × 100", quantity: 59, preparation: "Sin HT" },
      { id: "641-5", product: "Pallet 120 × 80", quantity: 20, preparation: "Con HT" },
      { id: "641-6", product: "Pallet 120 × 90 cerrado", quantity: 40, preparation: "Con HT" },
    ],
    source: "Órdenes Pamer · filas 10–15",
  },
  {
    id: "afb-62",
    reference: "Plan 62",
    client: "AFB",
    product: "Pallet 120 × 100 Mercosur cepillado",
    requested: 600,
    delivered: 600,
    pending: 0,
    stage: "completado",
    dateLabel: "Martes 11",
    transport: "Linares",
    supply: "Pedido completo",
    preparation: "Mercosur cepillado",
    logistics: "Linares · un viaje",
    delivery: "600 entregados",
    action: "Pedido cerrado.",
    lines: [{ id: "afb-62-1", product: "Pallet 120 × 100 Mercosur cepillado", quantity: 600 }],
    source: "Plan semanal · fila 62",
  },
  {
    id: "granja-pocha-65",
    reference: "Plan 65",
    client: "Granja Pocha",
    product: "Punto rojo y Mercosur exportación",
    requested: 600,
    delivered: 600,
    pending: 0,
    stage: "completado",
    dateLabel: "Miércoles 12",
    transport: "Linares",
    supply: "Dos líneas completas",
    preparation: "400 punto rojo · 200 Mercosur exportación",
    logistics: "Linares · un viaje",
    delivery: "600 entregados",
    action: "Pedido cerrado.",
    lines: [
      { id: "pocha-65-1", product: "Pallet punto rojo 120 × 100", quantity: 400 },
      { id: "pocha-65-2", product: "Pallet Mercosur exportación 120 × 100", quantity: 200 },
    ],
    source: "Plan semanal · fila 65",
  },
  {
    id: "forestal-66",
    reference: "Plan 66",
    client: "Forestal Oriental",
    product: "Pallet 120 × 130",
    requested: 50,
    delivered: 50,
    pending: 0,
    stage: "completado",
    dateLabel: "Miércoles 12",
    transport: "Matías",
    supply: "Pedido completo",
    preparation: "Sin HT · sin corte de esquina · sin rebaje",
    logistics: "Matías · un viaje",
    delivery: "50 entregados",
    action: "Pedido cerrado.",
    lines: [{ id: "forestal-66-1", product: "Pallet 120 × 130", quantity: 50, preparation: "Sin HT" }],
    source: "Plan semanal · fila 66",
  },
  {
    id: "frutura-67",
    reference: "Plan 67",
    client: "Frutura",
    product: "Pallet 122 × 102",
    requested: 518,
    delivered: 518,
    pending: 0,
    stage: "completado",
    dateLabel: "Miércoles 12",
    transport: "Milton",
    supply: "Pedido completo",
    preparation: "Pallet 122 × 102",
    logistics: "Milton · un viaje",
    delivery: "518 entregados",
    action: "Pedido cerrado.",
    lines: [{ id: "frutura-67-1", product: "Pallet 122 × 102", quantity: 518 }],
    source: "Plan semanal · fila 67",
  },
  {
    id: "frutura-69",
    reference: "Plan 69",
    client: "Frutura",
    product: "Pallet 120 × 100",
    requested: 600,
    delivered: 600,
    pending: 0,
    stage: "completado",
    dateLabel: "Jueves 13",
    transport: "Linares",
    supply: "Pedido completo",
    preparation: "Pallet 120 × 100",
    logistics: "Linares · un viaje",
    delivery: "600 entregados",
    action: "Pedido cerrado.",
    lines: [{ id: "frutura-69-1", product: "Pallet 120 × 100", quantity: 600 }],
    source: "Plan semanal · fila 69",
  },
  {
    id: "azucitrus-75",
    reference: "Plan 75",
    client: "Azucitrus",
    product: "Pallet 120 × 100",
    requested: 600,
    delivered: 600,
    pending: 0,
    stage: "completado",
    dateLabel: "Viernes 14",
    transport: "Linares",
    supply: "Pedido completo",
    preparation: "Pallet 120 × 100",
    logistics: "Linares · un viaje",
    delivery: "600 entregados",
    action: "Pedido cerrado.",
    lines: [{ id: "azucitrus-75-1", product: "Pallet 120 × 100", quantity: 600 }],
    source: "Plan semanal · fila 75",
  },
  {
    id: "san-miguel-76",
    reference: "Plan 76",
    client: "San Miguel",
    product: "Dos medidas de pallets",
    requested: 360,
    delivered: 360,
    pending: 0,
    stage: "completado",
    dateLabel: "Viernes 14",
    transport: "Milton",
    supply: "Dos líneas completas",
    preparation: "250 de 120 × 120 · 110 de 116,5 × 114",
    logistics: "Milton · un viaje",
    delivery: "360 entregados",
    action: "Pedido cerrado.",
    lines: [
      { id: "san-miguel-76-1", product: "Pallet 120 × 120", quantity: 250 },
      { id: "san-miguel-76-2", product: "Pallet 116,5 × 114", quantity: 110 },
    ],
    source: "Plan semanal · fila 76",
  },
  {
    id: "pontevedra-79",
    reference: "Plan 79",
    client: "Pontevedra",
    product: "Pallet Mercosur con HT",
    requested: 150,
    delivered: 150,
    pending: 0,
    stage: "completado",
    dateLabel: "Sábado 15",
    transport: "Matías",
    supply: "Pedido completo",
    preparation: "Mercosur con HT",
    logistics: "Matías · un viaje",
    delivery: "150 entregados",
    action: "Pedido cerrado.",
    lines: [{ id: "pontevedra-79-1", product: "Pallet Mercosur", quantity: 150, preparation: "Con HT" }],
    source: "Plan semanal · fila 79",
  },
];
