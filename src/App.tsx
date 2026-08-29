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
  Fingerprint,
  House,
  Lightbulb,
  ListMagnifyingGlass,
  LockKey,
  PencilSimple,
  Plus,
  Receipt,
  ShieldCheck,
  SignOut,
  Sparkle,
  Trash,
  UploadSimple,
  User,
  Wallet,
  Warning,
  X,
} from "@phosphor-icons/react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { categories } from "./data";
import { inspectPdf } from "./pdfImport";
import type { ImportCommit, ImportResult, Section, Statement, StatementSource, Transaction } from "./types";

const money = new Intl.NumberFormat("es-MX", { style: "currency", currency: "MXN", maximumFractionDigits: 0 });
const moneyPrecise = new Intl.NumberFormat("es-MX", { style: "currency", currency: "MXN", minimumFractionDigits: 2 });
const transactionStorageKey = "marcelito-transactions.v2";
const statementStorageKey = "marcelito-statements.v1";
type LocalAccount = { username: string; passwordHash: string };
const seededAccount: LocalAccount = { username: "Marcelodiazs", passwordHash: "ed6357244f855d10e821359702d859df700ba81431a98b88ba1de5156a1e9f61" };

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

function amountFor(transactions: Transaction[], flow: Transaction["flow"]) {
  return transactions.filter((item) => item.flow === flow).reduce((sum, item) => sum + Math.abs(item.amount), 0);
}

function statementDate(statement: Statement) {
  return new Intl.DateTimeFormat("es-MX", { dateStyle: "medium" }).format(new Date(statement.importedAt));
}

function statementLabel(statement?: Statement) {
  if (!statement) return "Movimiento manual";
  return `${statement.source} · ${statement.period}`;
}

function sourceColor(source: StatementSource) {
  return source === "Amex" ? "statement-amex" : source === "Santander" ? "statement-santander" : source === "BBVA" ? "statement-bbva" : "statement-unknown";
}

const navItems: { label: Section; icon: typeof House }[] = [
  { label: "Inicio", icon: House },
  { label: "Movimientos", icon: Receipt },
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
        <div className="brand brand-large"><span className="brand-mark">M</span><span>Marcelito</span></div>
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
          <div className="mobile-brand brand"><span className="brand-mark">M</span><span>Marcelito</span></div>
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
  const [section, setSection] = useState<Section>("Inicio");
  const [transactions, setTransactions] = useState<Transaction[]>(() => readStored(transactionStorageKey, []));
  const [statements, setStatements] = useState<Statement[]>(() => readStored(statementStorageKey, []));
  const [importOpen, setImportOpen] = useState(false);
  const reduceMotion = useReducedMotion();
  const latestStatement = statements[0];

  useEffect(() => {
    localStorage.setItem(transactionStorageKey, JSON.stringify(transactions));
  }, [transactions]);

  useEffect(() => {
    localStorage.setItem(statementStorageKey, JSON.stringify(statements));
  }, [statements]);

  function saveImport(commit: ImportCommit) {
    const previous = statements.find((item) => item.fileName === commit.fileName && item.source === commit.source && item.period === commit.period);
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
      status: importedTransactions.length ? "ready" : "review",
    };

    setStatements((current) => previous ? current.map((item) => item.id === statementId ? statement : item) : [statement, ...current]);
    setTransactions((current) => {
      const withoutPrevious = previous ? current.filter((item) => item.statementId !== statementId) : current;
      const fresh = importedTransactions.filter((item) => !withoutPrevious.some((saved) => saved.date === item.date && saved.description === item.description && saved.amount === item.amount && saved.account === item.account));
      return [...fresh, ...withoutPrevious];
    });
    setImportOpen(false);
  }

  function markStatementReviewed(statementId: string) {
    setStatements((current) => current.map((item) => item.id === statementId ? { ...item, status: "ready" } : item));
  }

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand"><span className="brand-mark">M</span><span>Marcelito</span></div>
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
            {section === "Inicio" && <Home transactions={transactions} statements={statements} onImport={() => setImportOpen(true)} />}
            {section === "Movimientos" && <Movements transactions={transactions} statements={statements} setTransactions={setTransactions} />}
            {section === "Gastos" && <Expenses transactions={transactions} statements={statements} />}
            {section === "Cuentas" && <Accounts transactions={transactions} statements={statements} onImport={() => setImportOpen(true)} onMarkReviewed={markStatementReviewed} />}
            {section === "Patrimonio" && <NetWorth transactions={transactions} statements={statements} />}
          </motion.div>
        </AnimatePresence>
      </main>
      <nav className="mobile-nav" aria-label="Navegación principal móvil">
        {navItems.map(({ label, icon: Icon }) => <button key={label} className={section === label ? "active" : ""} onClick={() => setSection(label)}><Icon size={21} weight={section === label ? "fill" : "regular"} /><span>{label}</span></button>)}
      </nav>
      <ImportDialog open={importOpen} onClose={() => setImportOpen(false)} onSave={saveImport} />
    </div>
  );
}

