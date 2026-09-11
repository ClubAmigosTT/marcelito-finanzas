"""Read-only corpus check. Validates source arithmetic, not Swift execution.

Usage: python scripts/audit-rappi-pdfs.py <private PDF> [<private PDF> ...]
Only aggregates are printed; no account identifiers or merchant data.
"""
import re
import sys
import unicodedata
from decimal import Decimal

from pypdf import PdfReader


def fold(value):
    return "".join(c for c in unicodedata.normalize("NFD", value.lower()) if not unicodedata.combining(c))


def audit(path):
    reader = PdfReader(path)
    text = fold("\n".join(page.extract_text() for page in reader.pages))
    header = fold(reader.pages[0].extract_text())

    def money(label):
        match = re.search(label + r"\s*\d{0,2}\s*[:=+\-]?\s*\$\s*([\d,]+\.\d{2})", header)
        if not match:
            raise ValueError("Missing independent summary field: " + label)
        return Decimal(match[1].replace(",", ""))

    table = False
    pending = ""
    amounts = []

    def flush():
        nonlocal pending
        if pending:
            match = re.search(r"([+-]\s*\$\s*[\d,]+\.\d{2})", pending)
            if not match:
                raise ValueError("Incomplete dated row")
            amounts.append(Decimal(re.sub(r"[^\d.+-]", "", match[1])))
        pending = ""

    for line in text.splitlines():
        line = line.strip()
        if "cargos, abonos y compras regulares" in line:
            flush()
            table = True
            continue
        if line.startswith(("total de cargos", "cargos no reconocidos", "atencion de quejas", "notas aclaratorias", "compras y cargos diferidos")):
            flush()
            table = False
        if not table:
            continue
        if re.match(r"^\d{4}-\d{2}-\d{2}\s+\d{4}-\d{2}-\d{2}", line):
            flush()
            pending = line
        elif pending:
            pending += " " + line
    flush()
    charges = sum((a for a in amounts if a > 0), Decimal(0))
    credits = -sum((a for a in amounts if a < 0), Decimal(0))
    opening = money("adeudo del periodo anterior")
    closing = money("saldo deudor total")
    assert charges == money(r"cargos regulares \(no a meses\)"), "Charges mismatch"
    assert credits == money("pagos y abonos"), "Credits mismatch"
    assert opening + charges - credits == closing, "Closing balance mismatch"
    period = re.search(r"periodo (\d{2}-[a-z]{3}-\d{4} al \d{2}-[a-z]{3}-\d{4})", header)[1]
    print(f"{period}: rows={len(amounts)} charges={charges} credits={credits} closing={closing} PASS")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("Provide private PDF paths; originals are never copied.")
    for argument in sys.argv[1:]:
        audit(argument)
