"""Pruebas del validador del repositorio.

No prueban "que el codigo sea bonito": prueban que las defensas que evitan una VM
inutil o inseguida siguen vivas. Se ejecutan con fixtures en un directorio temporal,
asi que pueden romper cosas sin miedo.

Uso:  python -m pytest -q
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import textwrap

import pytest

RAIZ = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
VALIDADOR = os.path.join(RAIZ, "scripts", "validate", "validate.py")


def ejecutar(cwd: str, *args: str) -> subprocess.CompletedProcess:
    """Ejecuta el validador DESDE la copia, no el original.

    validate.py resuelve sus rutas a partir de donde esta el fichero, asi que lanzar el del
    repositorio contra una copia evaluaria el original y el test no probaria nada.
    """
    script = os.path.join(cwd, "scripts", "validate", "validate.py")
    if not os.path.exists(script):
        script = VALIDADOR
    return subprocess.run(
        [sys.executable, script, *args], cwd=cwd, capture_output=True, text=True, timeout=180
    )


def copiar_repo(dst: str) -> str:
    """Copia el arbol del repo (sin caches) para poder romperlo sin miedo."""
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(
        RAIZ, dst,
        ignore=shutil.ignore_patterns(".git", ".venv", "__pycache__", ".pytest_cache", "dist", ".terraform"),
    )
    return dst


# --- El repo tal cual tiene que pasar todo lo que se puede comprobar sin VM ---------


@pytest.mark.parametrize("area", ["config", "apps", "gaming", "powershell", "secretos"])
def test_areas_del_repo_pasaron(area: str) -> None:
    p = ejecutar(RAIZ, "--solo", area)
    assert p.returncode == 0, f"area {area}:\n{p.stdout}\n{p.stderr}"


def test_estructura_sin_readme_no_es_error_de_config() -> None:
    """`estructura` solo debe fallar por ficheros prometidos, no por el resto."""
    p = ejecutar(RAIZ, "--solo", "estructura")
    lineas = [l for l in p.stdout.splitlines() if l.startswith("[ERROR]")]
    for l in lineas:
        assert "README.md" in l or "falta" in l, f"hallazgo inesperado en estructura: {l}"


def test_online_no_rompe_sin_red(tmp_path: str) -> None:
    """`--online` debe degradarse a aviso si no hay red, no colgar ni explosar."""
    copia = copiar_repo(str(tmp_path / "repo"))
    p = ejecutar(copia, "--solo", "apps", "--online")
    assert p.returncode in (0, 1)
    assert "Resumen:" in p.stdout


# --- Config: las trampas que el esquema debe negarse ------------------------------

CONFIG_BAD = {
    "cidr_universal": (
        {"remote": {"tunnel": "none", "allowedCidrs": ["0.0.0.0/0"], "requireNla": True,
                    "tipo": "rdp-windows-app", "session": {}}},
        "config",
    ),
    "sin_nla": (
        {"remote": {"tunnel": "none", "allowedCidrs": ["203.0.113.5/32"], "requireNla": False,
                    "tipo": "rdp-windows-app", "session": {}}},
        "config",
    ),
    "coste_sin_reconocer": (
        {"cost": {"acknowledgePaidResources": False, "presupuestoMensualUsd": 90}},
        "config",
    ),
}


@pytest.mark.parametrize("clave", list(CONFIG_BAD))
def test_config_rechaza_lo_peligroso(tmp_path, clave: str) -> None:
    """Cada una de estas configuraciones tiene que seguir siendo un ERROR."""
    parche, _area = CONFIG_BAD[clave]
    copia = str(tmp_path / "repo")
    os.makedirs(os.path.join(copia, "config"))
    for f in os.listdir(os.path.join(RAIZ, "config")):
        shutil.copy2(os.path.join(RAIZ, "config", f), os.path.join(copia, "config", f))
    ruta_ejemplo = os.path.join(copia, "config", "vm.example.json")
    cfg = json.load(open(ruta_ejemplo, encoding="utf-8"))

    def fundir(a: dict, b: dict) -> None:
        for k, v in b.items():
            if isinstance(v, dict) and isinstance(a.get(k), dict):
                fundir(a[k], v)
            else:
                a[k] = v

    fundir(cfg, parche)
    ruta_real = os.path.join(copia, "config", "vm.json")
    json.dump(cfg, open(ruta_real, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    p = ejecutar(copia, "--solo", "config", "--config", "config/vm.json")
    assert "ERROR" in p.stdout or p.returncode == 1, (
        f"'{clave}' deberia ser un error y el validador paso: {p.stdout}"
    )


# --- PowerShell: los errores que el validador debe cazar ---------------------------

PS_BAD = [
    ("operador de PowerShell 7", "||\n"),
    (" hashtable con comas", "[ordered]@{ a = 1, b = 2 }\n"),
    ("sin ErrorActionPreference", "Write-Host 'hola'\n"),
    ("clave de winget inexistente", "Install-GvmWingetApp -Id 'No.Existe'\n"),
]


@pytest.mark.parametrize("descripcion,fragmento", PS_BAD)
def test_powershell_detecta_constructos_prohibidos(tmp_path, descripcion: str, fragmento: str) -> None:
    copia = copiar_repo(str(tmp_path / "repo"))
    malo = os.path.join(copia, "scripts", "win", "Malo.ps1")
    texto = textwrap.dedent(
        """\
        <#
          .SYNOPSIS
            Script de prueba.
        #>
        [CmdletBinding()]
        param()
        $ErrorActionPreference = 'Stop'
        """
    ) + fragmento
    with open(malo, "w", encoding="utf-8") as fh:
        fh.write(texto)
    p = ejecutar(copia, "--solo", "powershell")
    assert "Malo.ps1" in p.stdout, f"no se detecto '{descripcion}':\n{p.stdout}"


def test_powershell_exige_ayuda(tmp_path) -> None:
    copia = copiar_repo(str(tmp_path / "repo"))
    with open(os.path.join(copia, "scripts", "win", "SinAyuda.ps1"), "w", encoding="utf-8") as fh:
        fh.write("$ErrorActionPreference = 'Stop'\nWrite-Host 'x'\n")
    p = ejecutar(copia, "--solo", "powershell")
    assert "SinAyuda.ps1" in p.stdout and "ayuda" in p.stdout


# --- Secretos ---------------------------------------------------------------------

SECRETOS = [
    ("contrasena en variable", "pass" + "word = 'SuperSecreta123!'"),
    ("clave privada", "-----BEGIN OPEN" + "SSH PRIVATE KEY-----"),
    ("SAS de Azure", 'url = "https://c.blob.core.windows.net/c?sv=2021-06-' + '08&' + 'sig=abcdef0123456789"'),
    ("token de GitHub", "token = 'gh" + "p_abcdefghijklmnopqrstuvwxy'"),
]


@pytest.mark.parametrize("descripcion,fragmento", SECRETOS)
def test_secretos_detecta_credenciales(tmp_path, descripcion: str, fragmento: str) -> None:
    copia = copiar_repo(str(tmp_path / "repo"))
    malo = os.path.join(copia, "scripts", "win", "Filtracion.ps1")
    with open(malo, "w", encoding="utf-8") as fh:
        fh.write("<#\n  .SYNOPSIS\n    x\n#>\n$ErrorActionPreference = 'Stop'\n" + fragmento)
    p = ejecutar(copia, "--solo", "secretos")
    assert "Filtracion.ps1" in p.stdout, f"no se detecto: {descripcion}\n{p.stdout}"


def test_el_repo_no_tiene_secretos() -> None:
    p = ejecutar(RAIZ, "--solo", "secretos")
    assert p.returncode == 0, p.stdout


# --- Apps y gaming -----------------------------------------------------------------


def test_catalogo_rechaza_host_no_permitido(tmp_path) -> None:
    copia = copiar_repo(str(tmp_path / "repo"))
    ruta = os.path.join(copia, "apps", "catalog.json")
    d = json.load(open(ruta, encoding="utf-8"))
    d["aplicaciones"][0]["fuente"]["descargaDirecta"] = "https://mirror-dudoso.example/7z.exe"
    json.dump(d, open(ruta, "w", encoding="utf-8"), ensure_ascii=False)
    p = ejecutar(copia, "--solo", "apps")
    assert "sources.json" in p.stdout or "rechazad" in p.stdout.lower() or p.returncode == 1, p.stdout


def test_perfil_de_juego_debe_coincidir_con_el_nombre(tmp_path) -> None:
    copia = copiar_repo(str(tmp_path / "repo"))
    shutil.copy(
        os.path.join(RAIZ, "gaming", "profiles", "fortnite.json"),
        os.path.join(copia, "gaming", "profiles", "otro-nombre.json"),
    )
    p = ejecutar(copia, "--solo", "gaming")
    assert p.returncode == 1 and "otro-nombre" in p.stdout


def test_layout_invalido_rechazado(tmp_path) -> None:
    copia = copiar_repo(str(tmp_path / "repo"))
    ruta = os.path.join(copia, "gaming", "touch", "layouts", "plataformas-2d.json")
    d = json.load(open(ruta, encoding="utf-8"))
    d["elementos"][0]["x"] = 1.7          # fuera de [0,1]
    json.dump(d, open(ruta, "w", encoding="utf-8"), ensure_ascii=False)
    p = ejecutar(copia, "--solo", "gaming")
    assert p.returncode == 1


# --- Estructura --------------------------------------------------------------------


def test_estructura_del_repo_actual_es_completa() -> None:
    """Si alguien mueve/borra un directorio prometido, esto tiene que fallar."""
    p = ejecutar(RAIZ, "--solo", "estructura")
    assert p.returncode == 0, p.stdout


def test_faltan_directorios_obligatorios(tmp_path) -> None:
    copia = copiar_repo(str(tmp_path / "repo"))
    shutil.rmtree(os.path.join(copia, "gaming"))
    p = ejecutar(copia, "--solo", "estructura")
    assert p.returncode == 1 and "gaming" in p.stdout


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
