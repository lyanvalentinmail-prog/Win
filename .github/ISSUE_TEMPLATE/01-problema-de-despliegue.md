---
name: Problema de despliegue
about: La VM no se crea, el bootstrap falla, las apps no se instalan o el acceso remoto no funciona
labels: despliegue
---

<!-- Nunca pegues contrasenas, tokens, SAS URLs, ni el contenido de terraform.tfstate. -->

**Entorno**
- proveedor y region:
- tamanho de VM (p. ej. `Standard_NV6ads_A10_v5`):
- edicion de Windows (`windows.edition` en `config/vm.json`):
- version de este repositorio (pega `Get-Content VERSION` o el tag):
- cliente: dispositivo, Android/Windows/iOS, Windows App o Moonlight, red (misma red o no)

**Que esperabas y que ha pasado**

**Estado de las fases**
```powershell
Get-Content C:\ProgramData\WinGamingVM\state\fases.json
Get-ChildItem C:\ProgramData\WinGamingVM\logs | Sort-Object LastWriteTime | Select-Object -Last 3
```

**Salida relevante**
Final del log del bootstrap y del informe `C:\ProgramData\WinGamingVM\informes\preparacion-*.md`.

**Comprobaciones que ya he hecho**
- [ ] `python scripts/validate/validate.py` pasa en mi copia
- [ ] el informe de preparacion ejecutado dentro de la VM (`scripts/win/Test-GamingReadiness.ps1`)
- [ ] leidos `docs/02-proveedores-y-limites.md` y `docs/06-limitaciones-windows-app.md`
- [ ] `cost.acknowledgePaidResources` en `true` (la VM se factura por hora)
