import { useEffect, useMemo, useRef, useState } from "react";
import {
  ArrowDown,
  ArrowRight,
  ArrowsLeftRight,
  Bank,
  Bell,
  ChartDonut,
  ChartLineUp,
  Check,
  CheckCircle,
  CircleNotch,
  CreditCard,
  FilePdf,
  House,
  ListMagnifyingGlass,
  LockKey,
  PencilSimple,
  Plus,
  Receipt,
  ShieldCheck,
  SignOut,
  Trash,
  UploadSimple,
  User,
  Wallet,
  Warning,
  X,
} from "@phosphor-icons/react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { categories } from "./data";
import { createAuditRun } from "./audit";
import { buildFinanceMetrics, defaultStatementKind, isSpendTransaction, type AnalyticsPeriod, type CashFlowPoint, type ExecutiveAlert, type ProjectionMonth, type TravelTrip } from "./finance";
import { gateOcrReconciliation, inspectPdf, reconcileStatementImport } from "./pdfImport";
import { categoryFromRules, merchantKey, type CategoryRules } from "./categoryRules";
import { normalizeConcept, runTransactionPipeline, statementPeriodEndTimestamp, transactionPeriodKey } from "./reconciliation";
import type { AuditRunRecord, FinancialGoal, FinancialGoalKind, ImportCommit, ImportResult, Section, Statement, StatementKind, StatementSource, StatementSummary, Transaction } from "./types";

const money = new Intl.NumberFormat("es-MX", { style: "currency", currency: "MXN", maximumFractionDigits: 0 });
const moneyPrecise = new Intl.NumberFormat("es-MX", { style: "currency", currency: "MXN", minimumFractionDigits: 2 });
const transactionStorageKey = "marcelito-transactions.v2";
const statementStorageKey = "marcelito-statements.v1";
const categoryRulesStorageKey = "marcelito-category-rules.v1";
const goalsStorageKey = "marcelito-goals.v1";
const auditStorageKey = "marcelito-audit.last.v1";
type LocalAccount = { username: string; passwordHash: string };
const seededAccount: LocalAccount = { username: "Marcelodiazs", passwordHash: "ed6357244f855d10e821359702d859df700ba81431a98b88ba1de5156a1e9f61" };

function latestStatementFor(statements: Statement[]) {
  return statements.slice().sort((left, right) => {
    const byCutoff = statementPeriodEndTimestamp(right.period, right.importedAt) - statementPeriodEndTimestamp(left.period, left.importedAt);
    return byCutoff || right.importedAt.localeCompare(left.importedAt) || right.id.localeCompare(left.id);
  })[0];
}

function prepareStoredStatements(statements: Statement[]) {
  // Imports created before issuer-total reconciliation existed cannot be
  // trusted retroactively: their raw rows may already contain the old parser
  // errors. Keep them visible for audit, but require a fresh import before
  // they can feed executive KPIs.
  return statements.map((statement) => statement.reconciliationStatus
    ? statement
    : {
      ...statement,
      reconciliationStatus: "pending" as const,
      reconciliation: {
        status: "pending" as const,
        tolerance: 0.05,
        reason: "Estado importado antes de la conciliación automática; vuelve a importarlo para usarlo en los KPI.",
      },
    });
}

