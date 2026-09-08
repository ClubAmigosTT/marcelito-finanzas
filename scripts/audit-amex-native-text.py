"""Read-only independent PDF text check. Not an iOS/PDFKit certification.

Run against a private directory; emits totals only, no account/merchant data.
No OCR, network access or PDF mutation. Requires pypdf.
"""
import re
import sys
from decimal import Decimal
from pathlib import Path
from pypdf import PdfReader

DATE = re.compile(r"^\d{1,2}\s+de\s*(?:Enero|Febrero|Marzo|Abril|Mayo|Junio|Julio|Agosto|Septiembre|Octubre|Noviembre|Diciembre)\b", re.I)
MONEY = re.compile(r"(?<![\w.,])(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2}(?![\d.,])")
FX = re.compile(r"(?:peso\s+colombiano|d[oó�]lar\s+U\.S\.A\.|euro)\s+[\d,.]+\s+TC\s*:\s*\d+[.,]\d+", re.I)


def audit(path):
    section, pending = 0, ""
    rows, errors, controls = [], [], {}

    def flush():
        nonlocal pending
        if not pending:
            return
        original, pending = pending, ""
        body = DATE.sub("", original)
        body = re.sub(r"\bRFC\s*[:#]?\s*[A-Z0-9]+\b|/REF[^\s]+", " ", body, flags=re.I)
        body = FX.sub(" ", body)
        body = re.sub(r"\bCARGO\s+\d+\s+DE\s*\d+\b", " ", body, flags=re.I)
        amounts = [m.group() for m in MONEY.finditer(body) if re.fullmatch(r"\s*(?:CR)?\s*", body[m.end():], re.I)]
        if len(amounts) != 1:
            errors.append((len(rows), len(amounts)))
            return
        amount = Decimal(amounts[0].replace(",", ""))
        credit = bool(re.search(r"\bCR\b", body))
        kind = "payment" if "GRACIAS POR SU PAGO" in body else "credit" if credit else "msi" if section == 3 else "purchase"
        rows.append((section, kind, amount))

    for page in PdfReader(path).pages:
        active = False
        for line in (page.extract_text() or "").splitlines():
            line = line.strip()
            lower = line.lower()
            if "nuevas transacciones:" in lower:
                controls["purchase"] = Decimal(MONEY.findall(line)[-1].replace(",", ""))
            if "fecha y detalle de las operaciones" in lower:
                flush(); active = True; section = section or 1; continue
            if "total de las transacciones en" in lower:
                flush(); controls["domestic"] = Decimal(MONEY.findall(line)[-1].replace(",", "")); section = 2; continue
            if "total de transacciones en moneda extranjera" in lower:
                flush(); controls["foreign"] = Decimal(MONEY.findall(line)[-1].replace(",", "")); section = 0; continue
            if "transacciones de meses sin intereses" in lower:
                flush(); section = 3; active = True; continue
            if "total de meses sin intereses" in lower:
                flush(); controls["msi"] = Decimal(MONEY.findall(line)[-1].replace(",", "")); section = 0; continue
            if "resumen de meses sin intereses" in lower or "consolidado de compras" in lower:
                flush(); section = 0; continue
            if lower.startswith("estado de cuenta") or "este no es un documento" in lower or lower.startswith("paga desde los canales"):
                flush(); active = False; continue
            if not active or not section:
                continue
            if DATE.match(line):
                flush(); pending = line
            elif pending:
                pending += " " + line
        flush()
    sums = {k: sum((a for _, kind, a in rows if kind == k), Decimal(0)) for k in ["purchase", "payment", "credit", "msi"]}
    domestic = sum(((-a if k == "credit" else a) for s, k, a in rows if s == 1 and k in ["purchase", "credit"]), Decimal(0))
    foreign = sum((a for s, k, a in rows if s == 2 and k == "purchase"), Decimal(0))
    valid = not errors and sums["purchase"] == controls.get("purchase") and abs(domestic) == abs(controls.get("domestic", Decimal("NaN"))) and foreign == controls.get("foreign") and sums["msi"] == controls.get("msi")
    print(path.name, "rows", len(rows), "rejected", errors, "totals", sums, "domestic", domestic, "foreign", foreign, "controls", controls, "PASS" if valid else "FAIL")
    return valid


if __name__ == "__main__":
    files = sorted(Path(sys.argv[1]).glob("*.pdf"))
    results = [audit(path) for path in files]
    sys.exit(0 if results and all(results) else 1)