function Home({ transactions, statements, onImport }: { transactions: Transaction[]; statements: Statement[]; onImport: () => void }) {
  const expenseTotal = amountFor(transactions, "expense");
  const incomeTotal = amountFor(transactions, "income");
  const transferTotal = amountFor(transactions, "transfer");
  const latest = statements[0];
  const accountEntries = Array.from(transactions.reduce((map, item) => {
    const current = map.get(item.account) ?? { total: 0, count: 0 };
    map.set(item.account, { total: current.total + Math.abs(item.amount), count: current.count + 1 });
    return map;
  }, new Map<string, { total: number; count: number }>()).entries()).sort((a, b) => b[1].total - a[1].total).slice(0, 2);
  const displayAccounts: Array<[string, { total: number; count: number }]> = accountEntries.length ? accountEntries : [["Sin banco", { total: 0, count: 0 }]];
  const categoryEntries = Array.from(transactions.filter((item) => item.flow === "expense").reduce((map, item) => map.set(item.category, (map.get(item.category) ?? 0) + Math.abs(item.amount)), new Map<string, number>()).entries()).sort((a, b) => b[1] - a[1]).slice(0, 5);

  if (!transactions.length && !statements.length) {
    return <RealDataEmpty onImport={onImport} />;
  }

  return (
    <>
      <section className="home-heading">
        <div><h1>Tu dinero, explicado.</h1><p>{latest ? `Último estado: ${latest.source} · ${latest.period}. Revisa cada movimiento antes de tomar decisiones.` : "Agrega movimientos manuales o importa tu primer estado de cuenta."}</p></div>
        <span className="month-button data-period">{latest?.period ?? "Sin periodo"}</span>
      </section>
      <section className="hero-balance">
        <div className="balance-main">
          <span>Gasto identificado</span>
          <strong>{money.format(expenseTotal)}</strong>
          <p>{transactions.length} movimientos · {statements.length} estados importados</p>
        </div>
        <div className="balance-story">
          <Sparkle size={24} weight="fill" />
          <div><strong>{latest ? "Datos reales listos para revisar" : "Movimientos manuales"}</strong><p>{latest ? `El archivo ${latest.fileName} se guardó con su banco y periodo. Los saldos de corte se mantienen pendientes hasta capturarlos.` : "Estos movimientos no provienen de un estado asociado. Importa un PDF para conservar el origen."}</p></div>
          <button aria-label="Importar otro estado" onClick={onImport}><ArrowRight size={19} /></button>
        </div>
      </section>
      <section className="live-metrics" aria-label="Indicadores de los datos importados">
        <Metric label="Ingresos detectados" value={money.format(incomeTotal)} delta="Desde tus estados" tone="income" icon={Wallet} />
        <Metric label="Transferencias" value={money.format(transferTotal)} delta="Flujo interno" tone="transfer" icon={ArrowsLeftRight} />
        <Metric label="Gasto identificado" value={money.format(expenseTotal)} delta={`${categoryEntries.length} categorías`} tone="expense" icon={Receipt} />
      </section>
      <section className="money-section">
        <div className="section-heading"><div><h2>Así se movió tu dinero</h2><p>Los importes salen únicamente de movimientos que cargaste o agregaste.</p></div><div className="legend"><span className="income-text">Ingreso</span><span className="transfer-text">Transferencia</span><span className="expense-text">Gasto</span></div></div>
        <div className="money-map">
          <FlowNode icon={Wallet} title="Ingresos" value={money.format(incomeTotal)} tone="income" detail={`${transactions.filter((item) => item.flow === "income").length} movimientos`} />
          <FlowConnector tone="income" value={money.format(incomeTotal)} />
          <div className="account-nodes">
            {displayAccounts.map(([account, data]) => <FlowNode key={account} icon={Bank} title={account} value={money.format(data.total)} tone="transfer" detail={`${data.count} movimientos`} />)}
          </div>
          <FlowConnector tone="transfer" value={money.format(transferTotal)} />
          <FlowNode icon={ArrowsLeftRight} title="Transferencias" value={money.format(transferTotal)} tone="transfer" detail="Movimientos internos" />
          <FlowConnector tone="expense" value={money.format(expenseTotal)} />
          <FlowNode icon={Receipt} title="Gasto real" value={money.format(expenseTotal)} tone="expense" detail="Sin saldos inventados" />
        </div>
      </section>
      <section className="decision-grid">
        <div className="decision-list">
          <div className="section-heading simple"><div><h2>Revisión pendiente</h2><p>Conserva el contexto de cada archivo antes de conciliar.</p></div></div>
          {latest && <Insight icon={FilePdf} title={`${latest.source} · ${latest.period}`} body={`${latest.transactionCount} movimientos guardados desde ${latest.fileName}. Estado: ${latest.status === "ready" ? "revisado" : "requiere revisión"}.`} action="Ver en Cuentas" />}
          <Insight icon={ListMagnifyingGlass} title={`${transactions.filter((item) => !item.category || item.category === "Sin categoría").length} movimientos sin categoría`} body="Pulir las categorías cambia la lectura de gasto, pero nunca modifica el archivo original." action="Revisar movimientos" />
        </div>
        <div className="spending-shape">
          <div className="shape-head"><div><h3>En qué se fue</h3><span>{money.format(expenseTotal)} identificado</span></div><button aria-label="Ver gastos"><ArrowRight size={18} /></button></div>
          {categoryEntries.length ? <div className="shape-grid">{categoryEntries.map(([category, amount], index) => <div className={`shape ${["travel", "food", "dining", "services", "other"][index] ?? "other"}`} key={category}><strong>{category}</strong><span>{money.format(amount)}</span><small>{expenseTotal ? `${Math.round(amount / expenseTotal * 100)}%` : "0%"}</small></div>)}</div> : <EmptyState title="Sin gastos todavía" body="Importa un estado o agrega un movimiento para construir tu lectura real." />}
        </div>
      </section>
    </>
  );
}