async function passwordDigest(username: string, password: string) {
  const bytes = new TextEncoder().encode(`${username}:${password}`);
  const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function readLocalAccount(): LocalAccount | null {
  if (localStorage.getItem("marcelito-account-deleted") === "1") return null;
  try {
    const saved = JSON.parse(localStorage.getItem("marcelito-account") ?? "null") as LocalAccount | null;
    return saved?.username && saved.passwordHash ? saved : seededAccount;
  } catch {
    return seededAccount;
  }
}

function saveLocalAccount(account: LocalAccount) {
  localStorage.setItem("marcelito-account", JSON.stringify(account));
  localStorage.removeItem("marcelito-account-deleted");
}

function deleteLocalAccount() {
  localStorage.removeItem("marcelito-account");
  localStorage.setItem("marcelito-account-deleted", "1");
  localStorage.removeItem("marcelito-profile");
  localStorage.removeItem("marcelito-transactions");
  localStorage.removeItem(transactionStorageKey);
  localStorage.removeItem(statementStorageKey);
  localStorage.removeItem(categoryRulesStorageKey);
  localStorage.removeItem(goalsStorageKey);
}

function clearLocalSession() {
  localStorage.removeItem("marcelito-profile");
}

function readStored<T>(key: string, fallback: T): T {
  try {
    const value = JSON.parse(localStorage.getItem(key) ?? "null") as T | null;
    return value ?? fallback;
  } catch {
    return fallback;
  }
}

function createId(prefix: string) {
  if (globalThis.crypto?.randomUUID) return `${prefix}-${globalThis.crypto.randomUUID()}`;
  return `${prefix}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function displayMoney(value: number | undefined | null) {
  return value === undefined || value === null || !Number.isFinite(value) ? "Pendiente" : money.format(value);
}

function dashboardMoney(blocked: boolean, value: number | undefined | null) {
  return blocked ? "Bloqueado por conciliación" : displayMoney(value);
}

function displayPercent(value: number | null | undefined) {
  return value === undefined || value === null || !Number.isFinite(value) ? "Pendiente" : `${Math.round(value * 100)}%`;
}

function comparisonPercent(value: number | null | undefined) {
  if (value === undefined || value === null || !Number.isFinite(value)) return "Sin comparativo";
  const percent = Math.round(Math.abs(value) * 100);
  return `${value >= 0 ? "+" : "−"}${percent}% vs. mes anterior`;
}

function comparisonMoney(current: number | undefined, previous: number | undefined) {
  if (current === undefined || previous === undefined) return "Sin comparativo";
  const delta = current - previous;
  return `${delta >= 0 ? "+" : "−"}${money.format(Math.abs(delta))} vs. mes anterior`;
}

function signedMoney(value: number | undefined | null) {
  if (value === undefined || value === null || !Number.isFinite(value)) return "Pendiente";
  return money.format(value);
}

function signedDeltaMoney(value: number | undefined | null) {
  if (value === undefined || value === null || !Number.isFinite(value)) return "Pendiente";
  return `${value >= 0 ? "+" : "−"}${money.format(Math.abs(value))}`;
}

function periodLabel(period?: AnalyticsPeriod) {
  return period?.label ?? "Periodo actual";
}

function compactMerchantName(description: string) {
  return description
    .replace(/\s+/g, " ")
    .replace(/\b(?:aut\.?|ref\.?|folio|no\.?|num\.?)\s*[:#-]?\s*[a-z0-9-]+/gi, "")
    .trim()
    .slice(0, 46) || "Sin descripción";
}

function statementDate(statement: Statement) {
  return new Intl.DateTimeFormat("es-MX", { dateStyle: "medium" }).format(new Date(statement.importedAt));
}

function statementOcrPageLabel(statement: Statement) {
  const pages = statement.ocrPageConfidences;
  if (!pages?.length) return "";
  return ` · página mínima ${Math.round(Math.min(...pages) * 100)}%`;
}

function statementLabel(statement?: Statement) {
  if (!statement) return "Movimiento manual";
  return `${statement.source} · ${statement.period}`;
}

function sourceColor(source: StatementSource) {
  return source === "Amex" ? "statement-amex" : source === "Santander" ? "statement-santander" : source === "BBVA" ? "statement-bbva" : "statement-unknown";
}

const navItems: { label: Section; icon: typeof House }[] = [
  { label: "Resumen", icon: House },
  { label: "Gastos", icon: ChartDonut },
  { label: "Cuentas", icon: CreditCard },
  { label: "Patrimonio", icon: ChartLineUp },
];

function AuthGate({ onEnter }: { onEnter: (name: string) => void }) {
  const [mode, setMode] = useState<"login" | "create">("login");
  const [name, setName] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (name.trim().length < 3 || password.length < 6) {
      setError("Usa un nombre de al menos 3 caracteres y una contraseña de 6 o más.");
      return;
    }
    setBusy(true);
    setError("");
    const username = name.trim();
    try {
      const account = readLocalAccount();
      const hash = await passwordDigest(account?.username ?? username, password);
      if (mode === "login") {
        if (!account || account.username.toLowerCase() !== username.toLowerCase() || account.passwordHash !== hash) {
          setError("Usuario o contraseña no válidos.");
          return;
        }
        localStorage.setItem("marcelito-profile", JSON.stringify({ name: account.username }));
        onEnter(account.username);
      } else {
        if (account) {
          setError("Ya existe un usuario en este dispositivo. Entra con él o elimínalo desde tu perfil.");
          return;
        }
        saveLocalAccount({ username, passwordHash: hash });
        localStorage.setItem("marcelito-profile", JSON.stringify({ name: username }));
        onEnter(username);
      }
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="auth-shell">
      <section className="auth-story" aria-label="Presentación de Marcelito">
        <div className="brand brand-large"><img className="brand-mark" src="/icons/icon-192.png" alt="" /><span>Marcelito</span></div>
        <div className="auth-message">
          <p className="auth-kicker">Tus cuentas, una sola historia</p>
          <h1>Entiende el camino completo de tu dinero.</h1>
          <p>Marcelito conecta ingresos, transferencias, deuda y gasto real para que cada decisión tenga contexto.</p>
        </div>
        <div className="auth-flow" aria-hidden="true">
          <span className="flow-segment income-segment" /><span className="flow-segment transfer-segment" /><span className="flow-segment debt-segment" /><span className="flow-segment expense-segment" />
        </div>
      </section>
      <section className="auth-panel">
        <form onSubmit={submit} className="auth-form">
          <div className="mobile-brand brand"><img className="brand-mark" src="/icons/icon-192.png" alt="" /><span>Marcelito</span></div>
          <div>
            <h2>{mode === "create" ? "Crea tu acceso" : "Bienvenido de nuevo"}</h2>
            <p>{mode === "create" ? "Tus datos se guardan localmente en este dispositivo." : "Entra a tu panorama financiero personal."}</p>
          </div>
          <label>
            Usuario
            <div className="input-wrap"><User size={18} /><input value={name} onChange={(event) => setName(event.target.value)} autoComplete="username" placeholder="Tu nombre de usuario" /></div>
          </label>
          <label>
            Contraseña
            <div className="input-wrap"><LockKey size={18} /><input type="password" value={password} onChange={(event) => setPassword(event.target.value)} autoComplete={mode === "create" ? "new-password" : "current-password"} placeholder="Mínimo 6 caracteres" /></div>
          </label>
          {error && <p className="form-error" role="alert"><Warning size={17} />{error}</p>}
          <button className="primary-button wide" type="submit" disabled={busy}>{mode === "create" ? "Crear acceso" : "Entrar"}<ArrowRight size={18} /></button>
          <button className="text-button" type="button" onClick={() => { setMode(mode === "login" ? "create" : "login"); setError(""); }}>
            {mode === "login" ? "Crear un usuario" : "Ya tengo un usuario"}
          </button>
          <p className="privacy-note"><ShieldCheck size={17} /> <span>Marcelito no envía tus estados de cuenta a servicios externos.</span> <a href="/privacy.html">Política de privacidad</a></p>
        </form>
      </section>
    </main>
  );
}

function AppShell({ user, onSignOut, onDeleteAccount }: { user: string; onSignOut: () => void; onDeleteAccount: () => void }) {
  const [section, setSection] = useState<Section>("Resumen");
  const [transactions, setTransactions] = useState<Transaction[]>(() => readStored(transactionStorageKey, []));
  const [statements, setStatements] = useState<Statement[]>(() => prepareStoredStatements(readStored<Statement[]>(statementStorageKey, [])));
  const [categoryRules, setCategoryRules] = useState<CategoryRules>(() => readStored(categoryRulesStorageKey, {}));
  const [goals, setGoals] = useState<FinancialGoal[]>(() => readStored(goalsStorageKey, []));
  const [lastAuditRun, setLastAuditRun] = useState<AuditRunRecord | null>(() => readStored<AuditRunRecord | null>(auditStorageKey, null));
  const [importOpen, setImportOpen] = useState(false);
  const reduceMotion = useReducedMotion();
  const latestStatement = latestStatementFor(statements);
  const pipeline = useMemo(() => runTransactionPipeline(transactions, statements), [transactions, statements]);
  const ledgerTransactions = useMemo(() => pipeline.transactions.filter((transaction) => {
    if (!transaction.statementId) return true;
    const statement = statements.find((item) => item.id === transaction.statementId);
    // Reconciliation is necessary but not sufficient for scanned/uncertain
    // imports. A statement marked for review stays out of every KPI until the
    // user confirms it from Cuentas > Documentos importados.
    return statement?.reconciliationStatus === "valid" && statement.status !== "review";
  }), [pipeline, statements]);
  // All screens receive the same post-pipeline ledger. Raw extracted rows are
  // retained only for audit/reprocessing and are never an aggregate source.
  const metrics = useMemo(() => buildFinanceMetrics(ledgerTransactions, statements, pipeline), [ledgerTransactions, statements, pipeline]);

  useEffect(() => {
    localStorage.setItem(transactionStorageKey, JSON.stringify(transactions));
  }, [transactions]);

  useEffect(() => {
    localStorage.setItem(statementStorageKey, JSON.stringify(statements));
  }, [statements]);

  useEffect(() => {
    localStorage.setItem(categoryRulesStorageKey, JSON.stringify(categoryRules));
  }, [categoryRules]);

  useEffect(() => {
    localStorage.setItem(goalsStorageKey, JSON.stringify(goals));
  }, [goals]);

  // Persist one deterministic audit record per ledger generation. The
  // fingerprint prevents render loops and makes it possible to correlate a
  // production report with the exact canonical rows that were shown.
  const auditedFingerprint = useRef("");
  useEffect(() => {
    const next = createAuditRun(pipeline, statements, ledgerTransactions, lastAuditRun ? "foreground" : "startup");
    if (next.ledgerFingerprint === auditedFingerprint.current && lastAuditRun?.status === next.status) return;
    auditedFingerprint.current = next.ledgerFingerprint;
    setLastAuditRun(next);
    localStorage.setItem(auditStorageKey, JSON.stringify(next));
  }, [pipeline, statements, ledgerTransactions, lastAuditRun]);

  function saveImport(commit: ImportCommit) {
    // An issuer-total mismatch is not safe to merge into an existing ledger.
    // The review dialog normally blocks this path, but keep the guard here so
    // programmatic callers cannot bypass the quality gate.
    if (commit.reconciliation && commit.reconciliation.status !== "valid") return;
    // The same PDF may have been imported before with a wrong bank label.
    // Match by filename first so a corrected detection replaces that record
    // instead of leaving a stale duplicate in the account ledger.
    const previous = statements.find((item) => item.fileName === commit.fileName);
    const statementId = previous?.id ?? createId("statement");
    const importedAt = new Date().toISOString();
    const importedTransactions = commit.transactions
      .filter((item) => item.description.trim().length >= 3 && Number.isFinite(item.amount) && item.amount !== 0)
      .map((item, index) => ({ ...item, id: `${statementId}-${index}-${item.id}`, statementId }));
    const statement: Statement = {
      id: statementId,
      source: commit.source,
      period: commit.period,
      fileName: commit.fileName,
      importedAt,
      mode: commit.mode,
      transactionCount: importedTransactions.length,
      status: "review",
      kind: commit.kind ?? previous?.kind ?? defaultStatementKind(commit.source),
      summary: commit.summary,
      reconciliationStatus: commit.reconciliation?.status,
      reconciliation: commit.reconciliation,
      sourceDetection: commit.sourceDetection,
      ocrConfidence: commit.ocrConfidence,
      ocrPageConfidences: commit.ocrPageConfidences,
    };
    const nextStatements = previous
      ? statements.map((item) => item.id === statementId ? statement : item)
      : [statement, ...statements];
    const withoutPrevious = previous ? transactions.filter((item) => item.statementId !== statementId) : transactions;
    const importedPipeline = runTransactionPipeline([...importedTransactions, ...withoutPrevious], nextStatements);
    const needsReview = importedTransactions.some((item) => item.category === "Sin categoría" || (item.confidence ?? 1) < 0.75)
      || commit.source === "Desconocido"
      || commit.kind === "unknown"
      || commit.sourceDetection?.status !== "verified"
      // Browser OCR currently returns flattened text without coordinates;
      // keep scanned imports provisional until the user confirms their rows.
      || commit.mode === "ocr"
      || importedPipeline.audit.criticalIssues.length > 0;
    statement.status = importedTransactions.length && !needsReview ? "ready" : "review";
    statement.transactionCount = importedPipeline.transactions.filter((item) => item.statementId === statementId).length;

    if (commit.categoryRules && Object.keys(commit.categoryRules).length) {
      setCategoryRules((current) => ({ ...current, ...commit.categoryRules }));
    }

    setStatements(nextStatements);
    // Keep the raw extracted rows so the next pipeline run can explain
    // rejected/admin rows and cross-statement duplicates in the audit view.
    // All KPI and screen consumers use `ledgerTransactions` (the canonical
    // pipeline output), never this raw collection directly.
    setTransactions([...importedTransactions, ...withoutPrevious]);
    setImportOpen(false);
  }

  function markStatementReviewed(statementId: string) {
    setStatements((current) => current.map((item) => item.id === statementId ? { ...item, status: "ready" } : item));
  }

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand"><img className="brand-mark" src="/icons/icon-192.png" alt="" /><span>Marcelito</span></div>
        <nav aria-label="Navegación principal">
          {navItems.map(({ label, icon: Icon }) => (
            <button key={label} className={section === label ? "nav-item active" : "nav-item"} onClick={() => setSection(label)} aria-current={section === label ? "page" : undefined}>
              <Icon size={20} weight={section === label ? "fill" : "regular"} /><span>{label}</span>
            </button>
          ))}
        </nav>
        <div className="side-profile">
          <div className="avatar">{user.slice(0, 1).toUpperCase()}</div>
          <div><strong>{user}</strong><span>Perfil personal</span></div>
          <button aria-label="Eliminar cuenta" onClick={onDeleteAccount}><Trash size={18} /></button>
          <button aria-label="Cerrar sesión" onClick={onSignOut}><SignOut size={18} /></button>
        </div>
      </aside>
      <main className="main-content">
        <header className="topbar">
          <div><span className="context-title">{section}</span><span className="sync-status"><CheckCircle size={15} weight="fill" /> {latestStatement ? `Última carga: ${latestStatement.period}` : "Sin estados importados"}</span></div>
          <div className="top-actions">
            <button className="icon-button mobile-profile-action" aria-label="Eliminar cuenta" onClick={onDeleteAccount}><Trash size={20} /></button>
            <button className="icon-button" aria-label="Notificaciones"><Bell size={20} /></button>
            <button className="primary-button" onClick={() => setImportOpen(true)}><UploadSimple size={18} />Importar estado</button>
          </div>
        </header>
        <AnimatePresence mode="wait">
          <motion.div key={section} className="page" initial={reduceMotion ? false : { opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={reduceMotion ? undefined : { opacity: 0, y: -4 }} transition={{ duration: 0.2, ease: [0.16, 1, 0.3, 1] }}>
            {section === "Resumen" && <Home transactions={ledgerTransactions} statements={statements} metrics={metrics} goals={goals} setGoals={setGoals} auditRun={lastAuditRun} onImport={() => setImportOpen(true)} />}
            {section === "Gastos" && <Expenses transactions={ledgerTransactions} statements={statements} metrics={metrics} onImport={() => setImportOpen(true)} />}
            {section === "Cuentas" && <Accounts transactions={ledgerTransactions} statements={statements} metrics={metrics} setTransactions={setTransactions} onImport={() => setImportOpen(true)} onMarkReviewed={markStatementReviewed} onLearnCategory={(description, category) => setCategoryRules((current) => { const key = merchantKey(description); if (!key) return current; if (category === "Sin categoría") { const next = { ...current }; delete next[key]; return next; } return { ...current, [key]: category }; })} />}
            {section === "Patrimonio" && <NetWorth metrics={metrics} />}
          </motion.div>
        </AnimatePresence>
      </main>
      <nav className="mobile-nav" aria-label="Navegación principal móvil">
        {navItems.map(({ label, icon: Icon }) => <button key={label} className={section === label ? "active" : ""} onClick={() => setSection(label)}><Icon size={21} weight={section === label ? "fill" : "regular"} /><span>{label}</span></button>)}
      </nav>
      <ImportDialog open={importOpen} onClose={() => setImportOpen(false)} onSave={saveImport} categoryRules={categoryRules} />
    </div>
  );
}

type DashboardMetricKey = "patrimony" | "cash" | "debt" | "expense" | "flow";
type MetricSeriesPoint = { key: string; label: string; value: number };

function Home({ transactions, statements, metrics, goals, setGoals, auditRun, onImport }: { transactions: Transaction[]; statements: Statement[]; metrics: ReturnType<typeof buildFinanceMetrics>; goals: FinancialGoal[]; setGoals: React.Dispatch<React.SetStateAction<FinancialGoal[]>>; auditRun: AuditRunRecord | null; onImport: () => void }) {
  const [selectedMetric, setSelectedMetric] = useState<DashboardMetricKey | null>(null);
  if (!transactions.length && !statements.length) return <RealDataEmpty onImport={onImport} />;

  const trend = metrics.liquidPatrimonyChangePercent;
  const trendLabel = comparisonPercent(trend);
  const trendTone = trend === null ? "" : trend >= 0 ? "positive" : "negative";
  const latestPeriodLabel = latestStatementFor(statements)?.period ?? periodLabel(metrics.analyticsPeriods[0]);

  return (
    <>
      <CFOBrief metrics={metrics} />
      {metrics.isProvisional && <div className="provisional-banner" role="status"><Warning size={18} /><span>Estos KPI son provisionales hasta corregir los movimientos señalados en Calidad de datos / conciliación.</span></div>}
      <section className="summary-heading">
        <div><p className="summary-eyebrow">Tu situación financiera</p><h1>Una lectura clara de tu dinero.</h1><p>Actualizado con tus estados y movimientos reales.</p></div>
        <span className="month-button data-period">{latestPeriodLabel}</span>
      </section>
      <button type="button" className="summary-hero summary-hero-action" aria-label="Ver detalle del patrimonio líquido" onClick={() => setSelectedMetric("patrimony")}>
        <div><span>Patrimonio líquido</span><strong>{dashboardMoney(metrics.isProvisional, metrics.liquidPatrimony)}</strong><p className={`summary-trend ${trendTone}`}>{metrics.isProvisional ? "Conciliación requerida" : trendLabel}</p></div>
      </button>
      <section className="summary-kpis" aria-label="Indicadores principales">
        <Metric label="Efectivo disponible" value={dashboardMoney(metrics.isProvisional, metrics.cashAvailable)} delta={metrics.isProvisional ? "Conciliación requerida" : comparisonMoney(metrics.cashAvailable, metrics.analyticsPeriods[1]?.cashAvailable)} tone="income" icon={Wallet} onSelect={() => setSelectedMetric("cash")} />
        <Metric label="Deuda total" value={dashboardMoney(metrics.isProvisional, metrics.debtTotal)} delta={metrics.isProvisional ? "Conciliación requerida" : comparisonMoney(metrics.debtTotal, metrics.analyticsPeriods[1]?.debtTotal)} tone="debt" icon={CreditCard} onSelect={() => setSelectedMetric("debt")} />
        <Metric label="Gasto del mes" value={dashboardMoney(metrics.isProvisional, metrics.currentMonthSpend)} delta={metrics.isProvisional ? "Conciliación requerida" : comparisonPercent(metrics.analyticsPeriods[0]?.variationPercent)} tone="expense" icon={Receipt} onSelect={() => setSelectedMetric("expense")} />
        <Metric label="Flujo neto" value={dashboardMoney(metrics.isProvisional, metrics.currentMonthNetFlow)} delta={metrics.isProvisional ? "Conciliación requerida" : comparisonMoney(metrics.currentMonthNetFlow, metrics.analyticsPeriods[1]?.netFlow)} tone={metrics.currentMonthNetFlow >= 0 ? "income" : "debt"} icon={ChartLineUp} onSelect={() => setSelectedMetric("flow")} />
      </section>
      {selectedMetric && <MetricDetailPanel metric={selectedMetric} metrics={metrics} onClose={() => setSelectedMetric(null)} />}
      {metrics.isProvisional ? <DashboardBlockedNotice metrics={metrics} /> : <>
        <ExecutiveSummary metrics={metrics} />
        <SpendTrendChart periods={metrics.analyticsPeriods} />
        <CashFlowTrendChart points={metrics.cashFlowHistory} />
        <SpendingSplit period={metrics.analyticsPeriods[0]} />
        <DebtBreakdown metrics={metrics} />
        <ProjectionPanel projection={metrics.projection} />
        <ScenarioSimulator metrics={metrics} />
        <ExecutiveAlerts alerts={metrics.executiveAlerts} />
        <GoalsPanel metrics={metrics} goals={goals} setGoals={setGoals} />
      </>}
      <DataQualityIndicator metrics={metrics} />
      <AuditDiagnostics metrics={metrics} auditRun={auditRun} />
    </>
  );
}

function CFOBrief({ metrics }: { metrics: ReturnType<typeof buildFinanceMetrics> }) {
  const current = metrics.analyticsPeriods[0];
  const risk = metrics.executiveAlerts[0];
  const situation = current ? `Gastaste ${displayMoney(current.spend)} y tu flujo neto fue ${displayMoney(current.netFlow)}.` : "Todavía no hay suficiente historial para explicar tu situación.";
  const riskText = risk?.title ?? "No hay un riesgo ejecutivo relevante detectado";
  const action = risk?.action ?? "Mantén el ritmo y revisa tu proyección de 90 días.";
  return <section className="cfo-brief" aria-labelledby="cfo-brief-title"><div className="cfo-brief-label"><span className="cfo-brief-mark">CFO</span><div><h2 id="cfo-brief-title">CFO Brief</h2><small>La decisión financiera más importante del momento.</small></div></div><p><strong>Situación:</strong> {situation} <strong>Riesgo:</strong> {riskText}. <strong>Acción:</strong> {action}</p></section>;
}

function ProjectionPanel({ projection }: { projection: ReturnType<typeof buildFinanceMetrics>["projection"] }) {
  const horizons: Array<{ label: string; period: ProjectionMonth; tone: string }> = [
    { label: "3 meses", period: projection.horizon3, tone: "short" },
    { label: "6 meses", period: projection.horizon6, tone: "medium" },
    { label: "12 meses", period: projection.horizon12, tone: "long" },
  ];
  return <section className="projection-panel" aria-labelledby="projection-title"><div className="section-heading"><div><h2 id="projection-title">Próximos 90 días</h2><p>Qué podría pasar si mantienes tu comportamiento reciente.</p></div><span className="estimate-badge">Estimación</span></div><div className="projection-table" role="table" aria-label="Proyección de los próximos 90 días"><div className="projection-row projection-head" role="row"><span>Periodo</span><span>Ingresos</span><span>Gasto fijo</span><span>Pagos / MSI</span><span>Liquidez</span><span>Patrimonio</span></div>{projection.next90Days.map((period) => <div className="projection-row" role="row" key={period.key}><strong>{period.label}</strong><span>{displayMoney(period.expectedIncome)}</span><span>{displayMoney(period.fixedSpend)}</span><span>{displayMoney(period.projectedPayments)}<small>{period.projectedMsi ? `MSI ${displayMoney(period.projectedMsi)}` : ""}</small></span><span>{displayMoney(period.projectedLiquidity)}</span><span>{displayMoney(period.projectedPatrimony)}</span></div>)}</div><div className="projection-horizons"><div className="section-heading"><div><h3>Proyección de largo plazo</h3><p>Gasto, ahorro, deuda y patrimonio estimados.</p></div></div><div className="projection-horizon-grid">{horizons.map(({ label, period, tone }) => <article className={`projection-horizon horizon-${tone}`} key={label}><span>{label}</span><strong>{displayMoney(period.projectedPatrimony)}</strong><small>Patrimonio estimado</small><div><span>Gasto acumulado</span><b>{displayMoney(period.projectedSpend * period.monthOffset)}</b></div><div><span>Ahorro acumulado</span><b>{displayMoney(period.projectedSavings * period.monthOffset)}</b></div><div><span>Deuda</span><b>{displayMoney(period.projectedDebt)}</b></div></article>)}</div></div><p className="estimate-note">{projection.assumption}</p></section>;
}

type ScenarioResult = {
  payment: number;
  remainingDebt: number;
  interestEstimated: number;
  cashAvailable: number | undefined;
  utilizationRate: number | undefined;
  liquidationMonths: number;
  liquidationLabel: string;
  liquidPatrimony: number | undefined;
  patrimonyGain: number;
};

function ScenarioSimulator({ metrics }: { metrics: ReturnType<typeof buildFinanceMetrics> }) {
  const debt = metrics.debtTotal ?? 0;
  const minimum = Math.min(debt, metrics.latestMinimumPayment ?? (debt ? debt * 0.05 : 0));
  const noInterest = Math.min(debt, metrics.latestPaymentForNoInterest ?? debt);
  const [scenarioA, setScenarioA] = useState(minimum);
  const [scenarioB, setScenarioB] = useState(noInterest);
  const monthlyRate = debt > 0 && metrics.latestInterest ? Math.min(0.05, Math.max(0.005, metrics.latestInterest / debt)) : 0.02;
  useEffect(() => {
    setScenarioA((current) => current === 0 ? minimum : current);
    setScenarioB((current) => current === 0 ? noInterest : current);
  }, [minimum, noInterest]);

  function simulate(paymentValue: number, baselineInterest: number): ScenarioResult {
    const payment = Math.min(debt, Math.max(0, Number.isFinite(paymentValue) ? paymentValue : 0));
    const remainingDebt = Math.max(0, debt - payment);
    let balance = remainingDebt;
    let interestEstimated = 0;
    let liquidationMonths = 0;
    while (balance > 0.5 && liquidationMonths < 120) {
      const interest = balance * monthlyRate;
      interestEstimated += interest;
      balance = Math.max(0, balance + interest - payment);
      liquidationMonths += 1;
      if (payment <= interest && liquidationMonths === 120) break;
    }
    const liquidationLabel = balance > 0.5 ? ">10 años" : liquidationMonths === 0 ? "Este mes" : `En ${liquidationMonths} meses`;
    const cashAvailable = metrics.cashAvailable === undefined ? undefined : metrics.cashAvailable - payment;
    const utilizationRate = metrics.creditLimit ? Math.max(0, (metrics.creditUsed ?? debt) - payment) / metrics.creditLimit : undefined;
    return { payment, remainingDebt, interestEstimated, cashAvailable, utilizationRate, liquidationMonths, liquidationLabel, liquidPatrimony: metrics.liquidPatrimony, patrimonyGain: baselineInterest - interestEstimated };
  }

  const baseline = simulate(minimum, 0);
  const resultA = simulate(scenarioA, baseline.interestEstimated);
  const resultB = simulate(scenarioB, baseline.interestEstimated);
  const winner = (metric: "cashAvailable" | "interestEstimated" | "patrimonyGain") => {
    const left = resultA[metric];
    const right = resultB[metric];
    if (left === undefined || right === undefined || left === right) return 0;
    const leftWins = metric === "interestEstimated" ? left < right : left > right;
    return leftWins ? 1 : -1;
  };
  return <section className="scenario-panel" aria-labelledby="scenario-title"><div className="section-heading"><div><h2 id="scenario-title">Simulador de escenarios</h2><p>Compara cuánto pagar y el impacto probable en tu deuda y liquidez.</p></div><span className="estimate-badge">Estimación</span></div>{debt ? <><div className="scenario-controls"><ScenarioControl label="Escenario A" value={scenarioA} minimum={minimum} noInterest={noInterest} onChange={setScenarioA} /><ScenarioControl label="Escenario B" value={scenarioB} minimum={minimum} noInterest={noInterest} onChange={setScenarioB} /></div><div className="scenario-grid"><ScenarioCard label="Escenario A" result={resultA} cashWinner={winner("cashAvailable") === 1} interestWinner={winner("interestEstimated") === 1} patrimonyWinner={winner("patrimonyGain") === 1} /><ScenarioCard label="Escenario B" result={resultB} cashWinner={winner("cashAvailable") === -1} interestWinner={winner("interestEstimated") === -1} patrimonyWinner={winner("patrimonyGain") === -1} /></div><p className="estimate-note">El interés se estima con la tasa observada en tu último corte; si no existe, se usa una referencia del 2% mensual. El pago reduce efectivo y deuda por el mismo importe, por eso el patrimonio inmediato no cambia.</p></> : <EmptyState title="Sin deuda para simular" body="Completa la deuda al corte en Cuentas para comparar opciones de pago." />}</section>;
}

function ScenarioControl({ label, value, minimum, noInterest, onChange }: { label: string; value: number; minimum: number; noInterest: number; onChange: (value: number) => void }) {
  return <div className="scenario-control"><strong>{label}</strong><div className="scenario-presets"><button className="text-button" onClick={() => onChange(minimum)}>Pago mínimo</button><button className="text-button" onClick={() => onChange(noInterest)}>No generar intereses</button></div><label><span>Monto personalizado</span><div className="scenario-input"><span>$</span><input type="number" min="0" step="100" value={Math.round(value)} onChange={(event) => onChange(Number(event.target.value))} /></div></label></div>;
}

function ScenarioCard({ label, result, cashWinner, interestWinner, patrimonyWinner }: { label: string; result: ScenarioResult; cashWinner: boolean; interestWinner: boolean; patrimonyWinner: boolean }) {
  return <article className="scenario-card"><div className="scenario-card-head"><div><span>{label}</span><strong>{displayMoney(result.payment)}</strong></div><small>Pago elegido</small></div><div className="scenario-outcomes"><div><span>Deuda restante</span><strong>{displayMoney(result.remainingDebt)}</strong></div><div className={cashWinner ? "scenario-winner" : ""}><span>Efectivo disponible</span><strong>{displayMoney(result.cashAvailable)}</strong>{cashWinner && <small>Más liquidez</small>}</div><div className={interestWinner ? "scenario-winner" : ""}><span>Intereses estimados</span><strong>{displayMoney(result.interestEstimated)}</strong>{interestWinner && <small>Menos intereses</small>}</div><div><span>Liquidación probable</span><strong>{result.liquidationLabel}</strong></div><div><span>Uso de crédito</span><strong>{result.utilizationRate === undefined ? "Pendiente" : `${Math.round(result.utilizationRate * 100)}%`}</strong></div><div className={patrimonyWinner ? "scenario-winner" : ""}><span>Patrimonio líquido</span><strong>{displayMoney(result.liquidPatrimony)}</strong><small>{patrimonyWinner ? "Mejor impacto futuro" : `${signedDeltaMoney(result.patrimonyGain)} vs pago mínimo`}</small></div></div></article>;
}

function ExecutiveAlerts({ alerts }: { alerts: ExecutiveAlert[] }) {
  return <section className="alerts-panel" aria-labelledby="alerts-title"><div className="section-heading"><div><h2 id="alerts-title">Alertas ejecutivas</h2><p>Señales que pueden cambiar tu próxima decisión.</p></div></div>{alerts.length ? <div className="alert-list">{alerts.map((alert) => <article className={`executive-alert alert-${alert.severity}`} key={alert.id}><span className="alert-dot" /><div><strong>{alert.title}</strong><p>{alert.body}</p><small>{alert.action}</small></div></article>)}</div> : <div className="alerts-clear"><strong>Sin riesgos relevantes detectados.</strong><span>Tu historial reciente no activa alertas de desviación.</span></div>}</section>;
}

function GoalsPanel({ metrics, goals, setGoals }: { metrics: ReturnType<typeof buildFinanceMetrics>; goals: FinancialGoal[]; setGoals: React.Dispatch<React.SetStateAction<FinancialGoal[]>> }) {
  const [kind, setKind] = useState<FinancialGoalKind>("patrimony");
  const [target, setTarget] = useState("");
  function addGoal() {
    const value = Number(target);
    if (!Number.isFinite(value) || value <= 0) return;
    setGoals((current) => [...current, { id: `goal-${Date.now()}`, kind, target: value }]);
    setTarget("");
  }
  return <section className="goals-panel" aria-labelledby="goals-title"><div className="section-heading"><div><h2 id="goals-title">Metas financieras</h2><p>Define un objetivo y sigue su avance con la proyección actual.</p></div></div><div className="goal-form"><select aria-label="Tipo de meta" value={kind} onChange={(event) => setKind(event.target.value as FinancialGoalKind)}><option value="patrimony">Patrimonio objetivo</option><option value="debt">Deuda objetivo</option><option value="maxSpend">Gasto máximo mensual</option><option value="savings">Ahorro mensual</option></select><div className="goal-input"><span>$</span><input aria-label="Valor de la meta" type="number" min="1" step="100" value={target} onChange={(event) => setTarget(event.target.value)} placeholder="Tu objetivo" /></div><button className="primary-button" onClick={addGoal}>Agregar meta</button></div>{goals.length ? <div className="goal-list">{goals.map((goal) => <GoalCard key={goal.id} goal={goal} metrics={metrics} onDelete={() => setGoals((current) => current.filter((item) => item.id !== goal.id))} />)}</div> : <div className="goals-empty"><strong>Aún no tienes metas.</strong><span>Empieza con un patrimonio, deuda, límite de gasto o ahorro mensual.</span></div>}</section>;
}

function GoalCard({ goal, metrics, onDelete }: { goal: FinancialGoal; metrics: ReturnType<typeof buildFinanceMetrics>; onDelete: () => void }) {
  const current = goal.kind === "patrimony" ? metrics.liquidPatrimony : goal.kind === "debt" ? metrics.debtTotal : goal.kind === "maxSpend" ? metrics.currentMonthSpend : metrics.currentMonthNetFlow;
  const currentValue = current ?? 0;
  const progress = goal.kind === "patrimony" ? Math.min(1, Math.max(0, currentValue / goal.target)) : goal.kind === "debt" ? currentValue <= goal.target ? 1 : Math.max(0, 1 - currentValue / Math.max(currentValue + goal.target, 1)) : goal.kind === "maxSpend" ? currentValue <= goal.target ? 1 : Math.min(1, goal.target / Math.max(currentValue, 1)) : Math.min(1, Math.max(0, currentValue / goal.target));
  const estimate = goalEstimate(goal, metrics);
  return <article className="goal-card"><div className="goal-card-head"><div><span>{goalTitle(goal.kind)}</span><strong>{displayMoney(goal.target)}</strong></div><button className="row-action" aria-label={`Eliminar meta de ${goalTitle(goal.kind)}`} onClick={onDelete}><Trash size={16} /></button></div><div className="goal-progress"><span style={{ width: `${Math.round(progress * 100)}%` }} /></div><div className="goal-card-foot"><span>{Math.round(progress * 100)}% de avance</span><small>{estimate}</small></div></article>;
}

function goalTitle(kind: FinancialGoalKind) {
  return kind === "patrimony" ? "Patrimonio objetivo" : kind === "debt" ? "Deuda objetivo" : kind === "maxSpend" ? "Gasto máximo mensual" : "Ahorro mensual";
}

function goalEstimate(goal: FinancialGoal, metrics: ReturnType<typeof buildFinanceMetrics>) {
  const current = goal.kind === "patrimony" ? metrics.liquidPatrimony : goal.kind === "debt" ? metrics.debtTotal : goal.kind === "maxSpend" ? metrics.currentMonthSpend : metrics.currentMonthNetFlow;
  const currentValue = current ?? 0;
  const reached = goal.kind === "debt" || goal.kind === "maxSpend" ? currentValue <= goal.target : currentValue >= goal.target;
  if (reached) return "Objetivo alcanzado";
  if (goal.kind === "maxSpend") return "Ajustar este mes";
  const projection = metrics.projection.months;
  const match = projection.find((period) => {
    const value = goal.kind === "patrimony" ? period.projectedPatrimony : goal.kind === "debt" ? period.projectedDebt : period.projectedSavings;
    return value !== undefined && (goal.kind === "debt" ? value <= goal.target : value >= goal.target);
  });
  return match ? `Fecha estimada: ${match.label}` : "No visible en 12 meses";
}

function ExecutiveSummary({ metrics }: { metrics: ReturnType<typeof buildFinanceMetrics> }) {
  const current = metrics.analyticsPeriods[0];
  const previous = metrics.analyticsPeriods[1];
  const spend = current?.spend ?? metrics.currentMonthSpend;
  const change = current?.variationPercent ?? null;
  const cause = metrics.primaryCause;
  const causeText = cause
    ? `El principal cambio vino de ${cause.label}: ${comparisonMoney(cause.current, cause.previous)}.`
    : previous ? "No hay una categoría con aumento suficiente para explicar el cambio." : "Aún no hay un mes anterior con el que comparar.";
  const payment = current?.paymentTotal ?? metrics.totalRealPayments;
  const debt = metrics.debtTotal;
  return <section className="executive-card executive-summary" aria-labelledby="executive-summary-title">
    <div className="section-heading"><div><h2 id="executive-summary-title">Qué pasó este mes</h2><p>Una lectura automática de gasto, cambios y saldos relevantes.</p></div><span className="summary-period-chip">{periodLabel(current)}</span></div>
    <p className="executive-conclusion">Este mes gastaste <strong>{displayMoney(spend)}</strong>{change === null ? ", sin comparativo disponible" : `, ${comparisonPercent(change)}`}. {causeText} {payment ? `Registraste ${displayMoney(payment)} en pagos relevantes` : "No se detectaron pagos relevantes"} y cerraste con <strong>{displayMoney(debt)}</strong> de deuda.</p>
  </section>;
}

function SpendTrendChart({ periods }: { periods: AnalyticsPeriod[] }) {
  const chartPeriods = periods.slice(0, 6).reverse();
  if (!chartPeriods.length) return null;
  const width = 720;
  const height = 220;
  const padding = { top: 24, right: 22, bottom: 30, left: 22 };
  const maxSpend = Math.max(...chartPeriods.map((period) => period.spend), 1);
  const step = chartPeriods.length === 1 ? 0 : (width - padding.left - padding.right) / (chartPeriods.length - 1);
  const points = chartPeriods.map((period, index) => {
    const x = padding.left + index * step;
    const y = height - padding.bottom - (period.spend / maxSpend) * (height - padding.top - padding.bottom);
    return { period, x, y };
  });
  return <section className="executive-card spend-trend-card" aria-labelledby="spend-trend-title">
    <div className="section-heading"><div><h2 id="spend-trend-title">Gasto por periodo</h2><p>Últimos {chartPeriods.length} periodos · valores absolutos y variación mensual.</p></div></div>
    <div className="trend-chart-wrap">
      <svg className="spend-trend-chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Evolución del gasto por periodo">
        <line x1={padding.left} x2={width - padding.right} y1={height - padding.bottom} y2={height - padding.bottom} className="trend-baseline" />
        <polyline points={points.map(({ x, y }) => `${x},${y}`).join(" ")} className="trend-line" />
        {points.map(({ period, x, y }) => <circle key={period.key} cx={x} cy={y} r="5" className="trend-point"><title>{`${period.label}: ${displayMoney(period.spend)}`}</title></circle>)}
      </svg>
      <div className="trend-values">{chartPeriods.map((period) => <div key={period.key}><span>{period.label}</span><strong>{displayMoney(period.spend)}</strong><small className={period.variationPercent !== null && period.variationPercent < 0 ? "trend-down" : "trend-up"}>{comparisonPercent(period.variationPercent)}</small></div>)}</div>
    </div>
  </section>;
}

function CashFlowTrendChart({ points }: { points: CashFlowPoint[] }) {
  const [selectedPoint, setSelectedPoint] = useState<CashFlowPoint | null>(null);
  const chartPoints = points.slice(-180);
  if (!chartPoints.length) return null;

  const width = 720;
  const height = 280;
  const padding = { top: 18, right: 18, bottom: 34, left: 78 };
  const values = chartPoints.flatMap((point) => [point.income, point.expense, point.balance]);
  const minimum = Math.min(0, ...values);
  const maximum = Math.max(0, ...values);
  const range = Math.max(maximum - minimum, 1);
  const chartRangePadding = Math.max(range * 0.12, 1);
  const domainMin = minimum - chartRangePadding;
  const domainMax = maximum + chartRangePadding;
  const plotWidth = width - padding.left - padding.right;
  const plotHeight = height - padding.top - padding.bottom;
  const xFor = (index: number) => padding.left + (chartPoints.length === 1 ? plotWidth / 2 : (index / (chartPoints.length - 1)) * plotWidth);
  const yFor = (value: number) => height - padding.bottom - ((value - domainMin) / (domainMax - domainMin)) * plotHeight;
  const linePoints = (key: "income" | "expense" | "balance") => chartPoints.map((point, index) => `${xFor(index)},${yFor(point[key])}`).join(" ");
  const labelIndexes = Array.from(new Set([0, Math.floor((chartPoints.length - 1) / 2), chartPoints.length - 1]));
  const yTicks = [0, 0.5, 1].map((ratio) => domainMin + (domainMax - domainMin) * ratio);
  const formatAxisMoney = (value: number) => new Intl.NumberFormat("es-MX", { notation: "compact", maximumFractionDigits: 1 }).format(value);
  const selectedIndex = selectedPoint ? chartPoints.findIndex((point) => point.key === selectedPoint.key) : -1;
  const selectedTrend = selectedIndex >= 0 ? chartPoints.slice(Math.max(0, selectedIndex - 3), Math.min(chartPoints.length, selectedIndex + 4)) : [];

  return <section className="executive-card cash-flow-trend-card" aria-labelledby="cash-flow-trend-title">
    <div className="section-heading"><div><h2 id="cash-flow-trend-title">Ingresos, gastos y balance</h2><p>Comparación por fecha · balance acumulado = ingresos − gastos.</p></div><span className="summary-period-chip">{chartPoints.length > 1 ? `Últimas ${chartPoints.length} fechas` : "1 fecha"}</span></div>
    <div className="cash-flow-chart-wrap">
      <svg className="cash-flow-chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Gráfica de líneas de ingresos, gastos y balance acumulado por fecha">
        {yTicks.map((tick) => <g key={tick}><line x1={padding.left} x2={width - padding.right} y1={yFor(tick)} y2={yFor(tick)} className="cash-flow-grid" /><text x={padding.left - 10} y={yFor(tick) + 4} textAnchor="end" className="cash-flow-axis-label">{formatAxisMoney(tick)}</text></g>)}
        <line x1={padding.left} x2={width - padding.right} y1={yFor(0)} y2={yFor(0)} className="cash-flow-zero" />
        <polyline points={linePoints("income")} className="cash-flow-line cash-flow-income" />
        <polyline points={linePoints("expense")} className="cash-flow-line cash-flow-expense" />
        <polyline points={linePoints("balance")} className="cash-flow-line cash-flow-balance" />
        {chartPoints.map((point, index) => <g key={point.key}>
          <circle cx={xFor(index)} cy={yFor(point.income)} r="3.5" className="cash-flow-point cash-flow-income-point" onClick={() => setSelectedPoint(point)} role="button" tabIndex={0} aria-label={"Ingresos " + point.date}><title>{`${point.date} · Ingresos: ${displayMoney(point.income)}`}</title></circle>
          <circle cx={xFor(index)} cy={yFor(point.expense)} r="3.5" className="cash-flow-point cash-flow-expense-point" onClick={() => setSelectedPoint(point)} role="button" tabIndex={0} aria-label={"Gastos " + point.date}><title>{`${point.date} · Gastos: ${displayMoney(point.expense)}`}</title></circle>
          <circle cx={xFor(index)} cy={yFor(point.balance)} r="3.5" className="cash-flow-point cash-flow-balance-point" onClick={() => setSelectedPoint(point)} role="button" tabIndex={0} aria-label={"Balance acumulado " + point.date}><title>{`${point.date} · Balance acumulado: ${displayMoney(point.balance)}`}</title></circle>
        </g>)}
        {labelIndexes.map((index) => <text key={chartPoints[index].key} x={xFor(index)} y={height - 10} textAnchor={index === 0 ? "start" : index === chartPoints.length - 1 ? "end" : "middle"} className="cash-flow-axis-label">{chartPoints[index].date}</text>)}
      </svg>
      {selectedPoint && <div className="cash-flow-selected" aria-live="polite">
        <div className="cash-flow-selected-head"><div><span>Fecha seleccionada</span><strong>{selectedPoint.date}</strong></div><button type="button" className="row-action" onClick={() => setSelectedPoint(null)} aria-label="Cerrar detalle"><X size={16} /></button></div>
        <div className="cash-flow-selected-values"><span><b>Ingresos</b>{displayMoney(selectedPoint.income)}</span><span><b>Gastos</b>{displayMoney(selectedPoint.expense)}</span><span><b>Balance acumulado</b>{displayMoney(selectedPoint.balance)}</span></div>
        <MiniCashFlowTrend points={selectedTrend.length ? selectedTrend : [selectedPoint]} />
      </div>}
      <div className="cash-flow-legend" aria-label="Series de la gráfica">
        <span className="cash-flow-legend-income">Ingresos</span>
        <span className="cash-flow-legend-expense">Gastos</span>
        <span className="cash-flow-legend-balance">Balance acumulado</span>
      </div>
      <p className="cash-flow-note">Transferencias internas y pagos de tarjeta no se muestran para no inflar el gasto.</p>
    </div>
  </section>;
}

function MiniCashFlowTrend({ points }: { points: CashFlowPoint[] }) {
  const width = 720;
  const height = 140;
  const padding = { top: 12, right: 10, bottom: 12, left: 10 };
  const values = points.flatMap((point) => [point.income, point.expense, point.balance]);
  const minimum = Math.min(0, ...values);
  const maximum = Math.max(0, ...values);
  const range = Math.max(maximum - minimum, 1);
  const domainMin = minimum - range * 0.12;
  const domainMax = maximum + range * 0.12;
  const xFor = (index: number) => padding.left + (points.length === 1 ? (width - padding.left - padding.right) / 2 : (index / (points.length - 1)) * (width - padding.left - padding.right));
  const yFor = (value: number) => height - padding.bottom - ((value - domainMin) / (domainMax - domainMin)) * (height - padding.top - padding.bottom);
  const linePoints = (key: "income" | "expense" | "balance") => points.map((point, index) => xFor(index) + "," + yFor(point[key])).join(" ");
  return <svg className="cash-flow-mini-chart" viewBox={"0 0 " + width + " " + height} role="img" aria-label="Mini gráfica de ingresos, gastos y balance">
    <line x1={padding.left} x2={width - padding.right} y1={yFor(0)} y2={yFor(0)} className="cash-flow-zero" />
    <polyline points={linePoints("income")} className="cash-flow-line cash-flow-income" />
    <polyline points={linePoints("expense")} className="cash-flow-line cash-flow-expense" />
    <polyline points={linePoints("balance")} className="cash-flow-line cash-flow-balance" />
  </svg>;
}

function SpendingSplit({ period }: { period?: AnalyticsPeriod }) {
  const ordinary = period?.ordinarySpend ?? 0;
  const extraordinary = period?.extraordinarySpend ?? 0;
  const total = ordinary + extraordinary;
  const ordinaryWidth = total ? ordinary / total * 100 : 0;
  return <section className="executive-card spending-split" aria-labelledby="spending-split-title">
    <div className="section-heading"><div><h2 id="spending-split-title">Gasto ordinario y extraordinario</h2><p>Separamos costo de vida recurrente de viajes, compras atípicas y eventos.</p></div><span className="summary-period-chip">{periodLabel(period)}</span></div>
    <div className="split-values"><div><span>Gasto ordinario</span><strong>{displayMoney(ordinary)}</strong><small>{total ? `${Math.round(ordinary / total * 100)}% del periodo` : "Sin datos identificados"}</small></div><div><span>Gasto extraordinario</span><strong>{displayMoney(extraordinary)}</strong><small>{total ? `${Math.round(extraordinary / total * 100)}% del periodo` : "Sin datos identificados"}</small></div></div>
    <div className="split-bar" aria-label={`Gasto ordinario ${Math.round(ordinaryWidth)} por ciento y extraordinario ${Math.round(100 - ordinaryWidth)} por ciento`}><span style={{ width: `${ordinaryWidth}%` }} /><span style={{ width: `${100 - ordinaryWidth}%` }} /></div>
  </section>;
}

function DataQualityIndicator({ metrics }: { metrics: ReturnType<typeof buildFinanceMetrics> }) {
  const quality = metrics.dataQuality;
  const alert = quality.relevantReviewCount > 0 || quality.critical;
  return <section className={`data-quality${alert ? " has-alert" : ""}`} aria-label="Calidad de datos y conciliación">
    <div><span>Calidad de datos / conciliación</span><strong>{Math.round(quality.classifiedPercent)}%</strong><small>{Math.round(quality.reconciledPercent)}% conciliado · {quality.classifiedCount} de {quality.totalCount} movimientos clasificados</small></div>
    {alert ? <p className="quality-alert">{metrics.isProvisional ? "KPI provisionales: " : ""}{quality.relevantReviewCount ? `revisa ${quality.relevantReviewCount} movimiento${quality.relevantReviewCount === 1 ? " relevante" : "s relevantes"}` : "hay filas rechazadas por el parser"}.</p> : <p className="quality-ok">Sin alertas relevantes de clasificación.</p>}
  </section>;
}

function DashboardBlockedNotice({ metrics }: { metrics: ReturnType<typeof buildFinanceMetrics> }) {
  const issue = metrics.audit.criticalIssues[0] ?? "Los estados aún no concilian contra sus totales originales.";
  return <section className="provisional-banner dashboard-blocked" role="alert"><Warning size={20} /><div><strong>Dashboard histórico bloqueado</strong><p>{issue}</p><small>Corrige o vuelve a importar los estados señalados. Las filas rechazadas no alimentan ningún KPI.</small></div></section>;
}

function DebtBreakdown({ metrics }: { metrics: ReturnType<typeof buildFinanceMetrics> }) {
  return <section className="debt-breakdown" aria-label="Desglose de deuda"><div><span>Saldo total de deuda</span><strong>{displayMoney(metrics.debtTotal)}</strong><small>Tarjetas y créditos al último corte</small></div><div><span>Pago próximo</span><strong>{displayMoney(metrics.latestPaymentDue)}</strong><small>Mínimo + MSI del estado</small></div><div><span>Pago para no generar intereses</span><strong>{displayMoney(metrics.latestPaymentForNoInterest)}</strong><small>Importe del estado</small></div><div><span>MSI pendientes</span><strong>{displayMoney(metrics.latestMsiPending)}</strong><small>{metrics.latestMsiInstallmentsCount ? `${metrics.latestMsiInstallmentsCount} mensualidades` : "Principal diferido"}</small></div></section>;
}

function AuditDiagnostics({ metrics, auditRun }: { metrics: ReturnType<typeof buildFinanceMetrics>; auditRun: AuditRunRecord | null }) {
  const audit = metrics.audit;
  return <details className="audit-diagnostics">
     <summary><div><strong>Auditoría de importación y conciliación</strong><span>Diagnóstico temporal reproducible · {audit.stages.join(" → ")}</span></div><b>{audit.periods.length} periodos</b></summary>
     {auditRun && <div className="audit-run-meta"><span>Auditoría {auditRun.id} · libro {auditRun.ledgerFingerprint}</span><b className={`audit-status-${auditRun.status}`}>{auditRun.status === "passed" ? "Verificado" : auditRun.status === "warning" ? "Advertencias" : "Bloqueado"}</b></div>}
    {audit.criticalIssues.length > 0 && <div className="audit-critical">{audit.criticalIssues.join(" · ")}</div>}
    <div className="audit-table" role="table" aria-label="Auditoría por periodo"><div className="audit-row audit-head" role="row"><span>Periodo</span><span>Importados / válidos</span><span>Duplicados</span><span>Traspasos</span><span>Pagos tarjeta</span><span>Ingresos</span><span>Gasto real</span><span>Reembolsos / revisar</span></div>{audit.periods.map((period) => <div className="audit-row" role="row" key={period.key}><strong>{period.label}</strong><span>{period.importedCount} / {period.validCount}<small>{displayMoney(period.importedAmount)} / {displayMoney(period.validAmount)}</small></span><span>{period.duplicateCount}<small>{displayMoney(period.duplicateAmount)}</small></span><span>{period.internalTransferCount}<small>{displayMoney(period.internalTransferAmount)}</small></span><span>{period.cardPaymentCount}<small>{displayMoney(period.cardPaymentAmount)}</small></span><span>{period.incomeCount}<small>{displayMoney(period.incomeAmount)}</small></span><span>{period.expenseCount}<small>{displayMoney(period.expenseAmount)}</small></span><span>{period.refundCount} / {period.reviewCount}<small>{displayMoney(period.refundAmount)} / {displayMoney(period.reviewAmount)}</small></span></div>)}</div><div className="audit-totals"><span>Totales</span><b>{audit.importedCount} · {displayMoney(audit.importedAmount)} importados</b><b>{audit.validCount} · {displayMoney(audit.validAmount)} válidos</b><b>{audit.invalidCount} · {displayMoney(audit.invalidAmount)} rechazados</b><b>{audit.duplicateCount} · {displayMoney(audit.duplicateAmount)} duplicados</b><b>{audit.internalTransferCount} traspasos</b><b>{audit.cardPaymentCount} pagos tarjeta</b><b>{displayMoney(audit.incomeAmount)} ingresos</b><b>{displayMoney(audit.expenseAmount)} gasto</b></div><div className="consistency-list"><strong>Consistencias contables</strong>{metrics.consistencyChecks.map((check) => <span className={check.passed ? "check-pass" : "check-fail"} key={check.id}>{check.passed ? "✓" : "!"} {check.label}{check.difference === undefined ? " · pendiente" : ` · diferencia ${displayMoney(check.difference)}`}</span>)}</div>
  </details>;
}

function CalculationSummary({ metrics }: { metrics: ReturnType<typeof buildFinanceMetrics> }) {
  return <section className="calculation-section" aria-label="Cálculos financieros"><div className="section-heading"><div><h2>Lo que explica tu dinero</h2><p>Calculado por periodo y conciliado con pagos, MSI, transferencias y devoluciones cuando están disponibles.</p></div><span className="calculation-periods">{metrics.periodCount} {metrics.periodCount === 1 ? "periodo" : "periodos"}</span></div><div className="calculation-grid"><div className="calculation-ledger"><div className="calculation-ledger-head"><span>Tarjeta</span><small>Acumulado de estados Amex</small></div><CalculationRow label="Gasto total" value={displayMoney(metrics.totalNewTransactions)} detail="Compras nuevas" /><CalculationRow label="Gasto promedio mensual" value={displayMoney(metrics.averageMonthlySpend)} detail="Nuevos cargos / periodos" /><CalculationRow label="Abonos reales" value={displayMoney(metrics.totalRealPayments)} detail="Pagos, sin créditos contables" /><CalculationRow label="Saldo acumulado" value={displayMoney(metrics.accumulatedBalance)} detail="Cargos − pagos − créditos" tone={metrics.accumulatedBalance > 0 ? "warning" : "positive"} /><CalculationRow label="Porcentaje pagado" value={displayPercent(metrics.paidPercent)} detail="Abonos / nuevos cargos" /><CalculationRow label="Pendiente" value={displayPercent(metrics.pendingPercent)} detail="Saldo / nuevos cargos" /></div><div className="calculation-ledger"><div className="calculation-ledger-head"><span>Consolidado</span><small>Tarjetas + bancos propios</small></div><CalculationRow label="Gasto real consolidado" value={displayMoney(metrics.consolidatedRealSpend)} detail="Excluye pagos y traspasos" /><CalculationRow label="Gasto de viaje" value={displayMoney(metrics.travelSpend)} detail={metrics.travelPercent === null ? "Pendiente de identificar" : `${displayPercent(metrics.travelPercent)} del gasto`} /><CalculationRow label="Gasto ordinario" value={displayMoney(metrics.ordinarySpend)} detail="Consolidado − viajes" /><CalculationRow label="Flujo neto mensual" value={displayMoney(metrics.netFlow)} detail="Ingresos reales − gastos reales" tone={metrics.netFlow >= 0 ? "positive" : "warning"} /><CalculationRow label="Tasa de ahorro" value={displayPercent(metrics.savingsRate)} detail="Flujo neto / ingresos" /><CalculationRow label="Promedio ordinario" value={displayMoney(metrics.ordinaryAverageMonthly)} detail="Ordinario / periodos" /></div><div className="calculation-ledger"><div className="calculation-ledger-head"><span>Crédito y MSI</span><small>Último corte con datos</small></div><CalculationRow label="Utilización de crédito" value={displayPercent(metrics.creditUtilizationRate)} detail={metrics.creditUsed !== undefined ? `${displayMoney(metrics.creditUsed)} utilizado` : "Límite y disponible pendientes"} /><CalculationRow label="Carga mensual MSI" value={displayMoney(metrics.latestMsiMonthlyLoad)} detail={metrics.latestMsiInstallmentsCount !== undefined ? `${metrics.latestMsiInstallmentsCount} mensualidades activas` : "Captura el total del corte"} /><CalculationRow label="MSI diferido original" value={displayMoney(metrics.latestMsiOriginalDeferred)} detail="Principal aún diferido" /><CalculationRow label="Nuevos cargos del corte" value={displayMoney(metrics.cardPeriods[0]?.newCharges)} detail="Compras + MSI + intereses + comisiones" /><CalculationRow label="Pago para no generar intereses" value={displayMoney(metrics.latestPaymentForNoInterest)} detail="Estimado con saldo anterior y pagos" /><CalculationRow label="Saldo de deuda" value={displayMoney(metrics.debtTotal)} detail="Requiere saldo al corte" /></div></div><p className="calculation-footnote">Pendiente significa que el documento aún no trae ese dato o debes capturarlo en <strong>Cuentas</strong>. Marcelito no sustituye una cifra faltante con una estimación silenciosa.</p></section>;
}

function CalculationRow({ label, value, detail, tone }: { label: string; value: string; detail: string; tone?: "positive" | "warning" }) {
  return <div className={`calculation-row${tone ? ` ${tone}` : ""}`}><div><span>{label}</span><small>{detail}</small></div><strong>{value}</strong></div>;
}

function StatementSummaryForm({ source, kind, summary, onChange }: { source: StatementSource; kind: Statement["kind"]; summary: StatementSummary; onChange: (key: keyof StatementSummary, value: string) => void }) {
  const fields: Array<{ key: keyof StatementSummary; label: string; hint: string }> = [
    { key: "previousBalance", label: "Saldo anterior", hint: "Corte previo" },
    { key: "newTransactions", label: "Nuevas transacciones", hint: "Compras nuevas" },
    { key: "payments", label: "Pagos realizados", hint: "Abonos reales" },
    { key: "credits", label: "Créditos / abonos contables", hint: "No son pagos" },
    { key: "newCharges", label: "Nuevos cargos del corte", hint: "Total del resumen" },
    { key: "interest", label: "Intereses", hint: "Interés del periodo" },
    { key: "fees", label: "Comisiones", hint: "Cargos y anualidad" },
    { key: "statementBalance", label: source === "Amex" ? "Saldo nuevo" : "Saldo al corte", hint: "Saldo del estado" },
    { key: "minimumPayment", label: "Pago mínimo", hint: "Pago requerido" },
    { key: "minimumPlusMsi", label: "Pago mínimo + MSI", hint: "Pago próximo del estado" },
    { key: "paymentForNoInterest", label: "Pago para no generar intereses", hint: "Importe del estado" },
    ...(kind === "card" || source === "Amex" ? [
      { key: "creditLimit" as keyof StatementSummary, label: "Límite de crédito", hint: "Línea autorizada" },
      { key: "creditAvailable" as keyof StatementSummary, label: "Crédito disponible", hint: "Disponible al corte" },
      { key: "debtBalance" as keyof StatementSummary, label: "Deuda al corte", hint: "Saldo usado" },
      { key: "revolvingBalance" as keyof StatementSummary, label: "Saldo revolvente", hint: "Deuda fuera de MSI" },
      { key: "msiPending" as keyof StatementSummary, label: "MSI pendientes", hint: "Principal diferido" },
      { key: "msiOriginalDeferred" as keyof StatementSummary, label: "MSI original diferido", hint: "Principal pendiente" },
      { key: "msiInstallments" as keyof StatementSummary, label: "Mensualidades MSI activas", hint: "Cantidad" },
      { key: "msiMonthlyLoad" as keyof StatementSummary, label: "Carga mensual MSI", hint: "Total del corte" },
    ] : [
      { key: "cashBalance" as keyof StatementSummary, label: "Efectivo disponible", hint: "Saldo bancario" },
      { key: "depositTotal" as keyof StatementSummary, label: "Depósitos / abonos", hint: "Total declarado" },
      { key: "withdrawalTotal" as keyof StatementSummary, label: "Retiros / cargos", hint: "Total declarado" },
    ]),
  ];
  return <details className="statement-summary-form"><summary>Completar datos del corte <span>Opcional, pero necesario para crédito y patrimonio</span></summary><p>Los importes detectados del PDF aparecen aquí para que puedas corregirlos. Si un campo no está en el estado, déjalo vacío.</p><div className="summary-field-grid">{fields.map((field) => <label key={String(field.key)}><span>{field.label}</span><small>{field.hint}</small><input type="number" step="0.01" value={typeof summary[field.key] === "number" ? Number(summary[field.key]) : ""} onChange={(event) => onChange(field.key, event.target.value)} placeholder="—" /></label>)}</div></details>;
}

function RealDataEmpty({ onImport }: { onImport: () => void }) {
  return <section className="real-data-empty"><div className="real-data-icon"><FilePdf size={32} /></div><h1>Empieza con tus estados reales</h1><p>Marcelito no carga cifras de muestra. Importa un PDF mensual y revisa banco, periodo, movimientos y categorías antes de guardarlo.</p><button className="primary-button" onClick={onImport}><UploadSimple size={18} />Importar primer estado</button><small>El archivo se procesa localmente y no se sube a ningún servidor.</small></section>;
}

function Metric({ label, value, delta, tone, icon: Icon, onSelect }: { label: string; value: string; delta: string; tone: string; icon: typeof Wallet; onSelect?: () => void }) {
  return <button type="button" className={"metric metric-button metric-" + tone} onClick={onSelect} aria-label={"Ver detalle de " + label}><div className="metric-icon"><Icon size={20} /></div><div><span>{label}</span><strong>{value}</strong><small>{delta}</small></div></button>;
}

function metricSeries(metric: DashboardMetricKey, metrics: ReturnType<typeof buildFinanceMetrics>): MetricSeriesPoint[] {
  if (metric === "expense") return metrics.cashFlowHistory.slice(-12).map((point) => ({ key: point.key, label: point.date, value: point.expense }));
  if (metric === "flow") return metrics.cashFlowHistory.slice(-12).map((point) => ({ key: point.key, label: point.date, value: point.balance }));
  const periods = metrics.analyticsPeriods.slice().reverse();
  const valueFor = metric === "patrimony"
    ? (period: AnalyticsPeriod) => period.liquidPatrimony
    : metric === "cash"
      ? (period: AnalyticsPeriod) => period.cashAvailable
      : (period: AnalyticsPeriod) => period.debtTotal;
  return periods
    .map((period) => ({ key: period.key, label: period.label, value: valueFor(period) }))
    .filter((point): point is MetricSeriesPoint => point.value !== undefined);
}

function metricCurrentValue(metric: DashboardMetricKey, metrics: ReturnType<typeof buildFinanceMetrics>) {
  if (metric === "patrimony") return metrics.liquidPatrimony;
  if (metric === "cash") return metrics.cashAvailable;
  if (metric === "debt") return metrics.debtTotal;
  if (metric === "expense") return metrics.currentMonthSpend;
  return metrics.currentMonthNetFlow;
}

function metricExplanation(metric: DashboardMetricKey) {
  if (metric === "patrimony") return "Efectivo disponible menos deuda total.";
  if (metric === "cash") return "Saldo consolidado de tus cuentas de efectivo.";
  if (metric === "debt") return "Deuda registrada en tarjetas al último corte.";
  if (metric === "expense") return "Gasto real del periodo, sin pagos internos.";
  return "Ingresos reales menos gasto real.";
}

function MetricDetailPanel({ metric, metrics, onClose }: { metric: DashboardMetricKey; metrics: ReturnType<typeof buildFinanceMetrics>; onClose: () => void }) {
  const points = metricSeries(metric, metrics);
  const current = metricCurrentValue(metric, metrics);
  const comparison = points.length > 1 ? comparisonMoney(points.at(-1)?.value, points.at(-2)?.value) : "Aún no hay comparativo";
  const color = metric === "expense" ? "var(--expense)" : metric === "debt" ? "var(--debt)" : metric === "patrimony" ? "var(--navy)" : "var(--income)";
  return <section className="metric-detail-panel" aria-live="polite" aria-labelledby="metric-detail-title">
    <div className="metric-detail-head"><div><span>Detalle del indicador</span><h2 id="metric-detail-title">{metric === "patrimony" ? "Patrimonio líquido" : metric === "cash" ? "Efectivo disponible" : metric === "debt" ? "Deuda total" : metric === "expense" ? "Gasto del mes" : "Flujo neto"}</h2></div><button type="button" className="row-action" aria-label="Cerrar detalle" onClick={onClose}><X size={17} /></button></div>
    <div className="metric-detail-summary"><strong>{dashboardMoney(metrics.isProvisional, current)}</strong><span>{metrics.isProvisional ? "Conciliación requerida" : comparison}</span><p>{metricExplanation(metric)}</p></div>
    {metrics.isProvisional ? <p className="metric-detail-empty">La tendencia se habilitará cuando los estados concilien.</p> : points.length ? <MiniMetricChart points={points} color={color} /> : <p className="metric-detail-empty">Aún no hay suficientes datos para dibujar una tendencia.</p>}
  </section>;
}

function MiniMetricChart({ points, color }: { points: MetricSeriesPoint[]; color: string }) {
  const width = 720;
  const height = 150;
  const padding = { top: 14, right: 12, bottom: 20, left: 12 };
  const minimum = Math.min(0, ...points.map((point) => point.value));
  const maximum = Math.max(0, ...points.map((point) => point.value));
  const range = Math.max(maximum - minimum, 1);
  const domainMin = minimum - range * 0.1;
  const domainMax = maximum + range * 0.1;
  const xFor = (index: number) => padding.left + (points.length === 1 ? (width - padding.left - padding.right) / 2 : (index / (points.length - 1)) * (width - padding.left - padding.right));
  const yFor = (value: number) => height - padding.bottom - ((value - domainMin) / (domainMax - domainMin)) * (height - padding.top - padding.bottom);
  return <div className="metric-detail-chart-wrap">
    <svg className="metric-detail-chart" viewBox={"0 0 " + width + " " + height} role="img" aria-label="Tendencia del indicador seleccionado">
      <line x1={padding.left} x2={width - padding.right} y1={yFor(0)} y2={yFor(0)} className="metric-detail-zero" />
      <polyline points={points.map((point, index) => xFor(index) + "," + yFor(point.value)).join(" ")} className="metric-detail-line" style={{ stroke: color }} />
      {points.map((point, index) => <circle key={point.key} cx={xFor(index)} cy={yFor(point.value)} r="4" className="metric-detail-point" style={{ stroke: color }}><title>{point.label + ": " + displayMoney(point.value)}</title></circle>)}
    </svg>
    <div className="metric-detail-range"><span>{points[0].label}</span><strong>{points.length > 1 ? "Evolución reciente" : "Primer dato"}</strong><span>{points.at(-1)?.label}</span></div>
  </div>;
}

function Movements({ transactions, statements, setTransactions, onLearnCategory, onImport, embedded = false }: { transactions: Transaction[]; statements: Statement[]; setTransactions: React.Dispatch<React.SetStateAction<Transaction[]>>; onLearnCategory: (description: string, category: string) => void; onImport: () => void; embedded?: boolean }) {
  const [query, setQuery] = useState("");
  const filtered = transactions.filter((item) => {
    const statement = statements.find((source) => source.id === item.statementId);
    return `${item.description} ${item.category} ${item.account} ${statementLabel(statement)} ${statement?.fileName ?? ""}`.toLowerCase().includes(query.toLowerCase());
  });
  function updateCategory(id: string, category: string) { setTransactions((items) => items.map((item) => item.id === id ? { ...item, category } : item)); const movement = transactions.find((item) => item.id === id); if (movement) onLearnCategory(movement.description, category); }
  return <section className={embedded ? "movements-detail" : undefined}>{!embedded && <PageHeading title="Movimientos" body="Busca, corrige y conecta cada movimiento con su estado de cuenta." action="Importar estado" onAction={onImport} />}<div className="filter-row"><div className="search-box"><ListMagnifyingGlass size={19} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Buscar comercio, banco, periodo o categoría" /></div><span className="result-count">{filtered.length} de {transactions.length}</span></div>{filtered.length ? <div className="movement-list">{filtered.map((item) => { const statement = statements.find((source) => source.id === item.statementId); return <div className="movement-row" key={item.id}><span className={`movement-glyph glyph-${item.flow}`}>{item.flow === "transfer" ? <ArrowsLeftRight size={18} /> : item.flow === "income" ? <ArrowDown size={18} /> : <Receipt size={18} />}</span><div className="movement-name"><strong>{item.description}</strong><span>{item.date} · {item.account} · {statementLabel(statement)}</span></div><select aria-label={`Categoría de ${item.description}`} value={item.category} onChange={(event) => updateCategory(item.id, event.target.value)}>{["Ingresos", "Transferencia", ...categories].map((category) => <option key={category}>{category}</option>)}</select><strong className={item.amount > 0 ? "amount positive" : "amount"}>{moneyPrecise.format(item.amount)}</strong><button className="row-action" aria-label={`Editar ${item.description}`}><PencilSimple size={17} /></button></div>; })}</div> : <EmptyState title="No hay movimientos reales" body="Importa un estado de cuenta o agrega un movimiento manual para empezar." />}</section>;
}

function Expenses({ transactions, statements, metrics, onImport }: { transactions: Transaction[]; statements: Statement[]; metrics: ReturnType<typeof buildFinanceMetrics>; onImport: () => void }) {
  if (!transactions.length && !statements.length) return <section><PageHeading title="Gastos" body="El gasto real se calcula a partir de tus movimientos importados." action="Importar estado" onAction={onImport} /><EmptyState title="Todavía no hay gastos" body="Carga un PDF mensual para ver categorías construidas con tus datos." /></section>;
  if (metrics.isProvisional) return <section><PageHeading title="Gastos" body="El gasto real se calcula a partir de movimientos conciliados." action="Importar estado" onAction={onImport} /><DashboardBlockedNotice metrics={metrics} /><DataQualityIndicator metrics={metrics} /></section>;
  const current = metrics.analyticsPeriods[0];
  const previous = metrics.analyticsPeriods[1];
  return <section>
    <PageHeading title="Gastos" body="Entiende cuánto gastaste, cómo cambió y qué lo explica." action="Importar estado" onAction={onImport} />
    <section className="expense-summary-kpis" aria-label="Resumen de gastos">
      <Metric label="Gasto del mes" value={displayMoney(metrics.currentMonthSpend)} delta={comparisonPercent(current?.variationPercent)} tone="expense" icon={Receipt} />
      <Metric label="Promedio móvil 3 meses" value={displayMoney(current?.movingAverage3)} delta={comparisonMoney(current?.movingAverage3, previous?.movingAverage3)} tone="income" icon={ChartLineUp} />
      <Metric label="Gasto extraordinario" value={displayMoney(current?.extraordinarySpend)} delta={current?.spend ? `${Math.round((current.extraordinarySpend / current.spend) * 100)}% del gasto · ${comparisonMoney(current.extraordinarySpend, previous?.extraordinarySpend)}` : "Sin datos identificados"} tone="debt" icon={Warning} />
    </section>
    <SpendingSplit period={current} />
    <div className="expense-analysis-grid">
      <CategoryDistribution categories={metrics.categoryDistribution} period={current} transactions={transactions} statements={statements} />
      <MerchantRanking merchants={metrics.topMerchants} period={current} />
    </div>
    <div className="expense-analysis-grid">
      <MovementRanking movements={metrics.topMovements} period={current} />
      <TravelTrips trips={metrics.travelTrips} period={current} />
    </div>
    <DataQualityIndicator metrics={metrics} />
  </section>;
}

function CategoryDistribution({ categories, period, transactions, statements }: { categories: ReturnType<typeof buildFinanceMetrics>["categoryDistribution"]; period?: AnalyticsPeriod; transactions: Transaction[]; statements: Statement[] }) {
  const [selectedCategory, setSelectedCategory] = useState<string | null>(null);
  const max = Math.max(...categories.map((category) => category.total), 1);
  const selectedTransactions = useMemo(() => {
    if (!selectedCategory) return [];
    const selectedKey = normalizeConcept(selectedCategory);
    return transactions.filter((transaction) => {
      if (!isSpendTransaction(transaction)) return false;
      if (period?.key && transactionPeriodKey(transaction, statements) !== period.key) return false;
      return normalizeConcept(transaction.category) === selectedKey;
    });
  }, [period?.key, selectedCategory, statements, transactions]);
  const detailTotal = selectedTransactions.reduce((total, transaction) => total + Math.abs(transaction.amount), 0);
  const recurring = useMemo(() => {
    const grouped = new Map<string, { name: string; total: number; count: number }>();
    selectedTransactions.forEach((transaction) => {
      const key = merchantKey(transaction.description) || normalizeConcept(transaction.description) || transaction.description.trim().toLowerCase();
      const current = grouped.get(key);
      if (current) {
        current.total += Math.abs(transaction.amount);
        current.count += 1;
      } else {
        grouped.set(key, { name: compactMerchantName(transaction.description), total: Math.abs(transaction.amount), count: 1 });
      }
    });
    return Array.from(grouped.values()).sort((left, right) => right.count - left.count || right.total - left.total).slice(0, 5);
  }, [selectedTransactions]);
  const highest = useMemo(() => selectedTransactions.slice().sort((left, right) => Math.abs(right.amount) - Math.abs(left.amount)).slice(0, 5), [selectedTransactions]);
  const detailId = selectedCategory ? `category-detail-${normalizeConcept(selectedCategory).replace(/\s+/g, "-")}` : undefined;

  function toggleCategory(category: string) {
    setSelectedCategory((current) => current === category ? null : category);
  }

  return <section className="detail-card" aria-labelledby="category-distribution-title"><div className="section-heading"><div><h2 id="category-distribution-title">Distribución por categorías</h2><p>{periodLabel(period)} · pulsa una categoría para ver sus gastos recurrentes y más altos.</p></div></div>{categories.length ? <div className="category-list">{categories.map((category) => {
    const selected = selectedCategory === category.name;
    return <button type="button" className={`category-row category-row-button${selected ? " selected" : ""}`} key={category.name} onClick={() => toggleCategory(category.name)} aria-expanded={selected} aria-controls={detailId}>
      <span className="category-row-label"><span>{category.name}</span><strong>{displayMoney(category.total)}</strong></span>
      <span className="category-track"><span style={{ width: `${Math.max(4, category.total / max * 100)}%` }} /></span>
      <small>{Math.round(category.share * 100)}%</small>
    </button>;
  })}</div> : <EmptyState title="Sin categorías todavía" body="Revisa las categorías desde Cuentas › Movimientos." />}
    {selectedCategory && <div className="category-detail-panel" id={detailId} aria-label={`Detalle de ${selectedCategory}`}>
      <div className="category-detail-head"><div><span className="eyebrow">Detalle de categoría</span><h3>{selectedCategory}</h3><p>{selectedTransactions.length} movimiento{selectedTransactions.length === 1 ? "" : "s"} · {displayMoney(detailTotal)} en {periodLabel(period)}</p></div><button type="button" className="icon-button" aria-label="Cerrar detalle de categoría" onClick={() => setSelectedCategory(null)}><X size={18} /></button></div>
      {selectedTransactions.length ? <div className="category-detail-grid">
        <div><h4>Gastos más recurrentes</h4><p className="category-detail-caption">Comercios que aparecen con mayor frecuencia.</p>{recurring.length ? <ol className="category-detail-list">{recurring.map((merchant, index) => <li key={merchant.name}><span className="category-detail-rank">{index + 1}</span><div><strong>{merchant.name}</strong><small>{merchant.count} movimiento{merchant.count === 1 ? "" : "s"}</small></div><strong>{displayMoney(merchant.total)}</strong></li>)}</ol> : <p className="category-detail-empty">Sin recurrencias identificadas.</p>}</div>
        <div><h4>Gastos más altos</h4><p className="category-detail-caption">Movimientos de mayor importe en el periodo.</p>{highest.length ? <ol className="category-detail-list">{highest.map((transaction, index) => <li key={transaction.id}><span className="category-detail-rank">{index + 1}</span><div><strong>{compactMerchantName(transaction.description)}</strong><small>{transaction.date} · {transaction.account}</small></div><strong>{displayMoney(Math.abs(transaction.amount))}</strong></li>)}</ol> : <p className="category-detail-empty">Sin movimientos destacados.</p>}</div>
      </div> : <p className="category-detail-empty">No hay movimientos válidos de esta categoría en el periodo seleccionado.</p>}
    </div>}
  </section>;
}

function MerchantRanking({ merchants, period }: { merchants: ReturnType<typeof buildFinanceMetrics>["topMerchants"]; period?: AnalyticsPeriod }) {
  return <section className="detail-card" aria-labelledby="merchant-ranking-title"><div className="section-heading"><div><h2 id="merchant-ranking-title">Top 5 comercios</h2><p>{periodLabel(period)} · ordenados por gasto.</p></div></div>{merchants.length ? <ol className="ranking-list">{merchants.map((merchant) => <li key={merchant.name}><span className="ranking-index" /><div><strong>{merchant.name}</strong><small>{merchant.count} movimiento{merchant.count === 1 ? "" : "s"} · {Math.round(merchant.share * 100)}%</small></div><strong>{displayMoney(merchant.total)}</strong></li>)}</ol> : <EmptyState title="Sin comercios identificados" body="Importa y revisa un estado para ver concentración por comercio." />}</section>;
}

function MovementRanking({ movements, period }: { movements: ReturnType<typeof buildFinanceMetrics>["topMovements"]; period?: AnalyticsPeriod }) {
  return <section className="detail-card" aria-labelledby="movement-ranking-title"><div className="section-heading"><div><h2 id="movement-ranking-title">Top 5 movimientos</h2><p>{periodLabel(period)} · desembolsos más grandes.</p></div></div>{movements.length ? <ol className="ranking-list movement-ranking">{movements.map((movement) => <li key={movement.id}><span className="ranking-index" /><div><strong>{movement.description}</strong><small>{movement.date} · {movement.category || "Sin categoría"}</small></div><strong>{signedMoney(-Math.abs(movement.amount))}</strong></li>)}</ol> : <EmptyState title="Sin movimientos identificados" body="Aquí aparecerán tus desembolsos más relevantes." />}</section>;
}

function TravelTrips({ trips, period }: { trips: TravelTrip[]; period?: AnalyticsPeriod }) {
  const total = trips.reduce((sum, trip) => sum + trip.total, 0);
  return <section className="detail-card travel-trips" aria-labelledby="travel-trips-title"><div className="section-heading"><div><h2 id="travel-trips-title">Viajes</h2><p>{periodLabel(period)} · {period?.spend ? `${Math.round(total / period.spend * 100)}% del gasto` : "sin porcentaje disponible"}.</p></div><strong className="detail-total">{displayMoney(total)}</strong></div>{trips.length ? <div className="travel-list">{trips.map((trip) => <article className="travel-trip" key={trip.id}><div className="travel-trip-head"><div><h3>{trip.name}</h3><small>{trip.startDate}{trip.endDate !== trip.startDate ? ` → ${trip.endDate}` : ""}</small></div><strong>{displayMoney(trip.total)}</strong></div><div className="travel-breakdown">{trip.movements.map((movement) => <div key={movement.id}><span>{movement.description}</span><small>{movement.date}</small><strong>{signedMoney(-Math.abs(movement.amount))}</strong></div>)}</div></article>)}</div> : <EmptyState title="Sin viajes identificados" body="Los movimientos de viaje aparecerán aquí agrupados por fechas." />}</section>;
}

function Accounts({ transactions, statements, metrics, setTransactions, onImport, onMarkReviewed, onLearnCategory }: { transactions: Transaction[]; statements: Statement[]; metrics: ReturnType<typeof buildFinanceMetrics>; setTransactions: React.Dispatch<React.SetStateAction<Transaction[]>>; onImport: () => void; onMarkReviewed: (statementId: string) => void; onLearnCategory: (description: string, category: string) => void }) {
  const [sourceFilter, setSourceFilter] = useState<StatementSource | "Todos">("Todos");
  const [periodFilter, setPeriodFilter] = useState("Todos");
  const [view, setView] = useState<"accounts" | "movements">("accounts");
  const periods = Array.from(new Set(statements.map((item) => item.period)));
  const filteredStatements = statements.filter((item) => (sourceFilter === "Todos" || item.source === sourceFilter) && (periodFilter === "Todos" || item.period === periodFilter));
  const importedSources = Array.from(new Set<StatementSource>(statements.map((item) => item.source)));
  const preferredSources: StatementSource[] = ["Santander", "BBVA", "Amex"];
  const knownSources: StatementSource[] = [
    ...preferredSources.filter((source) => importedSources.includes(source)),
    ...importedSources.filter((source) => !preferredSources.includes(source)).sort((left, right) => left.localeCompare(right)),
  ];
  const tabs = <div className="accounts-tabs" role="tablist" aria-label="Contenido de cuentas">
    <button role="tab" aria-selected={view === "accounts"} className={view === "accounts" ? "active" : ""} onClick={() => setView("accounts")}>Cuentas <span>{knownSources.length}</span></button>
    <button role="tab" aria-selected={view === "movements"} className={view === "movements" ? "active" : ""} onClick={() => setView("movements")}>Movimientos <span>{transactions.length}</span></button>
  </div>;

  if (view === "movements") {
    const movementTransactions = sourceFilter === "Todos" ? transactions : transactions.filter((item) => statements.find((statement) => statement.id === item.statementId)?.source === sourceFilter);
    return <section>{tabs}<Movements transactions={movementTransactions} statements={statements} setTransactions={setTransactions} onLearnCategory={onLearnCategory} onImport={onImport} embedded /></section>;
  }

  return <section>
    <PageHeading title="Cuentas" body="Tus saldos por cuenta, separados de los documentos que los respaldan." action="Importar estado" onAction={onImport} />
    {tabs}
    <section className="accounts-overview" aria-label="Resumen de cuentas">
      {knownSources.length ? <div className="account-card-grid">{knownSources.map((source) => {
        const sourceStatements = statements.filter((item) => item.source === source);
        const latest = latestStatementFor(sourceStatements);
        const period = latest ? metrics.periods.find((item) => item.statementId === latest.id) : undefined;
        const kind = latest?.kind ?? defaultStatementKind(source);
        const balance = kind === "card" ? period?.debtBalance : kind === "bank" ? period?.cashBalance : undefined;
        const balanceLabel = metrics.isProvisional ? "Bloqueado por conciliación" : balance === undefined ? "Pendiente" : kind === "card" ? `−${money.format(balance)}` : money.format(balance);
        const sourceTransactions = transactions.filter((item) => item.statementId && sourceStatements.some((statement) => statement.id === item.statementId));
        return <article className="account-card" key={source}>
          <div className="account-card-head"><span className={`account-icon ${sourceColor(source)}`}>{kind === "card" ? <CreditCard size={22} /> : <Bank size={22} />}</span><small>{kind === "card" ? "Tarjeta de crédito" : kind === "bank" ? "Cuenta de efectivo" : "Tipo pendiente"}</small></div>
          <h3>{source}</h3>
          <strong className={kind === "card" ? "account-card-balance debt" : "account-card-balance"}>{balanceLabel}</strong>
          <p>{metrics.isProvisional ? "Valida los estados antes de mostrar el saldo" : kind === "card" ? `Pago próximo: ${displayMoney(period?.minimumPlusMsi ?? period?.minimumPayment)} · No intereses: ${displayMoney(period?.paymentForNoInterest)}` : kind === "bank" ? "Cuenta de efectivo" : "Confirma el tipo en el documento importado"}</p>
          <small>{sourceTransactions.length} movimientos · {sourceStatements.length} estado(s)</small>
          <button className="account-card-link" onClick={() => { setSourceFilter(source); setView("movements"); }}>Ver movimientos <ArrowRight size={16} /></button>
        </article>;
      })}</div> : <EmptyState title="Aún no hay cuentas" body="Importa un estado de cuenta para construir tus saldos reales." />}
    </section>
    <details className="documents-panel">
      <summary><div><h2>Documentos importados</h2><span>{statements.length ? `${statements.length} archivos guardados localmente.` : "Aquí aparecerán tus PDFs revisados."}</span></div><strong>{statements.length}</strong></summary>
      <div className="documents-content">
        {statements.length ? <><div className="statement-filters"><select aria-label="Filtrar por banco" value={sourceFilter} onChange={(event) => setSourceFilter(event.target.value as StatementSource | "Todos")}><option value="Todos">Todos los bancos</option>{importedSources.map((source) => <option key={source} value={source}>{source}</option>)}</select><select aria-label="Filtrar por periodo" value={periodFilter} onChange={(event) => setPeriodFilter(event.target.value)}><option value="Todos">Todos los periodos</option>{periods.map((period) => <option key={period} value={period}>{period}</option>)}</select></div>{filteredStatements.length ? <div className="statement-list">{filteredStatements.map((statement) => <article className="statement-row" key={statement.id}><span className={`statement-icon ${sourceColor(statement.source)}`}><FilePdf size={20} /></span><div className="statement-main"><strong>{statement.source}</strong><span>{statement.period}</span><small>{statement.fileName} · Importado {statementDate(statement)} · {statement.transactionCount} movimientos · {statement.mode === "text" ? "lectura directa" : `OCR en el dispositivo${statement.ocrConfidence !== undefined ? ` · ${Math.round(statement.ocrConfidence * 100)}% confianza` : ""}${statementOcrPageLabel(statement)}`}{statement.reconciliationStatus ? ` · ${statement.reconciliationStatus === "valid" ? "conciliado" : "conciliación pendiente"}` : ""}</small></div><span className={`statement-status ${statement.status}`}>{statement.status === "ready" ? "Revisado" : "Pendiente"}</span>{statement.status === "review" && <button className="text-button statement-action" onClick={() => onMarkReviewed(statement.id)}>Marcar revisado</button>}</article>)}</div> : <EmptyState title="No coincide ningún documento" body="Prueba otro banco o periodo." />}</> : <EmptyState title="No hay documentos importados" body="Tus estados de cuenta aparecerán aquí después de revisarlos." />}
      </div>
    </details>
  </section>;
}
function NetWorthBase({ metrics }: { metrics: ReturnType<typeof buildFinanceMetrics> }) {
  const trend = metrics.liquidPatrimonyChangePercent;
  const trendLabel = comparisonPercent(trend);
  if (metrics.isProvisional) return <section><PageHeading title="Patrimonio" body="Los saldos se muestran cuando cada estado concilia." /><DashboardBlockedNotice metrics={metrics} /><DataQualityIndicator metrics={metrics} /></section>;
  return <section>
    <PageHeading title="Patrimonio" body="Cuánto tienes, cómo cambió y qué parte está en efectivo o deuda." />
    <div className="patrimony-analytics-grid">
      <section className="detail-card patrimony-chart-card" aria-labelledby="patrimony-history-title"><div className="section-heading"><div><h2 id="patrimony-history-title">Evolución histórica</h2><p>Patrimonio líquido por periodo · efectivo menos deuda.</p></div></div><PatrimonyChart periods={metrics.analyticsPeriods} /></section>
      <section className="patrimony-balances" aria-label="Saldos de patrimonio"><BalanceMetric label="Efectivo" value={displayMoney(metrics.cashAvailable)} comparison={comparisonMoney(metrics.cashAvailable, metrics.analyticsPeriods[1]?.cashAvailable)} tone="cash" /><BalanceMetric label="Deuda" value={displayMoney(metrics.debtTotal)} comparison={comparisonMoney(metrics.debtTotal, metrics.analyticsPeriods[1]?.debtTotal)} tone="debt" /><BalanceMetric label="Patrimonio neto" value={displayMoney(metrics.liquidPatrimony)} comparison={trendLabel} tone="net" /></section>
    </div>
  </section>;
}

function NetWorth({ metrics }: { metrics: ReturnType<typeof buildFinanceMetrics> }) {
  return <><NetWorthBase metrics={metrics} /><details className="technical-details"><summary>Ver detalle de conciliación</summary><CalculationSummary metrics={metrics} /></details></>;
}

function PatrimonyChart({ periods }: { periods: AnalyticsPeriod[] }) {
  const chartPeriods = periods.filter((period) => period.liquidPatrimony !== undefined).slice(0, 6).reverse();
  if (!chartPeriods.length) return <EmptyState title="Sin historial de saldos" body="Completa efectivo y deuda en Cuentas para construir la evolución histórica." />;
  const width = 720;
  const height = 220;
  const padding = { top: 22, right: 22, bottom: 30, left: 22 };
  const values = chartPeriods.map((period) => period.liquidPatrimony ?? 0);
  const minValue = Math.min(...values, 0);
  const maxValue = Math.max(...values, 0);
  const range = maxValue - minValue || 1;
  const step = chartPeriods.length === 1 ? 0 : (width - padding.left - padding.right) / (chartPeriods.length - 1);
  const yFor = (value: number) => height - padding.bottom - ((value - minValue) / range) * (height - padding.top - padding.bottom);
  const zeroY = yFor(0);
  const points = chartPeriods.map((period, index) => ({ period, x: padding.left + index * step, y: yFor(period.liquidPatrimony ?? 0) }));
  return <div className="patrimony-chart-wrap"><svg className="patrimony-chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Evolución histórica del patrimonio líquido"><line x1={padding.left} x2={width - padding.right} y1={zeroY} y2={zeroY} className="trend-baseline" /><polyline points={points.map(({ x, y }) => `${x},${y}`).join(" ")} className="patrimony-line" />{points.map(({ period, x, y }) => <circle key={period.key} cx={x} cy={y} r="5" className="patrimony-point"><title>{`${period.label}: ${displayMoney(period.liquidPatrimony)}`}</title></circle>)}</svg><div className="trend-values patrimony-values">{chartPeriods.map((period) => <div key={period.key}><span>{period.label}</span><strong>{displayMoney(period.liquidPatrimony)}</strong><small>{comparisonPercent(period.patrimonyVariationPercent)}</small></div>)}</div></div>;
}

function BalanceMetric({ label, value, comparison, tone }: { label: string; value: string; comparison: string; tone: "cash" | "debt" | "net" }) {
  return <article className={`balance-metric balance-${tone}`}><span>{label}</span><strong>{value}</strong><small>{comparison}</small></article>;
}

function PageHeading({ title, body, action, onAction }: { title: string; body: string; action?: string; onAction?: () => void }) {
  return <div className="page-heading"><div><h1>{title}</h1><p>{body}</p></div>{action && <button className="secondary-button" onClick={onAction}><Plus size={17} />{action}</button>}</div>;
}

function EmptyState({ title, body }: { title: string; body: string }) {
  return <div className="empty-state"><ListMagnifyingGlass size={32} /><h3>{title}</h3><p>{body}</p></div>;
}

function ImportDialog({ open, onClose, onSave, categoryRules }: { open: boolean; onClose: () => void; onSave: (commit: ImportCommit) => void; categoryRules: CategoryRules }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [stage, setStage] = useState<"pick" | "processing" | "review" | "error">("pick");
  const [progress, setProgress] = useState(0);
  const [progressLabel, setProgressLabel] = useState("");
  const [result, setResult] = useState<ImportResult | null>(null);
  const [items, setItems] = useState<Transaction[]>([]);
  const [summary, setSummary] = useState<StatementSummary>({});
  const [reviewSource, setReviewSource] = useState<StatementSource>("Desconocido");
  const [reviewKind, setReviewKind] = useState<StatementKind>("unknown");
  const [error, setError] = useState("");
  const initialCategories = useRef<Record<string, string>>({});

  if (open && dialog.current && !dialog.current.open) dialog.current.showModal();
  if (!open && dialog.current?.open) dialog.current.close();

  async function handleFile(file?: File) {
    if (!file) return;
    if (file.type !== "application/pdf" && !file.name.toLowerCase().endsWith(".pdf")) { setError("Selecciona un archivo PDF válido."); setStage("error"); return; }
    setStage("processing"); setProgress(0); setProgressLabel("Cargando estado de cuenta…"); setError("");
    try {
      const inspected = await inspectPdf(file, (value, label) => { setProgress(value); setProgressLabel(label); });
      const withLearnedCategories = inspected.transactions.map((item) => {
        const learned = categoryFromRules(item.description, categoryRules);
        return learned ? { ...item, category: learned, confidence: 1 } : item;
      });
      initialCategories.current = Object.fromEntries(withLearnedCategories.map((item) => [item.id, item.category]));
      setResult({ ...inspected, transactions: withLearnedCategories }); setItems(withLearnedCategories); setSummary(inspected.summary ?? {}); setReviewSource(inspected.source); setReviewKind(inspected.kind); setStage("review");
    } catch (cause) {
      const safeMessage = cause instanceof Error && cause.message.startsWith("El PDF")
        ? cause.message
        : "No pudimos leer este PDF. El archivo no se modificó; intenta con otra copia.";
      setError(safeMessage); setStage("error");
    }
  }

  function updateItem(id: string, key: "description" | "category", value: string) { setItems((current) => current.map((item) => item.id === id ? { ...item, [key]: value } : item)); }
  function updateAmount(id: string, value: string) { setItems((current) => current.map((item) => item.id === id ? { ...item, amount: Math.abs(Number(value) || 0) * (item.amount > 0 ? 1 : -1) } : item)); }
  function addManualItem() { setItems((current) => [...current, { id: `manual-${Date.now()}`, date: "Sin fecha", description: "Movimiento por revisar", account: result?.source ?? "Desconocido", category: "Sin categoría", amount: -1, flow: "expense", confidence: 1 }]); }

  function resetAndClose() { setStage("pick"); setProgress(0); setProgressLabel(""); setResult(null); setItems([]); setSummary({}); setReviewSource("Desconocido"); setReviewKind("unknown"); setError(""); initialCategories.current = {}; onClose(); }

  function updateSummary(key: keyof StatementSummary, value: string) {
    setSummary((current) => {
      const next = { ...current };
      if (!value.trim()) delete next[key];
      else next[key] = Number(value.replace(/,/g, "")) as never;
      return next;
    });
  }

  const validItems = items.filter((item) => item.description.trim().length >= 3 && Number.isFinite(item.amount) && item.amount !== 0);
  const currentReconciliation = result
    ? gateOcrReconciliation(
      reconcileStatementImport(reviewKind, summary, validItems),
      result.mode,
      result.ocrConfidence,
      result.ocrPageConfidences,
    )
    : undefined;
  const reconciliationBlocked = Boolean(currentReconciliation && currentReconciliation.status !== "valid");
  const learnedCategories = Object.fromEntries(validItems.flatMap((item) => {
    const previous = initialCategories.current[item.id];
    const key = merchantKey(item.description);
    return key && previous && previous !== item.category && item.category !== "Sin categoría" ? [[key, item.category]] : [];
  }));
  return <dialog ref={dialog} className="import-dialog" onCancel={(event) => { event.preventDefault(); resetAndClose(); }}><div className="dialog-head"><div><span className="dialog-icon"><FilePdf size={21} /></span><div><h2>Importar estado de cuenta</h2><p>El archivo se procesa localmente y conserva su origen.</p></div></div><button className="icon-button" aria-label="Cerrar" onClick={resetAndClose}><X size={20} /></button></div>
    {stage === "pick" && <label className="drop-zone"><input type="file" accept="application/pdf" onChange={(event) => handleFile(event.target.files?.[0])} /><UploadSimple size={30} /><strong>Selecciona tu PDF mensual</strong><span>Se detectarán banco, periodo y movimientos. Los estados escaneados se leen con OCR y quedan pendientes de confirmación.</span><span className="file-button">Elegir archivo</span></label>}
    {stage === "processing" && <div className="processing-state" role="status" aria-live="polite" aria-busy="true"><div className="loading-orbit" aria-hidden="true"><CircleNotch size={34} className="spinner" /><span className="loading-pulse"><i /><i /><i /></span></div><h3>{progressLabel || "Cargando estado de cuenta…"}</h3><p>Estamos leyendo y conciliando tu estado. No cierres esta ventana.</p><div className="progress-track" aria-hidden="true"><span style={{ width: `${progress}%` }} /></div><small>{progress}% completado</small></div>}
    {stage === "error" && <div className="error-state"><Warning size={34} /><h3>No pudimos completar la importación</h3><p>{error}</p><button className="secondary-button" onClick={() => setStage("pick")}>Intentar de nuevo</button></div>}
    {stage === "review" && result && <div className="review-state"><div className="review-summary"><div><span>Origen detectado</span><strong>{result.source}</strong></div><div><span>Periodo</span><strong>{result.period}</strong></div><div><span>Método</span><strong>{result.mode === "text" ? "Lectura directa" : "OCR en el dispositivo"}</strong></div><div><span>Movimientos</span><strong>{validItems.length}</strong></div>{result.mode === "ocr" && <div><span>Confianza OCR</span><strong>{Math.round((result.ocrConfidence ?? 0) * 100)}%</strong></div>}</div><div className={`reconciliation-callout ${currentReconciliation?.status ?? "pending"}`} role="status"><div><strong>{currentReconciliation?.status === "valid" ? "Importación conciliada" : currentReconciliation?.status === "invalid" ? "Importación bloqueada" : "Conciliación pendiente"}</strong><p>{currentReconciliation?.status === "valid" ? "Las filas extraídas coinciden con los totales declarados por el estado." : currentReconciliation?.reason ?? "Completa o revisa los totales declarados antes de guardar."}</p></div><small>{currentReconciliation ? `Tolerancia ±${currentReconciliation.tolerance.toFixed(2)}` : ""}</small></div><div className="review-source-editor"><label><span>Nombre que se guardará</span><input value={reviewSource} onChange={(event) => setReviewSource(event.target.value as StatementSource)} placeholder="Ej. Santander, Nómina o Banco personal" /></label><label><span>Tipo de archivo</span><select value={reviewKind} onChange={(event) => setReviewKind(event.target.value as StatementKind)}><option value="card">Tarjeta de crédito</option><option value="bank">Cuenta bancaria</option><option value="unknown">No identificado</option></select></label><p>Corrige el origen aquí si el PDF usa una marca o formato que todavía no conocemos. Las categorías que ajustes se recordarán para el siguiente mes.</p></div>{result.mode === "ocr" && <div className="ocr-callout"><Warning size={21} /><div><strong>Este PDF es una imagen escaneada</strong><p>Marcelito convirtió sus páginas a imagen y ejecutó OCR en tu navegador. Confirma los importes y agrega cualquier movimiento que no se haya reconocido.</p><button className="secondary-button" onClick={addManualItem}><Plus size={16} />Agregar movimiento</button></div></div>}{items.length ? <div className="review-table">{items.map((item) => <div className="review-row" key={item.id}><div><input aria-label="Descripción" value={item.description} onChange={(event) => updateItem(item.id, "description", event.target.value)} /><small>{item.date} · confianza {Math.round((item.confidence ?? 0) * 100)}%</small></div><select aria-label="Categoría" value={item.category} onChange={(event) => updateItem(item.id, "category", event.target.value)}>{["Ingresos", "Transferencia", ...categories].map((category) => <option key={category}>{category}</option>)}</select><input className={item.amount > 0 ? "review-amount positive" : "review-amount"} aria-label="Importe" type="number" step="0.01" value={Math.abs(item.amount)} onChange={(event) => updateAmount(item.id, event.target.value)} /></div>)}</div> : <EmptyState title="Estado listo para guardar" body="No detectamos movimientos automáticos, pero sí conservaremos banco, periodo y archivo para que lo completes." />}
      <div className="dialog-actions"><button className="text-button" onClick={() => setStage("pick")}>Elegir otro archivo</button><button className="primary-button" disabled={reconciliationBlocked} title={reconciliationBlocked ? "No se puede guardar hasta conciliar el estado" : undefined} onClick={() => currentReconciliation?.status === "valid" && onSave({ source: reviewSource.trim() || "Desconocido", kind: reviewKind, period: result.period, fileName: result.fileName, mode: result.mode, transactions: validItems.map((item) => ({ ...item, account: reviewSource.trim() || item.account })) , summary, reconciliation: currentReconciliation, sourceDetection: result.sourceDetection, ocrConfidence: result.ocrConfidence, ocrPageConfidences: result.ocrPageConfidences, categoryRules: learnedCategories })}><Check size={18} />{reconciliationBlocked ? "Corregir conciliación para guardar" : validItems.length ? `Guardar estado y ${validItems.length} movimientos` : "Guardar estado conciliado"}</button></div></div>}
    {stage === "review" && result && <StatementSummaryForm source={reviewSource} kind={reviewKind} summary={summary} onChange={updateSummary} />}
  </dialog>;
}

export default function App() {
  const stored = useMemo(() => { try { return JSON.parse(localStorage.getItem("marcelito-profile") ?? "null") as { name: string } | null; } catch { return null; } }, []);
  const [user, setUser] = useState(stored?.name ?? "");
  function handleDeleteAccount() {
    if (!window.confirm("Se eliminarán tu cuenta local y todos los movimientos y estados guardados en este dispositivo. Esta acción no se puede deshacer.")) return;
    deleteLocalAccount();
    setUser("");
  }
  function handleSignOut() {
    clearLocalSession();
    setUser("");
  }
  return user ? <AppShell user={user} onSignOut={handleSignOut} onDeleteAccount={handleDeleteAccount} /> : <AuthGate onEnter={setUser} />;
}
