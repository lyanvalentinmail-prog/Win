#!/usr/bin/env python3
"""Comprueba los enlaces relativos de todos los .md del repositorio.

Un README roto es el primer bug de un proyecto de documentacion: si el enlace no
existe, el lector no llega al requisito, al limite o al script que le interesa.
No valida enlaces externos (la CI sin red no puede y las URLs cambian); para eso
esta `--externos`, que hace una peticion HEAD con timeout corto.

Uso: python scripts/validate/check_links.py [--externos]
Salida: lineas "ARCHIVO:LINEA: problema" y un resumen. Exit 1 si hay rotos internos.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import urllib.error
import urllib.request

ENLACE = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
ANCHLA = re.compile(r"[#][^)]*$")
EXTERNO = re.compile(r"^(https?://|mailto:)")
IGNORAR = (".git/", "node_modules/")


def markdown_files(raiz: str):
    for base, dirs, ficheros in os.walk(raiz):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d != "node_modules"]
        for f in ficheros:
            if f.endswith(".md"):
                yield os.path.join(base, f)


def principal(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--raiz", default=".")
    ap.add_argument("--externos", action="store_true", help="comprobar tambien las URLs http(s)")
    args = ap.parse_args(argv)

    rotos: list[str] = []
    externos: list[str] = []
    total = 0
    for md in markdown_files(args.raiz):
        if any(x in md for x in IGNORAR):
            continue
        texto = open(md, encoding="utf-8").read()
        for num, linea in enumerate(texto.splitlines(), 1):
            for destino in ENLACE.findall(linea):
                total += 1
                if EXTERNO.match(destino):
                    if args.externos:
                        externos.append(f"{md}:{num}: {destino}")
                    continue
                if destino.startswith(("`", "#")):
                    continue
                ruta = ANCHLA.sub("", destino)
                if not ruta:
                    continue
                objetivo = os.path.normpath(os.path.join(os.path.dirname(md), ruta))
                if not os.path.exists(objetivo):
                    rotos.append(f"{md}:{num}: enlace roto -> {destino}")

    for r in rotos:
        print(f"[ERROR] {r}")
    if args.externos and externos:
        for item in externos:
            url = item.split(": ", 1)[1]
            peticion = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "win-gaming-vm-links/1.0"})
            try:
                with urllib.request.urlopen(peticion, timeout=12) as respuesta:
                    if respuesta.status >= 400:
                        print(f"[WARN ] externo {respuesta.status} en {item}")
            except (urllib.error.URLError, TimeoutError) as exc:
                print(f"[WARN ] externo no comprobable ({type(exc).__name__}) en {item}")

    print(f"\n{total} enlaces comprobados, {len(rotos)} rotos"
          + (f", {len(externos)} externos" if args.externos else "") + ".")
    return 1 if rotos else 0


if __name__ == "__main__":
    sys.exit(principal())