function RealDataEmpty({ onImport }: { onImport: () => void }) {
  return <section className="real-data-empty"><div className="real-data-icon"><FilePdf size={32} /></div><h1>Empieza con tus estados reales</h1><p>Marcelito no carga cifras de muestra. Importa un PDF mensual y revisa banco, periodo, movimientos y categorías antes de guardarlo.</p><button className="primary-button" onClick={onImport}><UploadSimple size={18} />Importar primer estado</button><small>El archivo se procesa localmente y no se sube a ningún servidor.</small></section>;
}

function Metric({ label, value, delta, tone, icon: Icon }: { label: string; value: string; delta: string; tone: string; icon: typeof Wallet }) {
  return <article className={`metric metric-${tone}`}><div className="metric-icon"><Icon size={20} /></div><div><span>{label}</span><strong>{value}</strong><small>{delta}</small></div></article>;
}

function FlowNode({ icon: Icon, title, value, tone, detail }: { icon: typeof Wallet; title: string; value: string; tone: string; detail: string }) {
  return <div className={`flow-node node-${tone}`}><div className="node-icon"><Icon size={21} /></div><div><span>{title}</span><strong>{value}</strong><small>{detail}</small></div></div>;
}

function FlowConnector({ tone, value }: { tone: string; value: string }) {
  return <div className={`flow-connector connector-${tone}`}><span>{value}</span><ArrowRight size={17} weight="bold" /></div>;
}

