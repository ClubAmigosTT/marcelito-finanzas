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
import { categories, transactions as initialTransactions } from "./data";
import { inspectPdf } from "./pdfImport";
import type { ImportResult, Section, Transaction } from "./types";

const money = new Intl.NumberFormat("es-MX", { style: "currency", currency: "MXN", maximumFractionDigits: 0 });
const moneyPrecise = new Intl.NumberFormat("es-MX", { style: "currency", currency: "MXN", minimumFractionDigits: 2 });
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
            <p>{mode === "create" ? "Tus datos se guardan localmente en esta primera versión." : "Entra a tu panorama financiero personal."}</p>
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
  const [transactions, setTransactions] = useState<Transaction[]>(() => {
    try {
      const stored = JSON.parse(localStorage.getItem("marcelito-transactions") ?? "null") as Transaction[] | null;
      return stored?.length ? stored : initialTransactions;
    } catch {
      return initialTransactions;
    }
  });
  const [importOpen, setImportOpen] = useState(false);
  const reduceMotion = useReducedMotion();

  useEffect(() => {
    localStorage.setItem("marcelito-transactions", JSON.stringify(transactions));
  }, [transactions]);

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
          <div><span className="context-title">{section}</span><span className="sync-status"><CheckCircle size={15} weight="fill" /> Datos al 27 de agosto</span></div>
          <div className="top-actions">
            <button className="icon-button mobile-profile-action" aria-label="Eliminar cuenta" onClick={onDeleteAccount}><Trash size={20} /></button>
            <button className="icon-button" aria-label="Notificaciones"><Bell size={20} /></button>
            <button className="primary-button" onClick={() => setImportOpen(true)}><UploadSimple size={18} />Importar estado</button>
          </div>
        </header>
        <AnimatePresence mode="wait">
          <motion.div key={section} className="page" initial={reduceMotion ? false : { opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={reduceMotion ? undefined : { opacity: 0, y: -4 }} transition={{ duration: 0.2, ease: [0.16, 1, 0.3, 1] }}>
            {section === "Inicio" && <Home transactions={transactions} />}
            {section === "Movimientos" && <Movements transactions={transactions} setTransactions={setTransactions} />}
            {section === "Gastos" && <Expenses />}
            {section === "Cuentas" && <Accounts />}
            {section === "Patrimonio" && <NetWorth />}
          </motion.div>
        </AnimatePresence>
      </main>
      <nav className="mobile-nav" aria-label="Navegación principal móvil">
        {navItems.map(({ label, icon: Icon }) => <button key={label} className={section === label ? "active" : ""} onClick={() => setSection(label)}><Icon size={21} weight={section === label ? "fill" : "regular"} /><span>{label}</span></button>)}
      </nav>
      <ImportDialog open={importOpen} onClose={() => setImportOpen(false)} onSave={(items) => {
        setTransactions((current) => {
          const fresh = items.filter((item) => !current.some((saved) => saved.date === item.date && saved.description === item.description && saved.amount === item.amount && saved.account === item.account));
          return [...fresh, ...current];
        });
        setImportOpen(false);
      }} />
    </div>
  );
}

