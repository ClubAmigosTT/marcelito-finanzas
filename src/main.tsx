import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";
import App from "./App";
import WebErrorBoundary from "./WebErrorBoundary";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <WebErrorBoundary>
      <App />
    </WebErrorBoundary>
  </StrictMode>,
);

