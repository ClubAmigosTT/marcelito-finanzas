export type Section = "Inicio" | "Movimientos" | "Gastos" | "Cuentas" | "Patrimonio";

export type FlowType = "income" | "transfer" | "expense" | "debt";

export type StatementSource = "Amex" | "Santander" | "BBVA" | "Desconocido";

export type StatementStatus = "ready" | "review";

export type Transaction = {
  id: string;
  date: string;
  description: string;
  account: string;
  category: string;
  amount: number;
  flow: FlowType;
  confidence?: number;
  statementId?: string;
};

export type ImportResult = {
  source: StatementSource;
  period: string;
  fileName: string;
  mode: "text" | "ocr";
  transactions: Transaction[];
};

export type Statement = {
  id: string;
  source: StatementSource;
  period: string;
  fileName: string;
  importedAt: string;
  mode: ImportResult["mode"];
  transactionCount: number;
  status: StatementStatus;
};

export type ImportCommit = {
  source: StatementSource;
  period: string;
  fileName: string;
  mode: ImportResult["mode"];
  transactions: Transaction[];
};
