import type { Transaction } from "./types";

export const transactions: Transaction[] = [
  { id: "t1", date: "27 ago", description: "Nómina mensual", account: "Santander", category: "Ingresos", amount: 48200, flow: "income" },
  { id: "t2", date: "26 ago", description: "Pago de tarjeta", account: "Santander → Amex", category: "Transferencia", amount: -19405, flow: "transfer" },
  { id: "t3", date: "24 ago", description: "Supermercado", account: "Amex", category: "Alimentos", amount: -1842.7, flow: "expense" },
  { id: "t4", date: "23 ago", description: "Reserva de viaje", account: "Amex", category: "Viajes", amount: -6270, flow: "expense" },
  { id: "t5", date: "22 ago", description: "Traspaso a ahorro", account: "Santander → BBVA", category: "Transferencia", amount: -6500, flow: "transfer" },
  { id: "t6", date: "21 ago", description: "Restaurante", account: "Amex", category: "Comidas", amount: -920, flow: "expense" },
  { id: "t7", date: "20 ago", description: "Suscripciones", account: "Amex", category: "Servicios", amount: -648, flow: "expense" },
];

export const categories = ["Alimentos", "Viajes", "Comidas", "Servicios", "Transporte", "Salud", "Compras", "Sin categoría"];