function Home({ transactions }: { transactions: Transaction[] }) {
  const spent = Math.abs(transactions.filter((item) => item.flow === "expense").reduce((sum, item) => sum + item.amount, 0));
  return (
    <>
      <section className="home-heading">
        <div><h1>Tu dinero, explicado.</h1><p>Agosto cerró con más efectivo, pero los viajes empujaron el gasto por encima de tu ritmo habitual.</p></div>
        <button className="month-button">Agosto 2026 <ArrowDown size={16} /></button>
      </section>
      <section className="hero-balance">
        <div className="balance-main">
          <span>Patrimonio líquido</span>
          <strong>{money.format(84769)}</strong>
          <p><span className="positive">+{money.format(6840)}</span> desde julio</p>
        </div>
        <div className="balance-story">
          <Sparkle size={24} weight="fill" />
          <div><strong>Vas en buena dirección</strong><p>El ahorro creció 8.8%. Si mantienes el gasto variable debajo de $9,400, septiembre cerrará positivo.</p></div>
          <button aria-label="Ver explicación"><ArrowRight size={19} /></button>
        </div>
      </section>
      <section className="live-metrics" aria-label="Indicadores del mes">
        <Metric label="Efectivo disponible" value={money.format(107920)} delta="+$11,340" tone="income" icon={Wallet} />
        <Metric label="Deuda total" value={money.format(23151)} delta="-$3,210" tone="debt" icon={CreditCard} />
        <Metric label="Gasto del mes" value={money.format(spent)} delta="18% en viajes" tone="expense" icon={Receipt} />
      </section>
      <section className="money-section">
        <div className="section-heading"><div><h2>Así se movió tu dinero</h2><p>Transferencias y pagos se conectan para no contar el mismo gasto dos veces.</p></div><div className="legend"><span className="income-text">Ingreso</span><span className="transfer-text">Transferencia</span><span className="expense-text">Gasto</span><span className="debt-text">Deuda</span></div></div>
        <div className="money-map">
          <FlowNode icon={Wallet} title="Ingresos" value="$48,200" tone="income" detail="Nómina y abonos" />
          <FlowConnector tone="income" value="$48,200" />
          <div className="account-nodes">
            <FlowNode icon={Bank} title="Santander" value="$27,654" tone="transfer" detail="Cuenta principal" />
            <FlowNode icon={Bank} title="BBVA" value="$80,266" tone="transfer" detail="Ahorro y reservas" />
          </div>
          <FlowConnector tone="transfer" value="$19,405" />
          <FlowNode icon={CreditCard} title="American Express" value="$23,151" tone="debt" detail="Saldo al corte" />
          <FlowConnector tone="expense" value="$10,303" />
          <FlowNode icon={Receipt} title="Gasto real" value="$10,303" tone="expense" detail="Después de excluir pagos" />
        </div>
      </section>
      <section className="decision-grid">
        <div className="decision-list">
          <div className="section-heading simple"><div><h2>Decisiones para septiembre</h2><p>Basadas en tus movimientos ya conciliados.</p></div></div>
          <Insight icon={Lightbulb} title="Reserva $6,500 antes del día 12" body="Cubre el pago esperado de Amex sin tocar tu fondo de viaje." action="Crear apartado" />
          <Insight icon={ListMagnifyingGlass} title="Revisa 4 movimientos sin categoría" body="Representan $1,240 y pueden cambiar tu lectura de gasto variable." action="Revisar ahora" />
        </div>
        <div className="spending-shape">
          <div className="shape-head"><div><h3>En qué se fue</h3><span>$10,303 este mes</span></div><button aria-label="Ver gastos"><ArrowRight size={18} /></button></div>
          <div className="shape-grid"><div className="shape travel"><strong>Viajes</strong><span>$6,270</span></div><div className="shape food"><strong>Alimentos</strong><span>$1,843</span></div><div className="shape dining"><strong>Comidas</strong><span>$920</span></div><div className="shape services"><strong>Servicios</strong><span>$648</span></div><div className="shape other"><strong>Otros</strong><span>$622</span></div></div>
        </div>
      </section>
    </>
  );
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

function Movements({ transactions, setTransactions }: { transactions: Transaction[]; setTransactions: React.Dispatch<React.SetStateAction<Transaction[]>> }) {
  const [query, setQuery] = useState("");
  const filtered = transactions.filter((item) => `${item.description} ${item.category} ${item.account}`.toLowerCase().includes(query.toLowerCase()));
  function updateCategory(id: string, category: string) { setTransactions((items) => items.map((item) => item.id === id ? { ...item, category } : item)); }
  return <section><PageHeading title="Movimientos" body="Busca, corrige y conecta cada movimiento con su historia real." action="Agregar movimiento" /><div className="filter-row"><div className="search-box"><ListMagnifyingGlass size={19} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Buscar comercio, cuenta o categoría" /></div><button className="secondary-button">Todos los flujos <ArrowDown size={16} /></button></div><div className="movement-list">{filtered.map((item) => <div className="movement-row" key={item.id}><span className={`movement-glyph glyph-${item.flow}`}>{item.flow === "transfer" ? <ArrowsLeftRight size={18} /> : item.flow === "income" ? <ArrowDown size={18} /> : <Receipt size={18} />}</span><div className="movement-name"><strong>{item.description}</strong><span>{item.date} · {item.account}</span></div><select aria-label={`Categoría de ${item.description}`} value={item.category} onChange={(event) => updateCategory(item.id, event.target.value)}>{["Ingresos", "Transferencia", ...categories].map((category) => <option key={category}>{category}</option>)}</select><strong className={item.amount > 0 ? "amount positive" : "amount"}>{moneyPrecise.format(item.amount)}</strong><button className="row-action" aria-label={`Editar ${item.description}`}><PencilSimple size={17} /></button></div>)}{filtered.length === 0 && <EmptyState title="No encontramos movimientos" body="Prueba otra búsqueda o importa un nuevo estado de cuenta." />}</div></section>;
}

function Expenses() {
  return <section><PageHeading title="Gastos" body="El gasto real excluye traspasos y pagos de tarjeta para evitar duplicados." action="Crear presupuesto" /><div className="expense-layout"><div className="expense-map"><div className="shape-grid large"><div className="shape travel"><strong>Viajes</strong><span>$6,270</span><small>61% del gasto</small></div><div className="shape food"><strong>Alimentos</strong><span>$1,843</span><small>18%</small></div><div className="shape dining"><strong>Comidas</strong><span>$920</span></div><div className="shape services"><strong>Servicios</strong><span>$648</span></div><div className="shape other"><strong>Otros</strong><span>$622</span></div></div></div><aside className="story-card"><span className="story-month">Viaje · Agosto</span><h2>Fin de semana en Mérida</h2><p>Este viaje explica 61% del gasto del mes. Hospedaje y transporte ya están pagados; quedan $1,800 reservados para consumo.</p><div className="story-total"><span>Total identificado</span><strong>$6,270</strong></div><button className="secondary-button">Abrir historia <ArrowRight size={17} /></button></aside></div></section>;
}

function Accounts() {
  const accounts = [{ name: "Santander", type: "Cuenta principal", value: "$27,654", icon: Bank, tone: "transfer" }, { name: "BBVA", type: "Ahorro y reservas", value: "$80,266", icon: Bank, tone: "income" }, { name: "American Express", type: "Crédito · corte 27 ago", value: "$23,151", icon: CreditCard, tone: "debt" }];
  return <section><PageHeading title="Cuentas" body="Saldos, próximos cortes y la función que cumple cada cuenta." action="Agregar cuenta" /><div className="accounts-layout"><div className="account-list">{accounts.map(({ name, type, value, icon: Icon, tone }) => <article className="account-row" key={name}><span className={`account-icon node-${tone}`}><Icon size={22} /></span><div><h3>{name}</h3><p>{type}</p></div><strong>{value}</strong><button aria-label={`Abrir ${name}`}><ArrowRight size={18} /></button></article>)}</div><aside className="account-rule"><Fingerprint size={26} /><h3>Una cuenta, una función</h3><p>BBVA concentra ahorro; Santander opera el día a día; Amex agrupa compras. Marcelito vigila que una transferencia no se convierta en gasto duplicado.</p></aside></div></section>;
}

function NetWorth() {
  return <section><PageHeading title="Patrimonio" body="La evolución de lo que tienes menos lo que debes, con cada cambio explicado." action="Agregar activo" /><div className="networth-hero"><div><span>Patrimonio neto estimado</span><strong>$84,769</strong><p><span className="positive">+$18,430</span> en los últimos 6 meses</p></div><div className="trend-chart" aria-label="Tendencia ascendente de patrimonio de marzo a agosto"><div style={{ height: "38%" }} /><div style={{ height: "46%" }} /><div style={{ height: "54%" }} /><div style={{ height: "61%" }} /><div style={{ height: "72%" }} /><div style={{ height: "84%" }} /></div></div><div className="timeline"><div className="timeline-row"><span>Agosto</span><strong>$84,769</strong><p>El ahorro y un menor saldo de Amex sumaron $6,840.</p></div><div className="timeline-row"><span>Julio</span><strong>$77,929</strong><p>El viaje redujo el avance mensual, sin usar el fondo de emergencia.</p></div><div className="timeline-row"><span>Junio</span><strong>$75,310</strong><p>Primer mes con las tres cuentas conciliadas.</p></div></div></section>;
}

function PageHeading({ title, body, action }: { title: string; body: string; action: string }) {
  return <div className="page-heading"><div><h1>{title}</h1><p>{body}</p></div><button className="secondary-button"><Plus size={17} />{action}</button></div>;
}

function EmptyState({ title, body }: { title: string; body: string }) {
  return <div className="empty-state"><ListMagnifyingGlass size={32} /><h3>{title}</h3><p>{body}</p></div>;
}

function ImportDialog({ open, onClose, onSave }: { open: boolean; onClose: () => void; onSave: (items: Transaction[]) => void }) {
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
    } catch { setError("No pudimos leer este PDF. El archivo no se modificó; intenta con otra copia."); setStage("error"); }
  }

  function resetAndClose() { setStage("pick"); setProgress(0); setResult(null); setItems([]); setError(""); onClose(); }
  function updateItem(id: string, key: "description" | "category", value: string) { setItems((current) => current.map((item) => item.id === id ? { ...item, [key]: value } : item)); }
  function updateAmount(id: string, value: string) { setItems((current) => current.map((item) => item.id === id ? { ...item, amount: Math.abs(Number(value) || 0) * (item.amount > 0 ? 1 : -1) } : item)); }
  function addManualItem() {
    setItems((current) => [...current, { id: `manual-${Date.now()}`, date: "Sin fecha", description: "Movimiento por revisar", account: result?.source ?? "Desconocido", category: "Sin categoría", amount: -0, flow: "expense", confidence: 1 }]);
  }

  return <dialog ref={dialog} className="import-dialog" onCancel={(event) => { event.preventDefault(); resetAndClose(); }}><div className="dialog-head"><div><span className="dialog-icon"><FilePdf size={21} /></span><div><h2>Importar estado de cuenta</h2><p>El archivo se procesa localmente.</p></div></div><button className="icon-button" aria-label="Cerrar" onClick={resetAndClose}><X size={20} /></button></div>
    {stage === "pick" && <label className="drop-zone"><input type="file" accept="application/pdf" onChange={(event) => handleFile(event.target.files?.[0])} /><UploadSimple size={30} /><strong>Selecciona tu PDF mensual</strong><span>Amex se lee directamente. Santander puede requerir revisión con OCR.</span><span className="file-button">Elegir archivo</span></label>}
    {stage === "processing" && <div className="processing-state"><CircleNotch size={34} className="spinner" /><h3>{progressLabel}</h3><p>No cierres esta ventana mientras organizamos los movimientos.</p><div className="progress-track"><span style={{ width: `${progress}%` }} /></div><small>{progress}%</small></div>}
    {stage === "error" && <div className="error-state"><Warning size={34} /><h3>No pudimos completar la importación</h3><p>{error}</p><button className="secondary-button" onClick={() => setStage("pick")}>Intentar de nuevo</button></div>}
    {stage === "review" && result && <div className="review-state"><div className="review-summary"><div><span>Origen detectado</span><strong>{result.source}</strong></div><div><span>Método</span><strong>{result.mode === "text" ? "Lectura directa" : "OCR requerido"}</strong></div><div><span>Movimientos</span><strong>{items.length}</strong></div></div>{result.mode === "ocr" && <div className="ocr-callout"><Warning size={21} /><div><strong>Este PDF es una imagen escaneada</strong><p>La lectura visual completa se conectará en la siguiente etapa. Puedes capturar movimientos manualmente sin guardar el documento.</p><button className="secondary-button" onClick={addManualItem}><Plus size={16} />Agregar movimiento</button></div></div>}{items.length ? <div className="review-table"><div className="review-row table-head"><span>Movimiento</span><span>Categoría</span><span>Importe</span></div>{items.slice(0, 12).map((item) => <div className="review-row" key={item.id}><div><input aria-label="Descripción" value={item.description} onChange={(event) => updateItem(item.id, "description", event.target.value)} /><small>{item.date} · confianza {Math.round((item.confidence ?? 0) * 100)}%</small></div><select value={item.category} onChange={(event) => updateItem(item.id, "category", event.target.value)}>{["Ingresos", "Transferencia", ...categories].map((category) => <option key={category}>{category}</option>)}</select><input className={item.amount > 0 ? "review-amount positive" : "review-amount"} aria-label="Importe" type="number" step="0.01" value={Math.abs(item.amount)} onChange={(event) => updateAmount(item.id, event.target.value)} /></div>)}</div> : result.mode !== "ocr" ? <EmptyState title="No detectamos movimientos" body="El PDF se leyó, pero necesita revisión manual." /> : null}
      <div className="dialog-actions"><button className="text-button" onClick={() => setStage("pick")}>Elegir otro archivo</button><button className="primary-button" disabled={!items.length} onClick={() => onSave(items)}><Check size={18} />Guardar {items.length || ""} movimientos</button></div></div>}
  </dialog>;
}

export default function App() {
  const stored = useMemo(() => { try { return JSON.parse(localStorage.getItem("marcelito-profile") ?? "null") as { name: string } | null; } catch { return null; } }, []);
  const [user, setUser] = useState(stored?.name ?? "");
  function handleDeleteAccount() {
    if (!window.confirm("Se eliminarán tu cuenta local y todos los movimientos guardados en este dispositivo. Esta acción no se puede deshacer.")) return;
    deleteLocalAccount();
    setUser("");
  }
  return user ? <AppShell user={user} onSignOut={() => setUser("")} onDeleteAccount={handleDeleteAccount} /> : <AuthGate onEnter={setUser} />;
}
