# Atajos para el ciclo local. Todo lo que aqui se ejecuta en TU estacion: la VM se prepara
# con los scripts de scripts/win (PowerShell), no con make.
PY ?= python3
VENV ?= .venv
PYBIN := $(wildcard $(VENV)/bin/python)
ifneq ($(PYBIN),)
PY := $(PYBIN)
endif

.PHONY: help venv valid valid-online test enlaces tf-fmt tf-lint ps-lint limpiar release-check

help:            ## muestra esta ayuda
	@grep -hE '^[a-zA-Z0-9_.-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

venv:            ## crea el entorno virtual con las dependencias del validador
	$(PY) -m venv $(VENV)
	$(VENV)/bin/python -m pip install -r scripts/validate/requirements.txt

valid:           ## validador del repositorio (config, apps, gaming, PS, estructura, secretos)
	$(PY) scripts/validate/validate.py --verbose

valid-online:    ## validador + contraste de ids de winget contra el repositorio oficial
	$(PY) scripts/validate/validate.py --online --verbose

test:            ## pruebas del validador y de los datos
	$(PY) -m pytest -q

enlaces:         ## enlaces relativos rotos en la documentacion
	$(PY) scripts/validate/check_links.py

ps-lint:         ## analisis de estilo de los .ps1 si tienes pwsh + PSScriptAnalyzer instalado
	@command -v pwsh >/dev/null 2>&1 || { echo "pwsh no disponible: esto lo hace el trabajo windows-scripts en CI"; exit 0; }
	@pwsh -NoProfile -Command 'if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { throw "instala el modulo: Install-Module PSScriptAnalyzer" }; Get-ChildItem scripts/win -Recurse -Include *.ps1,*.psm1 | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings scripts/validate/PSScriptAnalyzerSettings.psd1 } | Tee-Object -FilePath ps-lint.txt | Out-Host'

tf-fmt:          ## terraform fmt en los tres modulos
	@for d in azure aws kvm; do (cd infra/$$d && terraform fmt -recursive) || true; done

tf-lint:         ## fmt + init + validate por modulo (necesita red al registry)
	@for d in azure aws kvm; do \
	  echo "== infra/$$d"; (cd infra/$$d && terraform init -backend=false -input=false && terraform fmt -check -recursive && terraform validate) || exit 1; \
	done

release-check:   ## lo que exige el trabajo de release antes de pushear un tag
	@test -f VERSION || { echo "falta VERSION"; exit 1; }
	@git rev-parse --abbrev-ref HEAD
	@$(PY) scripts/validate/validate.py
	@$(PY) -m pytest -q
	@$(PY) scripts/validate/check_links.py
	@if find . -path ./.git -prune -o -type f \( -name '*.exe' -o -name '*.msi' -o -name '*.iso' \) -print | grep -q .; then echo "hay binarios en el arbol"; exit 1; fi
	@echo "listo para: git tag v$$(cat VERSION) && git push origin --tags"

limpiar:         ## quita artefactos locales
	rm -rf .pytest_cache **/__pycache__ dist release-notes.md ps-lint.txt
	find . -name '*.tfstate*' -maxdepth 3 -not -path './.git/*' -delete 2>/dev/null || true
