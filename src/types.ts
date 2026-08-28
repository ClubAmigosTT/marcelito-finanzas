export type Section = "Inicio" | "Movimientos" | "Gastos" | "Cuentas" | "Patrimonio";

export type FlowType = "income" | "transfer" | "expense" | "debt";

export type Transaction = {
  id: string;
  date: string;
  description: string;
  account: string;
  category: string;
  amount: number;
  flow: FlowType;
  confidence?: number;
};

export type ImportResult = {
  source: "Amex" | "Santander" | "Desconocido";
  period: string;
  mode: "text" | "ocr";
  transactions: Transaction[];
};

