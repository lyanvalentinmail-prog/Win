#!/usr/bin/env python3
"""Extrae el bloque de CHANGELOG.md correspondiente al tag y escribe release-notes.md.

Se niega a publicar si el changelog no documenta esa version: un release sin notas, en
un proyecto que trata limites y supuestos de proveedor, es una invitacion a malinterpretar
lo que hace el codigo.

Uso: python scripts/validate/release_notes.py
"""
from __future__ import annotations

import pathlib
import re
import sys

AVISO = (
    "**Que NO incluye este paquete**\n\n"
    "- Ni instaladores, ni ISO de Windows, ni drivers: todo se descarga de su fuente oficial "
    "en el momento de la instalacion, verificando host, firma y (cuando esta declarado) SHA-256.\n"
    "- Ninguna garantia de rendimiento en el juego: depende del SKU, del driver de GPU, de la "
    "edicion de Windows y de tu red. Si un limite aplica, el informe de preparacion lo dice.\n"
    "- Licencias de Windows y de los juegos: son tuyas, del proveedor de nube y de los editores.\n\n"
    "Antes de desplegar: `docs/README.md` y `docs/10-requisitos.md`.\n"
)


def principal() -> int:
    raiz = pathlib.Path(".")
    version = (raiz / "VERSION").read_text(encoding="utf-8").strip()
    tag = f"v{version}"
    texto = (raiz / "CHANGELOG.md").read_text(encoding="utf-8")

    patron = re.compile(rf"^##\s*\[?{re.escape(version)}\]?.*?(?=^##\s*\[)", re.S | re.M)
    m = patron.search(texto)
    if not m:
        print(f"[ERROR] CHANGELOG.md no tiene una seccion '## [{version}]'; "
              "anadela antes de publicar el tag", file=sys.stderr)
        return 1
    cuerpo = m.group(0).rstrip().rstrip("-").rstrip()

    salida = raiz / "release-notes.md"
    salida.write_text(
        f"Win Gaming VM {tag}\n\n{cuerpo}\n\n---\n\n{AVISO}\n", encoding="utf-8"
    )
    print(f"[ok] {salida} generado desde CHANGELOG.md ({len(cuerpo)} caracteres de notas)")
    return 0


if __name__ == "__main__":
    sys.exit(principal())