function Insight({ icon: Icon, title, body, action }: { icon: typeof Lightbulb; title: string; body: string; action: string }) {
  return <article className="insight"><div className="insight-icon"><Icon size={21} /></div><div><strong>{title}</strong><p>{body}</p></div><button>{action}<ArrowRight size={16} /></button></article>;
}

function Movements({ transactions, statements, setTransactions }: { transactions: Transaction[]; statements: Statement[]; setTransactions: React.Dispatch<React.SetStateAction<Transaction[]>> }) {
  const [query, setQuery] = useState("");
  const filtered = transactions.filter((item) => {
    const statement = statements.find((source) => source.id === item.statementId);
    return `${item.description} ${item.category} ${item.account} ${statementLabel(statement)} ${statement?.fileName ?? ""}`.toLowerCase().includes(query.toLowerCase());
  });
  function updateCategory(id: string, category: string) { setTransactions((items) => items.map((item) => item.id === id ? { ...item, category } : item)); }
  return <section><PageHeading title="Movimientos" body="Busca, corrige y conecta cada movimiento con su estado de cuenta." action="Agregar movimiento" /><div className="filter-row"><div className="search-box"><ListMagnifyingGlass size={19} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Buscar comercio, banco, periodo o categoría" /></div><span className="result-count">{filtered.length} de {transactions.length}</span></div>{filtered.length ? <div className="movement-list">{filtered.map((item) => { const statement = statements.find((source) => source.id === item.statementId); return <div className="movement-row" key={item.id}><span className={`movement-glyph glyph-${item.flow}`}>{item.flow === "transfer" ? <ArrowsLeftRight size={18} /> : item.flow === "income" ? <ArrowDown size={18} /> : <Receipt size={18} />}</span><div className="movement-name"><strong>{item.description}</strong><span>{item.date} · {item.account} · {statementLabel(statement)}</span></div><select aria-label={`Categoría de ${item.description}`} value={item.category} onChange={(event) => updateCategory(item.id, event.target.value)}>{["Ingresos", "Transferencia", ...categories].map((category) => <option key={category}>{category}</option>)}</select><strong className={item.amount > 0 ? "amount positive" : "amount"}>{moneyPrecise.format(item.amount)}</strong><button className="row-action" aria-label={`Editar ${item.description}`}><PencilSimple size={17} /></button></div>; })}</div> : <EmptyState title="No hay movimientos reales" body="Importa un estado de cuenta o agrega un movimiento manual para empezar." />}</section>;
}

function Expenses({ transactions, statements }: { transactions: Transaction[]; statements: Statement[] }) {
  const groups = Array.from(transactions.filter((item) => item.flow === "expense").reduce((map, item) => map.set(item.category, (map.get(item.category) ?? 0) + Math.abs(item.amount)), new Map<string, number>()).entries()).sort((a, b) => b[1] - a[1]);
  const total = groups.reduce((sum, [, amount]) => sum + amount, 0);
  const latest = statements[0];
  if (!transactions.length) return <section><PageHeading title="Gastos" body="El gasto real se calcula a partir de tus movimientos importados." action="Importar estado" /><EmptyState title="Todavía no hay gastos" body="Carga un PDF mensual para ver categorías construidas con tus datos." /></section>;
  const top = groups[0];
  return <section><PageHeading title="Gastos" body="El gasto real excluye transferencias y conserva el origen de cada movimiento." action="Revisar categorías" /><div className="expense-layout"><div className="expense-map">{groups.length ? <div className="shape-grid large">{groups.slice(0, 5).map(([category, amount], index) => <div className={`shape ${["travel", "food", "dining", "services", "other"][index] ?? "other"}`} key={category}><strong>{category}</strong><span>{money.format(amount)}</span><small>{total ? `${Math.round(amount / total * 100)}% del gasto` : ""}</small></div>)}</div> : <EmptyState title="Sin gastos identificados" body="Tus movimientos todavía no tienen cargos clasificados." />}</div><aside className="story-card"><span className="story-month">{latest ? `${latest.source} · ${latest.period}` : "Movimientos manuales"}</span><h2>{top ? top[0] : "Sin categoría"}</h2><p>{top ? `Es la categoría con mayor peso: ${money.format(top[1])} de ${money.format(total)} identificados. Puedes corregir cada movimiento desde Movimientos.` : "Cuando importe un estado, aquí aparecerá la historia que más explica tu gasto."}</p><div className="story-total"><span>Total identificado</span><strong>{money.format(total)}</strong></div></aside></div></section>;
}

