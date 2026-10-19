#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Validador del repositorio Win Gaming VM.

Comprueba, sin tocar ninguna nube y sin ejecutar PowerShell:

  config      — config/vm.json (o vm.example.json) contra config/vm.schema.json + limites
                reales del proveedor (config/provider-limits.json) + reglas cruzadas.
  apps        — apps/catalog.json + apps/selections/*.json: coherencia, fuentes oficiales,
                hashes, ediciones compatibles.
  gaming      — gaming/profiles/*.json y gaming/touch/layouts/*.json contra sus schemas,
                con reglas de honestidad (juego 'restringida' no puede tener layout tactil).
  powershell  — Analisis lexico de scripts/win/*.ps1 y del modulo: balance de llaves,
                operadores incompatibles con Windows PowerShell 5.1, funciones inexistentes
                del modulo, rutas de scripts invocados, y ausencia de secretos.
  estructura  — el arbol que promete el README existe y los JSON tienen las claves minimas.
  secretos    — busqueda de credenciales/tokens/URLs con usuario:pass en todo el repo.

Salida: lineas [OK]/[WARN]/[ERROR] y un resumen. Exit code: 0 sin errores, 1 con errores.

Uso:
  python3 scripts/validate/validate.py                 # todo lo que se puede validar offline
  python3 scripts/validate/validate.py --config config/vm.json
  python3 scripts/validate/validate.py --online        # ademas: verifica ids de winget en
                                                       # microsoft/winget-pkgs via API de GitHub
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

try:
    from jsonschema import Draft202012Validator
except Exception:  # pragma: no cover - dependencia opcional
    Draft202012Validator = None

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ERROR = "ERROR"
WARN = "WARN"
OK = "OK"


# --------------------------------------------------------------------------- utils
class Results:
    def __init__(self, verbose: bool = False):
        self.items: list[tuple[str, str, str]] = []
        self.verbose = verbose

    def add(self, nivel: str, area: str, msg: str) -> None:
        self.items.append((nivel, area, msg))

    def ok(self, area, msg):
        self.add(OK, area, msg)

    def warn(self, area, msg):
        self.add(WARN, area, msg)

    def error(self, area, msg):
        self.add(ERROR, area, msg)

    @property
    def errores(self):
        return [i for i in self.items if i[0] == ERROR]

    @property
    def avisos(self):
        return [i for i in self.items if i[0] == WARN]

    def report(self) -> None:
        for nivel, area, msg in self.items:
            if nivel == OK and not self.verbose:
                continue
            print(f"[{nivel:5}] {area:12} {msg}")


def path(*parts: str) -> str:
    return os.path.join(ROOT, *parts)


def load_json(rel: str):
    with open(path(rel), encoding="utf-8") as fh:
        return json.load(fh)


def read_bytes(rel: str) -> bytes:
    p = path(rel)
    if not os.path.exists(p):
        raise FileNotFoundError(rel)
    return open(p, "rb").read()


def read(rel: str) -> str:
    with open(path(rel), encoding="utf-8") as fh:
        return fh.read()


def walk(rel_root: str, exts: tuple[str, ...] | None = None) -> list[str]:
    fuera = {".git", "__pycache__", ".venv", "node_modules", "dist", ".terraform",
             ".pytest_cache", ".mypy_cache", ".nox", ".cache", ".output"}
    for base, dirs, files in os.walk(path(rel_root)):
        dirs[:] = [d for d in dirs if d not in fuera]
        for f in files:
            if exts is None or f.endswith(exts):
                yield os.path.relpath(os.path.join(base, f), ROOT).replace(os.sep, "/")


def schema_errors(instance, schema, prefix=""):
    """Errores de validacion con jsonschema o, si falta, con un subconjunto propio."""
    if Draft202012Validator is not None:
        v = Draft202012Validator(schema)
        for e in sorted(v.iter_errors(instance), key=lambda x: list(x.path)):
            where = prefix + "/".join(str(p) for p in e.path) or prefix + "<raiz>"
            yield where, e.message
        return
    # Fallback minimo: required + additionalProperties (suficiente para cazarnos errores nuestros)
    def rec(obj, sch, where):
        req = sch.get("required", [])
        if isinstance(obj, dict):
            for r in req:
                if r not in obj:
                    yield where + r, f"falta la propiedad obligatoria '{r}'"
            extra = set(obj) - set(sch.get("properties", {})) - set(sch.get("$defs", {}))
            if sch.get("additionalProperties") is False and extra:
                yield where, f"propiedades no permitidas: {', '.join(sorted(extra))}"
            for k, subsch in sch.get("properties", {}).items():
                if k in obj and isinstance(subsch, dict) and subsch.get("type") == "object":
                    yield from rec(obj[k], subsch, where + k + ".")
        elif isinstance(obj, list):
            for i, item in enumerate(obj):
                if sch.get("items"):
                    yield from rec(item, sch["items"], where + f"{i}.")

    yield from rec(instance, schema, prefix)


# --------------------------------------------------------------------------- config
def check_config(res: Results, cfg_rel: str) -> None:
    area = "config"
    try:
        cfg = load_json(cfg_rel)
    except FileNotFoundError:
        res.error(area, f"no existe {cfg_rel}")
        return
    except json.JSONDecodeError as exc:
        res.error(area, f"{cfg_rel} no es JSON valido: {exc}")
        return

    try:
        schema = load_json("config/vm.schema.json")
    except Exception as exc:  # pragma: no cover
        res.error(area, f"no se pudo leer config/vm.schema.json: {exc}")
        return

    errs = list(schema_errors(cfg, schema))
    for where, msg in errs:
        res.error(area, f"{cfg_rel} :: {where}: {msg}")
    if not errs:
        res.ok(area, f"{cfg_rel} conforme a config/vm.schema.json")

    limits = load_json("config/provider-limits.json")["providers"]
    prov = cfg.get("provider")
    if prov not in limits:
        res.error(area, f"proveedor desconocido en provider-limits.json: {prov}")
        return
    pl = limits[prov]
    sizes = {s["id"]: s for s in pl.get("sizes", [])}
    vm = cfg.get("vm", {})
    size = vm.get("size")

    # Limites del proveedor
    if size not in sizes and prov != "libvirt":
        res.error(area, f"vm.size '{size}' no aparece en config/provider-limits.json ({prov}): "
                        "anadelo con sus limites reales o elige uno listado")
    elif size in sizes:
        lim = sizes[size]
        if lim.get("vcpus") and vm.get("vcpus") != lim["vcpus"]:
            res.error(area, f"vm.vcpus={vm.get('vcpus')} no coincide con {size} ({lim['vcpus']} vCPU): "
                            "el SKU fija el numero de vCPU, no es un ajuste libre")
        if lim.get("ramGiB") and vm.get("ramGiB") != lim["ramGiB"]:
            res.error(area, f"vm.ramGiB={vm.get('ramGiB')} no coincide con {size} ({lim['ramGiB']} GiB)")
        gpu_cfg = cfg.get("gpu", {}).get("mode", "none")
        if gpu_cfg != "none" and not lim.get("gpu"):
            res.error(area, f"gpu.mode='{gpu_cfg}' pero {size} no tiene GPU: no se puede prometer "
                            "aceleracion ni codificador de hardware en este SKU")
        if gpu_cfg == "none" and lim.get("gpu"):
            res.warn(area, f"{size} tiene GPU pero gpu.mode='none': perderas el canal de juego")
        if vm.get("vcpus", 0) < 4:
            res.warn(area, "menos de 4 vCPU: el preset de gaming no es realista en este tamano")
        if vm.get("ramGiB", 0) < 8:
            res.warn(area, "menos de 8 GiB de RAM: Windows + launcher + juego no caben comodos")

    # Discos
    discos = pl.get("discos", {})
    for campo in ("osDiskSku", "dataDiskSku"):
        sku = vm.get(campo)
        tam = vm.get("osDiskGiB" if campo == "osDiskSku" else "dataDiskGiB", 0)
        if sku and sku in discos and tam:
            d = discos[sku]
            if tam < d["minGiB"]:
                res.error(area, f"{campo}={sku} admite como minimo {d['minGiB']} GiB (pedido {tam})")
            if tam > d["maxGiB"]:
                res.error(area, f"{campo}={sku} admite como maximo {d['maxGiB']} GiB (pedido {tam})")
        elif sku and sku not in discos and prov != "libvirt":
            res.error(area, f"{campo}='{sku}' no es un SKU declarado en provider-limits.json")
    if vm.get("dataDiskGiB", 0) == 0:
        res.warn(area, "sin disco de datos: los juegos se instalaran en el disco del SO, y en Azure el "
                      "disco temporal NO persiste tras deallocate")

    # Edicion de Windows + capacidad de software
    ed = cfg.get("windows", {}).get("edition")
    eds = load_json("config/windows-editions.json")["ediciones"]
    if ed not in eds:
        res.error(area, f"windows.edition '{ed}' no existe en config/windows-editions.json")
    else:
        edition = eds[ed]
        if edition.get("winget") == "no":
            res.warn(area, f"{ed} no tiene winget oficial: la instalacion de apps usara el camino "
                           "alternativo verificado o se detendra (ver docs/08-instalacion-apps.md)")
        if edition.get("microsoftStore") == "no":
            for app in load_json("apps/catalog.json")["aplicaciones"]:
                if app.get("compatibilidad", {}).get("requiereStore"):
                    res.warn(area, f"{app['id']} necesita Microsoft Store, ausente en {ed}")

    # Acceso remoto y exposicion
    remote = cfg.get("remote", {})
    cidrs = remote.get("allowedCidrs", [])
    tunel = remote.get("tunnel", "none")
    if not cidrs and tunel == "none":
        res.error(area, "remote.allowedCidrs=[] y remote.tunnel='none': no habria forma de conectar. "
                        "Lista tu IP o usa tailscale/ssh/bastion/vpn (no se abre 3389 a 0.0.0.0/0)")
    if any(c in ("0.0.0.0/0", "::/0") for c in cidrs):
        res.error(area, "remote.allowedCidrs contiene 0.0.0.0/0: exponer RDP a Internet esta prohibido "
                        "por este proyecto (docs/04-seguridad.md)")
    if not remote.get("requireNla", True):
        res.error(area, "remote.requireNla=false: NLA es obligatorio en este proyecto")
    if remote.get("port") not in (None, 3389):
        res.warn(area, f"puerto RDP {remote.get('port')}: recuerda abrirlo tambien en el NSG/Security Group")
    if remote.get("type") == "none":
        res.warn(area, "remote.type='none': no se configurara el acceso remoto")
    if remote.get("session", {}).get("avc444") and cfg.get("gpu", {}).get("mode") == "none":
        res.warn(area, "remote.session.avc444=true sin GPU: la politica se escribira en 0 (no se finge)")

    # Gaming
    gaming = cfg.get("gaming", {})
    if gaming.get("enabled") and gaming.get("channel") in ("moonlight", "both"):
        if cfg.get("gpu", {}).get("mode") == "none":
            res.error(area, "gaming.channel exige GPU para el canal de juego y gpu.mode='none': "
                            "elige un SKU con GPU o usa channel='rdp'")
        if gaming.get("sunshine", {}).get("encoder") == "software":
            res.warn(area, "gaming.sunshine.encoder='software': stream por CPU, mas latencia. "
                          "El informe de preparacion lo marcara como degradado")
    perfiles = gaming.get("touchControls", {}).get("profiles", [])
    for pf in perfiles:
        if not os.path.exists(path("gaming", "profiles", f"{pf}.json")):
            res.error(area, f"gaming.touchControls.profiles referencia gaming/profiles/{pf}.json y no existe")
    if gaming.get("enabled") and not cfg.get("windows", {}).get("autoLogon") and cfg.get("provider") != "libvirt":
        res.warn(area, "sin autoLogon, la sesion de consola puede estar bloqueada tras un reinicio: "
                       "el script Unlock-ConsoleSession.ps1 solo funciona si hay sesion iniciada")

    # Coste: no se promete gratuidad
    cost = cfg.get("cost", {})
    if cost.get("acknowledgePaidResources") is not True:
        res.error(area, "cost.acknowledgePaidResources debe ser true: las VM de azure/aws se facturan "
                        "por hora (VM + discos + GPU + IP + egreso). No existe la VM de gaming gratuita")
    if cost.get("spot") or vm.get("spot"):
        res.warn(area, "vm.spot=true: la VM puede ser interrumpida en plena partida; el proyecto no "
                      "reclama sesiones garantizadas")

    # Etiquetas y region
    if not cfg.get("tags"):
        res.warn(area, "sin tags: anade al menos 'proyecto' y 'proprietario' para poder auditar coste/uso")
    if Draft202012Validator is None:
        res.warn(area, "jsonschema no instalado: validacion estructural reducida "
                       "(pip install -r scripts/validate/requirements.txt)")


# --------------------------------------------------------------------------- apps
def check_apps(res: Results, online: bool = False) -> dict:
    area = "apps"
    try:
        cat = load_json("apps/catalog.json")
    except Exception as exc:
        res.error(area, f"apps/catalog.json ilegible: {exc}")
        return {}
    errs = list(schema_errors(cat, load_json("apps/catalog.schema.json")))
    for where, msg in errs:
        res.error(area, f"catalogo :: {where}: {msg}")
    if not errs:
        res.ok(area, "apps/catalog.json conforme a su schema")

    sources = load_json("apps/sources.json")
    permitidos = {h.lower() for h in sources["hostsPermitidos"]}
    ids_app = [a["id"].lower() for a in cat["aplicaciones"]]
    duplicados = {i for i in ids_app if ids_app.count(i) > 1}
    if duplicados:
        res.error(area, f"ids duplicados en el catalogo: {', '.join(sorted(duplicados))}")

    usados: set[str] = set()
    for nombre in ("minimal", "utilities", "gaming", "full"):
        sel_rel = f"apps/selections/{nombre}.json"
        if not os.path.exists(path(sel_rel)):
            res.error(area, f"falta la seleccion {sel_rel}")
            continue
        sel = load_json(sel_rel)
        for e in sel.get("aplicaciones", []):
            aid = e["id"].lower()
            usados.add(aid)
            if aid not in ids_app:
                res.error(area, f"{sel_rel} referencia '{e['id']}' que no esta en apps/catalog.json")
        # coherencia: un conjunto declarado en el catalogo debe aparecer en su seleccion
        esperado = {a["id"].lower() for a in cat["aplicaciones"] if nombre in a.get("conjuntos", [])}
        presentes = {e["id"].lower() for e in sel.get("aplicaciones", [])}
        for falta in sorted(esperado - presentes):
            res.warn(area, f"{nombre}..json no incluye '{falta}' aunque el catalogo dice conjuntos~{nombre}")
        for sobra in sorted(presentes - esperado):
            res.warn(area, f"{nombre}.json incluye '{sobra}' cuyo catalogo no marca conjuntos~{nombre}")

    for app in cat["aplicaciones"]:
        aid = app["id"]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*\.[A-Za-z0-9][A-Za-z0-9._+-]*", aid):
            res.error(area, f"{aid}: no tiene forma de PackageIdentifier 'Publicador.Nombre'")
        u = app.get("fuente", {}).get("oficial", "")
        for campo, url in (("fuente.oficial", u), ("fuente.descargaDirecta", app.get("fuente", {}).get("descargaDirecta", ""))):
            if not url:
                continue
            if not url.startswith("https://"):
                res.error(area, f"{aid}: {campo} no es https ({url})")
                continue
            host = re.sub(r"^https://", "", url).split("/")[0].lower()
            if host not in permitidos:
                res.error(area, f"{aid}: {campo} apunta a '{host}', que NO esta en apps/sources.json")
            if "@" in url or "password" in url.lower() or "?" in url and "=" in url and "token" in url.lower():
                res.error(area, f"{aid}: {campo} parece llevar credenciales en la URL")
        sha = app.get("verificacion", {}).get("installerSha256", "")
        if sha and not re.fullmatch(r"[0-9a-fA-F]{64}", sha):
            res.error(area, f"{aid}: verificacion.installerSha256 no es un SHA-256 hex de 64")
        if app["instalacion"]["metodo"] == "winget" and not app.get("verificacion", {}).get("firmanteEsperado"):
            res.warn(area, f"{aid}: instalacion por winget sin 'firmanteEsperado': no habra con que cotejar la firma")
        for hook in app.get("postInstalacion", []):
            if hook not in {
                "crear-carpeta-juegos", "fijar-biblioteca-steam", "iniciar-como-servicio",
                "quitar-de-autostart", "anadir-al-escritorio", "aplicar-perfil-controles",
                "crear-carpeta-capturas",
            }:
                res.error(area, f"{aid}: postInstalacion '{hook}' no esta soportada por Install-Apps.ps1")
        if app.get("compatibilidad", {}).get("bloqueadoEnVm"):
            res.ok(area, f"{aid}: marcada bloqueadaEnVm (el bootstrap la omite y documenta el motivo)")

    # Dominios declarados en sources.json: que no sean basura con espacios
    for h in permitidos:
        if not re.fullmatch(r"[a-z0-9.-]+", h):
            res.warn(area, f"apps/sources.json: host '{h}' no parece un dominio valido")

    if online:
        res.ok(area, "verificando ids contra microsoft/winget-pkgs (API de GitHub)...")
        for app in cat["aplicaciones"]:
            if app["instalacion"]["metodo"] != "winget":
                continue
            existe, meta = winget_lookup(app["id"])
            if existe is None:
                res.warn(area, f"{app['id']}: sin respuesta de la API ({meta}); omite la comprobacion")
            elif not existe:
                res.error(area, f"{app['id']}: no existe en microsoft/winget-pkgs (fuente no oficial)")
            else:
                if meta and app.get("verificacion", {}).get("installerSha256"):
                    if meta.lower() != app["verificacion"]["installerSha256"].lower():
                        res.warn(area, f"{app['id']}: el SHA-256 del catalogo difiere del manifiesto actual "
                                        "de winget (actualizacion de version: reintentar o vaciar el campo)")
                    else:
                        res.ok(area, f"{app['id']}: hash coincide con el manifiesto oficial")
    return {a["id"]: a for a in cat["aplicaciones"]}


def winget_lookup(pkg_id: str):
    """Devuelve (existe, sha256_del_ultimo_manifest_o_None) usando la API de repositorios de GitHub."""
    partes = pkg_id.split(".")
    ruta = "/".join(["manifests", partes[0][0].lower()] + partes)
    url = f"https://api.github.com/repos/microsoft/winget-pkgs/git/trees/master:{ruta}"
    req = urllib.request.Request(url, headers={"User-Agent": "win-gaming-vm-validator",
                                               "Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as exc:
        return (False, f"HTTP {exc.code}") if exc.code == 404 else (None, f"HTTP {exc.code}")
    except Exception as exc:  # red bloqueada, rate limit, etc.
        return (None, str(exc))
    versiones = [t["path"] for t in data.get("tree", []) if re.match(r"^[0-9]", t["path"] or "")]
    if not versiones:
        return True, None
    def clave(v):
        return [int(x) if x.isdigit() else 0 for x in re.findall(r"\d+", v)]
    ultima = max(versiones, key=clave)
    url2 = (f"https://api.github.com/repos/microsoft/winget-pkgs/contents/{ruta}/{ultima}/"
             f"{pkg_id}.installer.yaml")
    try:
        with urllib.request.urlopen(urllib.request.Request(url2, headers={"User-Agent": "win-gaming-vm-validator"}), timeout=25) as r2:
            import base64
            txt = base64.b64decode(json.load(r2)["content"]).decode("utf-8", "replace")
        sha = None
        for m in re.finditer(r"InstallerSha256:\s*([0-9a-fA-F]{64})", txt):
            sha = m.group(1)
            break
        return True, sha
    except Exception:
        return True, None


# --------------------------------------------------------------------------- gaming
def check_gaming(res: Results) -> None:
    area = "gaming"
    pdir = path("gaming", "profiles")
    if not os.path.isdir(pdir):
        res.error(area, "falta gaming/profiles")
        return
    esquema = load_json("gaming/schemas/gaming-profile.schema.json")
    for rel in sorted(walk("gaming/profiles", (".json",))):
        perfil = load_json(rel)
        errs = list(schema_errors(perfil, esquema, prefix=f"{rel} :: "))
        for where, msg in errs:
            res.error(area, f"{where}: {msg}")
        if not errs:
            res.ok(area, f"{rel} conforme a gaming/schemas/gaming-profile.schema.json")
        if perfil.get("id") != os.path.splitext(os.path.basename(rel))[0]:
            res.error(area, f"{rel}: 'id' ({perfil.get('id')}) debe coincidir con el nombre del fichero")
        req = perfil.get("requisitos", {})
        if req.get("fuente"):
            host = re.sub(r"^https?://", "", req["fuente"]).split("/")[0].lower()
            if host in {"reddit.com", "www.reddit.com", "youtube.com", "medium.com", "blogspot.com", "x.com"}:
                res.error(area, f"{rel}: requisitos.fuente apunta a una red social, no a la ficha oficial")
        vm = perfil.get("compatibilidadVm", {}).get("antitrampas", {}).get("vm")
        tactil = perfil.get("controles", {}).get("mapeoTactil", {}).get("modo")
        if vm == "restringida" and tactil not in (None, "ninguno"):
            res.error(area, f"{rel}: un juego con antichat que rechaza VM no puede prometer layout tactil "
                            "(mapeoTactil.modo debe ser 'ninguno')")
        layout = perfil.get("controles", {}).get("mapeoTactil", {}).get("layout")
        if layout:
            candidato = os.path.normpath(os.path.join(os.path.dirname(rel), layout)).replace(os.sep, "/")
            if not os.path.exists(path(candidato)):
                res.error(area, f"{rel}: el layout '{layout}' no existe (esperado en {candidato})")
            else:
                ldoc = load_json(candidato)
                lerrs = list(schema_errors(ldoc, load_json("gaming/touch/touch-layout.schema.json"), prefix=f"{candidato} :: "))
                for where, msg in lerrs:
                    res.error(area, f"{where}: {msg}")
                for e in ldoc.get("elementos", []):
                    if not (0.0 <= e["x"] <= 1.0 and 0.0 <= e["y"] <= 1.0):
                        res.error(area, f"{candidato}: elemento {e['id']} fuera de la pantalla (x={e['x']}, y={e['y']})")
                    if not (0.03 <= e["tamano"] <= 0.6):
                        res.error(area, f"{candidato}: elemento {e['id']} con tamano {e['tamano']} fuera de 0,03-0,60")
        host = perfil.get("aplicacion", {}).get("host", [])
        cliente = perfil.get("aplicacion", {}).get("cliente", [])
        for item in host:
            if item in ("layout-tactil", "mostrar-estadisticas"):
                res.error(area, f"{rel}: '{item}' es accion del cliente, no del host")
        for item in cliente:
            if item in ("sensibilidad-raton", "aceleracion-raton", "remap-teclas-powertoys"):
                res.error(area, f"{rel}: '{item}' se aplica en el host, no en el cliente")
        if not perfil.get("aplicacion", {}).get("pasosManuales") and cliente:
            res.warn(area, f"{rel}: hay acciones de cliente pero 'pasosManuales' esta vacio: el usuario no sabra que hacer")


# --------------------------------------------------------------------------- powershell
PS_ALLOWED_FIRST = re.compile(r"^\s*(<#|#|\[CmdletBinding|\$ErrorActionPreference|Set-StrictMode|param\s*\(|Import-Module|using)")


def limpiar_powershell(text: str) -> tuple[str, list[int]]:
    """Devuelve el codigo sin comentarios ni literales y la tabla de posiciones originales.

    Con la posicion original podemos reportar el numero de linea real del hallazgo.
    """
    out: list[str] = []
    posiciones: list[int] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "#" and not text.startswith("<#", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        if text.startswith("<#", i):
            fin = text.find("#>", i)
            i = n if fin < 0 else fin + 2
            continue
        if c in "\"'":
            q = c
            i += 1
            while i < n:
                if text[i] == "`" and q == '"' and i + 1 < n:
                    i += 2
                    continue
                if text[i] == q:
                    if i + 1 < n and text[i + 1] == q:
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            out.append(" ")  # huella para no romper indices visuales
            posiciones.append(i)
            continue
        out.append(c)
        posiciones.append(i)
        i += 1
    return "".join(out), posiciones


def revisar_cierres(texto: str) -> tuple[bool, str]:
    """True si el escaneo termina DENTRO de un literal o de un bloque <# ... #>.

    El balanceo de llaves no ve este fallo: una comilla sin cerrar se 'come' el resto del
    fichero y el parser de PowerShell aborta con un mensaje confuso.
    """
    i, n = 0, len(texto)
    while i < n:
        c = texto[i]
        if c == "#" and not texto.startswith("<#", i):
            while i < n and texto[i] != "\n":
                i += 1
            continue
        if texto.startswith("<#", i):
            fin = texto.find("#>", i)
            if fin < 0:
                return True, "comentario de bloque <# sin cerrar"
            i = fin + 2
            continue
        if c in "\"'":
            q = c
            aqui = i
            i += 1
            while i < n:
                if texto[i] == "`" and q == '"' and i + 1 < n:
                    i += 2
                    continue
                if texto[i] == q:
                    if i + 1 < n and texto[i + 1] == q:
                        i += 2
                        continue
                    i += 1
                    break
                if texto[i] == "\n" and q == "'":
                    # una comilla simple no puede saltar de linea en PowerShell
                    return True, f"literal de comilla simple sin cerrar (abierto en la linea {texto.count(chr(10), 0, aqui) + 1})"
                i += 1
            else:
                return True, f"literal de comilla doble sin cerrar (abierto en la linea {texto.count(chr(10), 0, aqui) + 1})"
            continue
        i += 1
    return False, ""


def linea_real(texto: str, posiciones: list[int], idx: int) -> int:
    """Numero de linea (1-based) en el fichero original del caracter idx del texto limpio."""
    if idx < len(posiciones):
        return texto.count("\n", 0, posiciones[idx]) + 1
    return texto.count("\n") + 1


def check_powershell(res: Results) -> None:
    area = "powershell"
    modulo = path("scripts", "win", "Modules", "GamingVM", "GamingVM.psm1")
    exportadas: set[str] = set()
    if os.path.exists(modulo):
        txt = read("scripts/win/Modules/GamingVM/GamingVM.psm1")
        exportadas = set(re.findall(r"^function\s+([A-Za-z]+-[A-Za-z0-9]+)", txt, re.M))
        lim, pos = limpiar_powershell(txt)
        balancear(txt, lim, pos, "GamingVM.psm1", res, area)
    psd1 = read("scripts/win/Modules/GamingVM/GamingVM.psd1")
    declaradas = set(re.findall(r"'([A-Z][A-Za-z]+-[A-Za-z0-9]+)'", psd1))
    faltan = declaradas - exportadas
    sobran = exportadas - declaradas
    if faltan:
        res.error(area, f"GamingVM.psd1 exporta funciones inexistentes: {', '.join(sorted(faltan))}")
    if sobran:
        res.warn(area, f"funciones en el .psm1 no listadas en FunctionsToExport: {', '.join(sorted(sobran))}")

    ficheros = sorted(walk("scripts", (".ps1",)))
    if not ficheros:
        res.error(area, "no hay scripts .ps1 en scripts/")
    for rel in ficheros:
        texto = read(rel)
        roto, motivo = revisar_cierres(texto)
        if roto:
            res.error(area, f"{rel}: {motivo}")
        limpio, posiciones = limpiar_powershell(texto)
        balancear(texto, limpio, posiciones, rel, res, area)
        # 1) operadores de PowerShell 7 que rompen en Windows PowerShell 5.1
        for patron, nombre in ((r"\|\|", "||"), (r"&&", "&&"), (r"\?\?", "??")):
            for ln, _ in hallazgos_en_codigo(texto, patron):
                res.error(area, f"{rel}:{ln}: el operador {nombre} no existe en Windows PowerShell 5.1")
        for patron, nombre in ((r"ConvertFrom-Json\s+-AsHashtable", "ConvertFrom-Json -AsHashtable"),
                               (r"ForEach-Object\s+-Parallel", "ForEach-Object -Parallel"),
                               (r"-TimeoutSeconds", "Test-Connection -TimeoutSeconds"),
                               (r"Get-Error\b", "Get-Error")):
            for ln, _ in hallazgos_en_codigo(texto, patron):
                res.error(area, f"{rel}:{ln}: `{nombre}` es de PowerShell 7+; el bootstrap debe correr "
                                "en la 5.1 que trae Windows Server por defecto")
        # 2) cabecera: param + strict mode + manejo de errores
        if "param(" not in limpio:
            if "Initialize-GvmRuntime" not in texto:
                res.warn(area, f"{rel}: sin bloque param()")
        if "Set-StrictMode" not in texto:
            res.warn(area, f"{rel}: falta Set-StrictMode")
        if "$ErrorActionPreference" not in texto:
            res.error(area, f"{rel}: falta $ErrorActionPreference (los fallos deben abortar, no seguir)")
        # Windows PowerShell 5.1 lee los .ps1 sin BOM como ANSI: los acentos del
        # comentario y de los literales salen como mojibake (o rompen el parseo).
        if any(ord(c) > 127 for c in texto) and not read_bytes(rel).startswith(b"\xef\xbb\xbf"):
            res.error(area, f"{rel}: tiene caracteres no ASCII y ningun BOM UTF-8; Windows PowerShell 5.1 "
                            "lo leera como ANSI. Anade el BOM al fichero o pasalo a ASCII")
        if not re.search(r"<#\s*\.SYNOPSIS", texto):
            res.error(area, f"{rel}: falta la documentacion de ayuda (comment-based help con .SYNOPSIS)")
        # 3) funciones del modulo usadas pero inexistentes
        usados = set(re.findall(r"\b((?:Get|Set|Test|Write|New|Install|Initialize|Assert|Resolve|Export|Clear|Undo)-Gvm[A-Za-z0-9]+)\b", limpio))
        for u in sorted(usados - exportadas):
            res.error(area, f"{rel}: llama a {u}(), que no esta definida en GamingVM.psm1")
        # 4) scripts invocados por ruta
        for ref in re.findall(r"Join-Path\s+\$PSScriptRoot\s+'([^']+\.ps1)'", limpio):
            if not os.path.exists(path("scripts", "win", ref.replace("\\", os.sep))):
                res.error(area, f"{rel}: invoca scripts/win/{ref} y no existe")
        # 5) secretos y acciones prohibidas
        for ln, _ in hallazgos_en_codigo(texto, r"(?i)(password\s*=\s*['\"][^'\"]{4,}|ConvertTo-SecureString\s+-String|-Token\s*=\s*['\"][A-Za-z0-9]{12,})"):
            res.error(area, f"{rel}:{ln}: posible credencial embebida")
        for ln, _ in hallazgos_en_codigo(texto, r"(?i)Set-MpPreference\s+-DisableRealtimeMonitoring", solo_codigo=False):
            res.error(area, f"{rel}:{ln}: desactiva la proteccion en tiempo real (prohibido por el proyecto)")
        for ln, _ in hallazgos_en_codigo(texto, r"(?i)(Stop-Service|Set-Service|Disable-Service)\s+.*WinDefend", solo_codigo=False):
            res.error(area, f"{rel}:{ln}: toca el servicio de Defender (prohibido)")
        # 6) aqui-strings sin terminador y strings con comillas tipograficas
        if "“" in texto or "”" in texto or "’" in texto:
            res.error(area, f"{rel}: contiene comillas tipograficas (rompen el parseo de PowerShell)")


def balancear(texto: str, limpio: str, posiciones: list[int], rel: str, res: Results, area: str) -> None:
    pares = {"{": "}", "(": ")", "[": "]"}
    op = {v: k for k, v in pares.items()}
    pila: list[tuple[str, int]] = []
    linea = 1
    for ch in limpio:
        if ch == "\n":
            linea += 1
            continue
        if ch in pares:
            pila.append((ch, linea))
        elif ch in op:
            if not pila:
                res.error(area, f"{rel}: cierre '{ch}' suelto en la linea {linea}")
            else:
                abre, _ = pila.pop()
                if pares[abre] != ch:
                    res.error(area, f"{rel}: '{abre}' sin cerrar (abierto linea {linea}, encontrado '{ch}')")
    for abre, ln in pila:
        res.error(area, f"{rel}: '{abre}' abierto en la linea {ln} no se cierra")
    if texto.count("<#") != texto.count("#>"):
        res.error(area, f"{rel}: bloque de comentario <# ... #> sin cerrar ({texto.count('<#')} aperturas vs {texto.count('#>')} cierres)")


def hallazgos_en_codigo(texto: str, patron: str, solo_codigo: bool = True):
    """Encuentra `patron` en el codigo PowerShell (ignorando comentarios/literales si procede)."""
    if solo_codigo:
        limpio, posiciones = limpiar_powershell(texto)
        for m in re.finditer(patron, limpio):
            yield linea_real(texto, posiciones, m.start()), m.group(0)
    else:
        for m in re.finditer(patron, texto, re.S):
            yield texto.count("\n", 0, m.start()) + 1, m.group(0)


# --------------------------------------------------------------------------- estructura
def check_estructura(res: Results) -> None:
    area = "estructura"
    obligatorios = [
        "README.md", "LICENSE", ".gitignore",
        "config/vm.schema.json", "config/vm.example.json", "config/provider-limits.json",
        "config/windows-editions.json", "config/remote-session.json", "config/gaming-presets.json",
        "config/resolutions.json",
        "apps/catalog.json", "apps/catalog.schema.json", "apps/sources.json",
        "apps/selections/utilities.json", "apps/selections/gaming.json",
        "gaming/README.md", "gaming/schemas/gaming-profile.schema.json",
        "scripts/win/Bootstrap-GamingVM.ps1", "scripts/win/Install-Apps.ps1",
        "scripts/win/Set-RemoteDesktop.ps1", "scripts/win/Set-GamingOptimizations.ps1",
        "scripts/win/Set-Sunshine.ps1", "scripts/win/Set-TouchControls.ps1",
        "scripts/win/Set-SecurityBaseline.ps1", "scripts/win/Test-GamingReadiness.ps1",
        "scripts/win/Get-SystemMetrics.ps1", "scripts/win/Install-GpuDriver.ps1",
        "scripts/win/Modules/GamingVM/GamingVM.psm1", "scripts/win/Modules/GamingVM/GamingVM.psd1",
        "scripts/validate/validate.py", "scripts/validate/requirements.txt",
        "infra/azure/main.tf", "infra/aws/main.tf", "infra/kvm/main.tf",
        ".github/workflows/validate.yml", ".github/workflows/release.yml",
    ]
    for rel in obligatorios:
        if not os.path.exists(path(rel)):
            res.error(area, f"falta {rel}")
    # README en espanol y con las secciones clave
    readme = path("README.md")
    if os.path.exists(readme):
        txt = open(readme, encoding="utf-8").read()
        # Plegamos acentos: el README puede titular "Instalacion" o "Instalación", y aqui
        # se comprueban conceptos, no tildes.
        def plegar(t: str) -> str:
            import unicodedata
            return "".join(c for c in unicodedata.normalize("NFD", t) if unicodedata.category(c) != "Mn")
        plano = plegar(txt).lower()
        for clave in ("Arquitectura", "Instalacion", "Limitaciones", "Seguridad"):
            if clave.lower() not in plano:
                res.error(area, f"README.md: falta la seccion '{clave}' prometida por el enunciado")
        if len(txt) < 4000:
            res.warn(area, "README.md corto para ser la guia completa del proyecto")
    if Draft202012Validator is None:
        res.warn(area, "sin jsonschema: validacion de schemas reducida")


def check_secretos(res: Results) -> None:
    area = "secretos"
    patrones = [
        (r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "clave privada"),
        (r"(?i)\b(AKIA|ASIA)[0-9A-Z]{16}\b", "access key de AWS"),
        (r"\bgh[pousr]_[A-Za-z0-9]{20,}\b", "token de GitHub"),
        (r"(?i)xox[baprs]-[A-Za-z0-9-]{10,}", "token de Slack"),
        (r"(?i);Authentication=Basic [A-Za-z0-9+/=]{10,}", "autenticacion basica en cadena de conexion"),
        (r"(?i)(password|passwd|pwd|secret|token|apikey|api_key)\s*[:=]\s*['\"][^'\"\n]{6,}['\"]", "posible credencial literal"),
        (r"(?i)User=.*;Password=[^'\"]", "cadena de conexion con contrasena"),  # nosec
        (r"[?&](?:sig|sv|sp)=2?[0-9a-zA-Z%+/=]{16,}", "consulta con firma SAS de Azure"),
    ]
    ignorados = re.compile(r"(?i)(schema\.json|vm\.example|README|docs/|\.md$|examples?/|test)")
    total = 0
    for rel in walk(".", None):
        if rel.endswith((".png", ".jpg", ".ico", ".qcow2", ".iso")):
            continue
        if "vm.example" in rel or rel.endswith("sources.json"):
            continue
        try:
            texto = read(rel)
        except Exception:
            continue
        if "\x00" in texto:
            continue
        for patron, nombre in patrones:
            for m in re.finditer(patron, texto):
                ln = texto[: m.start()].count("\n") + 1
                # permitimos menciones documentales dentro de textos de ayuda/schema
                linea = texto.split("\n")[ln - 1]
                if "# nosec" in linea or "patrones" in linea:
                    continue
                # Los ficheros documentales y de pruebas CITAN los patrones para explicarlos
                # o para comprobar que se detectan: ahi solo exigimos los de alta confianza
                # (clave privada, AKIA, tokens de GitHub/Slack, Basic en cadena de conexion).
                if nombre == "posible credencial literal" and ignorados.search(rel):
                    continue
                if nombre == "posible credencial literal" and re.search(r"(?i)(ejemplo|placeholder|cambia-|<|\{\{|tu-)", linea):
                    continue
                res.error(area, f"{rel}:{ln}: {nombre} detectada -> {linea.strip()[:90]}")
                total += 1
    if total == 0:
        res.ok(area, "sin credenciales ni tokens en el arbol")


# --------------------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser(description="Validador del repositorio Win Gaming VM")
    ap.add_argument("--config", default="config/vm.example.json", help="JSON de configuracion a validar")
    ap.add_argument("--solo", nargs="*", choices=["config", "apps", "gaming", "powershell", "estructura", "secretos"], help="ejecuta solo estas comprobaciones")
    ap.add_argument("--online", action="store_true", help="verifica los ids de winget contra microsoft/winget-pkgs")
    ap.add_argument("--verbose", action="store_true", help="muestra tambien los [OK]")
    args = ap.parse_args()

    res = Results(verbose=args.verbose)
    pasos = args.solo or ["config", "apps", "gaming", "powershell", "estructura", "secretos"]
    if "config" in pasos:
        check_config(res, args.config)
        # La configuracion REAL del usuario (ignorada por git) es la que manda en la VM: si
        # existe y no es la que se paso por --config, se valida tambien.
        if args.config != "config/vm.json" and os.path.exists(path("config", "vm.json")):
            check_config(res, "config/vm.json")
        for extra in sorted(walk("config", (".json",))):
            if extra.endswith(".schema.json") or os.path.basename(extra) == "vm.example.json":
                continue
            try:
                load_json(extra)
            except Exception as exc:
                res.error("config", f"{extra}: JSON invalido: {exc}")
    if "apps" in pasos:
        check_apps(res, online=args.online)
    if "gaming" in pasos:
        check_gaming(res)
    if "powershell" in pasos:
        check_powershell(res)
    if "estructura" in pasos:
        check_estructura(res)
    if "secretos" in pasos:
        check_secretos(res)

    res.report()
    print(f"\nResumen: {len(res.errores)} errores, {len(res.avisos)} avisos "
          f"({len(res.items)} comprobaciones)")
    return 1 if res.errores else 0


if __name__ == "__main__":
    sys.exit(main())
