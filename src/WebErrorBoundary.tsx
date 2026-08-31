import { Component, type ErrorInfo, type ReactNode } from "react";
import { Warning } from "@phosphor-icons/react";

const diagnosticsKey = "marcelito-web-errors.v1";
const maxStoredErrors = 20;

type WebErrorBoundaryProps = { children: ReactNode };
type WebErrorBoundaryState = { error: Error | null; eventId?: string };
export type WebErrorDiagnostic = {
  eventId: string;
  recordedAt: string;
  message: string;
  stack: string;
  componentStack: string;
  path: string;
  userAgent: string;
};

export function readWebErrorDiagnostics(): WebErrorDiagnostic[] {
  try {
    const value = JSON.parse(localStorage.getItem(diagnosticsKey) ?? "[]");
    return Array.isArray(value) ? value as WebErrorDiagnostic[] : [];
  } catch {
    return [];
  }
}

export function clearWebErrorDiagnostics() {
  try {
    localStorage.removeItem(diagnosticsKey);
  } catch {
    // Storage errors should never prevent the audit screen from rendering.
  }
}

function recordWebError(error: Error, componentStack = "") {
  const eventId = `web-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;
  const entry = {
    eventId,
    recordedAt: new Date().toISOString(),
    message: error.message.slice(0, 500),
    stack: (error.stack ?? "").slice(0, 2000),
    componentStack: componentStack.slice(0, 2000),
    path: window.location.pathname,
    userAgent: navigator.userAgent.slice(0, 240),
  };
  try {
    const previous = JSON.parse(localStorage.getItem(diagnosticsKey) ?? "[]");
    const entries = Array.isArray(previous) ? previous : [];
    localStorage.setItem(diagnosticsKey, JSON.stringify([...entries, entry].slice(-maxStoredErrors)));
  } catch {
    // A full/private storage area must not hide the original crash screen.
  }
  return eventId;
}

/**
 * Keeps a render crash recoverable and locally diagnosable. It deliberately
 * stores no PDF text, descriptions, amounts or account names.
 */
export default class WebErrorBoundary extends Component<WebErrorBoundaryProps, WebErrorBoundaryState> {
  state: WebErrorBoundaryState = { error: null };

  private readonly handleWindowError = (event: ErrorEvent) => {
    const error = event.error instanceof Error
      ? event.error
      : new Error(event.message || "Error de ejecución no controlado");
    recordWebError(error);
  };

  private readonly handleUnhandledRejection = (event: PromiseRejectionEvent) => {
    const error = event.reason instanceof Error
      ? event.reason
      : new Error(typeof event.reason === "string" ? event.reason : "Promesa rechazada sin detalle");
    recordWebError(error);
  };

  componentDidMount() {
    window.addEventListener("error", this.handleWindowError);
    window.addEventListener("unhandledrejection", this.handleUnhandledRejection);
  }

  componentWillUnmount() {
    window.removeEventListener("error", this.handleWindowError);
    window.removeEventListener("unhandledrejection", this.handleUnhandledRejection);
  }

  static getDerivedStateFromError(error: Error): WebErrorBoundaryState {
    return { error };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    const eventId = recordWebError(error, errorInfo.componentStack ?? "");
    this.setState({ eventId });
    console.error(`[Marcelito ${eventId}] Error de interfaz`, error);
  }

  render() {
    if (!this.state.error) return this.props.children;
    return (
      <main className="runtime-error-shell" role="alert">
        <section className="runtime-error-card">
          <Warning size={36} aria-hidden="true" />
          <p className="auth-kicker">Marcelito sigue protegiendo tus datos</p>
          <h1>La pantalla encontró un problema</h1>
          <p>El fallo quedó registrado solo en este dispositivo. Recarga para continuar; tus estados de cuenta no se envían.</p>
          {this.state.eventId && <small>Referencia: {this.state.eventId}</small>}
          <button className="primary-button" type="button" onClick={() => window.location.reload()}>Recargar aplicación</button>
        </section>
      </main>
    );
  }
}