function Accounts({ transactions, statements, onImport, onMarkReviewed }: { transactions: Transaction[]; statements: Statement[]; onImport: () => void; onMarkReviewed: (statementId: string) => void }) {
  const [sourceFilter, setSourceFilter] = useState<StatementSource | "Todos">("Todos");
  const [periodFilter, setPeriodFilter] = useState("Todos");
  const periods = Array.from(new Set(statements.map((item) => item.period)));
  const filteredStatements = statements.filter((item) => (sourceFilter === "Todos" || item.source === sourceFilter) && (periodFilter === "Todos" || item.period === periodFilter));
  const knownSources: StatementSource[] = ["Santander", "BBVA", "Amex"];
  return <section><PageHeading title="Cuentas" body="Aquí puedes ver qué banco y qué periodo alimentan tus datos." action="Importar estado" onAction={onImport} /><div className="statement-ledger"><div className="section-heading"><div><h2>Estados de cuenta</h2><p>{statements.length ? `${statements.length} archivos guardados localmente.` : "Aún no has guardado ningún estado."}</p></div><div className="statement-filters"><select aria-label="Filtrar por banco" value={sourceFilter} onChange={(event) => setSourceFilter(event.target.value as StatementSource | "Todos")}><option value="Todos">Todos los bancos</option>{knownSources.map((source) => <option key={source} value={source}>{source}</option>)}</select><select aria-label="Filtrar por periodo" value={periodFilter} onChange={(event) => setPeriodFilter(event.target.value)}><option value="Todos">Todos los periodos</option>{periods.map((period) => <option key={period} value={period}>{period}</option>)}</select></div></div>{filteredStatements.length ? <div className="statement-list">{filteredStatements.map((statement) => <article className="statement-row" key={statement.id}><span className={`statement-icon ${sourceColor(statement.source)}`}><FilePdf size={20} /></span><div className="statement-main"><strong>{statement.source}</strong><span>{statement.period} · {statement.fileName}</span><small>Importado {statementDate(statement)} · {statement.transactionCount} movimientos · {statement.mode === "text" ? "lectura directa" : "requiere revisión visual"}</small></div><span className={`statement-status ${statement.status}`}>{statement.status === "ready" ? "Revisado" : "Pendiente"}</span>{statement.status === "review" && <button className="text-button statement-action" onClick={() => onMarkReviewed(statement.id)}>Marcar revisado</button>}</article>)}</div> : <EmptyState title="No coincide ningún estado" body="Prueba otro banco o periodo, o importa un nuevo PDF." />}</div><div className="accounts-layout"><div className="account-list">{knownSources.map((source) => { const sourceStatements = statements.filter((item) => item.source === source); const sourceTransactions = transactions.filter((item) => item.statementId && sourceStatements.some((statement) => statement.id === item.statementId)); const latest = sourceStatements[0]; return <article className="account-row" key={source}><span className={`account-icon ${sourceColor(source)}`}><Bank size={22} /></span><div><h3>{source}</h3><p>{latest ? `${sourceStatements.length} estado(s) · último: ${latest.period}` : "Sin estados importados"}</p></div><strong>{sourceTransactions.length} mov.</strong><button aria-label={`Filtrar ${source}`} onClick={() => setSourceFilter(source)}><ArrowRight size={18} /></button></article>; })}</div><aside className="account-rule"><Fingerprint size={26} /><h3>Origen visible</h3><p>Cada movimiento conserva el banco, el periodo y el nombre del archivo que lo originó. Los saldos de corte se incorporarán cuando estén disponibles en el documento.</p></aside></div></section>;
}

function NetWorth({ transactions, statements }: { transactions: Transaction[]; statements: Statement[] }) {
  const expenses = amountFor(transactions, "expense");
  const income = amountFor(transactions, "income");
  return <section><PageHeading title="Patrimonio" body="No mostramos un patrimonio inventado: primero necesitamos saldos al corte conciliados." action="Ver estados" /><div className="networth-hero"><div><span>Patrimonio líquido</span><strong>—</strong><p>Saldo pendiente de capturar desde tus estados.</p></div><div className="balance-story"><Sparkle size={24} weight="fill" /><div><strong>La historia ya está separada</strong><p>{statements.length ? `${statements.length} estados alimentan ${transactions.length} movimientos: ${money.format(income)} de ingresos y ${money.format(expenses)} de gasto.` : "Importa un estado para comenzar a conciliar ingresos, deuda y saldos."}</p></div></div></div><div className="timeline">{statements.length ? statements.map((statement) => <div className="timeline-row" key={statement.id}><span>{statement.period}</span><strong>{statement.transactionCount} mov.</strong><p>{statement.source} · {statement.fileName} · {statement.status === "ready" ? "revisado" : "pendiente de revisión"}</p></div>) : <EmptyState title="Sin historial financiero" body="Cuando importes tus PDFs, aquí quedará la línea de tiempo por banco y periodo." />}</div></section>;
}

function PageHeading({ title, body, action, onAction }: { title: string; body: string; action: string; onAction?: () => void }) {
  return <div className="page-heading"><div><h1>{title}</h1><p>{body}</p></div><button className="secondary-button" onClick={onAction}><Plus size={17} />{action}</button></div>;
}

function EmptyState({ title, body }: { title: string; body: string }) {
  return <div className="empty-state"><ListMagnifyingGlass size={32} /><h3>{title}</h3><p>{body}</p></div>;
}

function ImportDialog({ open, onClose, onSave }: { open: boolean; onClose: () => void; onSave: (commit: ImportCommit) => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [stage, setStage] = useState<"pick" | "processing" | "review" | "error">("pick");
  const [progress, setProgress] = useState(0);
  const [progressLabel, setProgressLabel] = useState("");
  const [result, setResult] = useState<ImportResult | null>(null);
  const [items, setItems] = useState<Transaction[]>([]);
  const [error, setError] = useState("");

  if (open && dialog.current && !dialog.current.open) dialog.current.showModal();
  if (!open && dialog.current?.open) dialog.current.close();

  async function handleFile(file?: File) {
    if (!file) return;
    if (file.type !== "application/pdf" && !file.name.toLowerCase().endsWith(".pdf")) { setError("Selecciona un archivo PDF válido."); setStage("error"); return; }
    setStage("processing"); setError("");
    try {
      const inspected = await inspectPdf(file, (value, label) => { setProgress(value); setProgressLabel(label); });
      setResult(inspected); setItems(inspected.transactions); setStage("review");
    } catch {
      setError("No pudimos leer este PDF. El archivo no se modificó; intenta con otra copia."); setStage("error");
    }
  }

  function resetAndClose() { setStage("pick"); setProgress(0); setResult(null); setItems([]); setError(""); onClose(); }
  function updateItem(id: string, key: "description" | "category", value: string) { setItems((current) => current.map((item) => item.id === id ? { ...item, [key]: value } : item)); }
  function updateAmount(id: string, value: string) { setItems((current) => current.map((item) => item.id === id ? { ...item, amount: Math.abs(Number(value) || 0) * (item.amount > 0 ? 1 : -1) } : item)); }
  function addManualItem() { setItems((current) => [...current, { id: `manual-${Date.now()}`, date: "Sin fecha", description: "Movimiento por revisar", account: result?.source ?? "Desconocido", category: "Sin categoría", amount: -1, flow: "expense", confidence: 1 }]); }

  const validItems = items.filter((item) => item.description.trim().length >= 3 && Number.isFinite(item.amount) && item.amount !== 0);
  return <dialog ref={dialog} className="import-dialog" onCancel={(event) => { event.preventDefault(); resetAndClose(); }}><div className="dialog-head"><div><span className="dialog-icon"><FilePdf size={21} /></span><div><h2>Importar estado de cuenta</h2><p>El archivo se procesa localmente y conserva su origen.</p></div></div><button className="icon-button" aria-label="Cerrar" onClick={resetAndClose}><X size={20} /></button></div>
    {stage === "pick" && <label className="drop-zone"><input type="file" accept="application/pdf" onChange={(event) => handleFile(event.target.files?.[0])} /><UploadSimple size={30} /><strong>Selecciona tu PDF mensual</strong><span>Se detectarán banco, periodo y movimientos. Los estados escaneados quedan pendientes de revisión.</span><span className="file-button">Elegir archivo</span></label>}
    {stage === "processing" && <div className="processing-state"><CircleNotch size={34} className="spinner" /><h3>{progressLabel}</h3><p>No cierres esta ventana mientras organizamos los movimientos.</p><div className="progress-track"><span style={{ width: `${progress}%` }} /></div><small>{progress}%</small></div>}
    {stage === "error" && <div className="error-state"><Warning size={34} /><h3>No pudimos completar la importación</h3><p>{error}</p><button className="secondary-button" onClick={() => setStage("pick")}>Intentar de nuevo</button></div>}
    {stage === "review" && result && <div className="review-state"><div className="review-summary"><div><span>Banco detectado</span><strong>{result.source}</strong></div><div><span>Periodo</span><strong>{result.period}</strong></div><div><span>Método</span><strong>{result.mode === "text" ? "Lectura directa" : "Revisión visual"}</strong></div><div><span>Movimientos</span><strong>{validItems.length}</strong></div></div>{result.mode === "ocr" && <div className="ocr-callout"><Warning size={21} /><div><strong>Este PDF es una imagen escaneada</strong><p>Guardaremos el estado con su banco y periodo, pero tendrás que capturar o corregir movimientos manualmente.</p><button className="secondary-button" onClick={addManualItem}><Plus size={16} />Agregar movimiento</button></div></div>}{items.length ? <div className="review-table">{items.slice(0, 40).map((item) => <div className="review-row" key={item.id}><div><input aria-label="Descripción" value={item.description} onChange={(event) => updateItem(item.id, "description", event.target.value)} /><small>{item.date} · confianza {Math.round((item.confidence ?? 0) * 100)}%</small></div><select aria-label="Categoría" value={item.category} onChange={(event) => updateItem(item.id, "category", event.target.value)}>{["Ingresos", "Transferencia", ...categories].map((category) => <option key={category}>{category}</option>)}</select><input className={item.amount > 0 ? "review-amount positive" : "review-amount"} aria-label="Importe" type="number" step="0.01" value={Math.abs(item.amount)} onChange={(event) => updateAmount(item.id, event.target.value)} /></div>)}</div> : <EmptyState title="Estado listo para guardar" body="No detectamos movimientos automáticos, pero sí conservaremos banco, periodo y archivo para que lo completes." />}
      <div className="dialog-actions"><button className="text-button" onClick={() => setStage("pick")}>Elegir otro archivo</button><button className="primary-button" onClick={() => onSave({ source: result.source, period: result.period, fileName: result.fileName, mode: result.mode, transactions: validItems })}><Check size={18} />{validItems.length ? `Guardar estado y ${validItems.length} movimientos` : "Guardar estado para revisar"}</button></div></div>}
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
  return user ? <AppShell user={user} onSignOut={() => setUser("")} onDeleteAccount={handleDeleteAccount} /> : <AuthGate onEnter={setUser} />;
}
