# 09 · Seguridad

Principio: **una VM de Windows expuesta a Internet es el activo más expuesto del proyecto**.
Todo lo demás (apps, perfiles, bitrate) es accesorio si el 3389 está abierto al mundo con un
usuario `Administrador`.

## Modelo de amenaza y control

| Amenaza | Control aplicado | Dónde |
| --- | --- | --- |
| Fuerza bruta sobre RDP | NLA obligatoria (`UserAuthentication=1`), `SecurityLayer=1`, `MinEncryptionLevel=3`; **sin regla de entrada si no declaras tu CIDR** | `Set-RemoteDesktop.ps1`, `infra/azure`, `infra/aws` |
| Escaneo masivo del puerto | IP nueva + regla solo a tu IP; opcionalmente túnel (Tailscale/Bastion/SSM) | `remote.tunnel`, `scripts/client/Montar-TunelSSH.ps1` |
| Credencial filtrada en el repo | `config/vm.json` y `*.tfvars` en `.gitignore`; `sensitive=true` en Terraform; el validador **falla** si detecta una contraseña literal | `.gitignore`, `scripts/validate/validate.py` |
| Contraseña débil de proveedor | precondition de Terraform (≥12) + complejidad de Azure | `infra/azure/vm.tf` |
| Sesión huérfana abierta | `MaxIdleTime`, bloqueo por inactividad (`security.screenLockMinutes`) | `Set-RemoteDesktop.ps1`, `Set-SecurityBaseline.ps1` |
| Acceso de no administradores | `Remote Desktop Users` vigilado; recomendación de dejarlo vacío | `security.restrictRdpToAdministrators` |
| Malware | Defender **siempre activo**; solo se actualizan firmas; exclusiones **solo** si las pides explícitamente | `Set-SecurityBaseline.ps1`, `power.*` |
| Exposición de Sunshine (web UI 47990) | `origin_web_ui_allowed=pc` + reglas de firewall restringidas, o **creadas deshabilitadas** si no declaraste CIDR | `Set-Sunshine.ps1` |
| Redirección de disco/micro del cliente | `fDisableCdm=1` y `fDisableAudioCapture=1` por defecto | `Set-RemoteDesktop.ps1` |
| Robo de datos en reposo | disco gestionado con cifrado por plataforma; BitLocker del disco D: opcional con clave exportada **a un fichero fuera del repo** | `security.bitlockerDataDisk`, `Set-SecurityBaseline.ps1` |
| State de Terraform con la contraseña | backend remoto cifrado + recomendación explícita | `infra/README.md` |
| Auditoría insuficiente | `auditpol` (inicio de sesión, cambios de privilegios, objeto de acceso) → visibles en el informe | `Set-SecurityBaseline.ps1` |
| Servicio de terceros "optimizador" | no se instala nada fuera del catálogo verificado; la allow-list de hosts es vinculante | `apps/sources.json`, `Install-Apps.ps1` |

## Lo que el proyecto **no** hace (aunque te lo pidan)

- **No desactiva Defender** ni `mpssvc`, `BFE`, `Sense`, `wuauserv`, `WinDefend`: la fase de
  optimización tiene una lista **prohibida** que lanza una excepción si intentas
  deshabilitarlas desde `power.disableUnusedServices`.
- **No abre 0.0.0.0/0** en ningún firewall, ni siquiera "para probar": el validador lo
  convierte en error de configuración.
- **No genera ni guarda credenciales**: no escribe la contraseña en `acceso-windows-app.md`,
  no hace `net user /add` con contraseñas en claro, no guarda tokens de Tailscale.
- **No instala SSH/RDP expuestos sin tu config**: si `remote.tunnel: none` y `allowedCidrs`
  vacío, las reglas de firewall quedan **deshabilitadas** y el script te explica el callejón.
- **No endurece LSA hasta romper el propio acceso**: lo que escribe `Set-SecurityBaseline.ps1`
  es `LmCompatibilityLevel=3` (NTLMv2 + sesión firmada, el valor que **mantiene** NLA/RDP
  funcionando — `5` rechazaría NTLM y es fácil que te deje fuera), `RestrictAnonymous=1`,
  `everyoneincludesanonymous=0`, `limitblankpassworduse=1`, `SchUseStrongCrypto` para TLS y
  apagado de LLMNR/NetBIOS. Cualquier desviación del ideal queda en el informe como `aviso`
  con el motivo, no como un silencio.
- **No evita el antitrampas del juego** con spoofing: no hay parches, no hay drivers sin
  firmar, no hay "modo stealth". Se documenta y no se instala lo que no va a funcionar.

## Checklist de despliegue seguro

1. [ ] `remote.tunnel` elegido (`tailscale`/`bastion`/`ssh`) **o** `allowedCidrs` con tu IP exacta /32.
2. [ ] `remote.requireNla: true` y `security.restrictRdpToAdministrators: true`.
3. [ ] Contraseña del proveedor ≥ 20 caracteres, única, en un gestor; nunca en el repo.
4. [ ] Usuario de conexión = administrador local con otro nombre que `admin`/`administrator`.
5. [ ] `security.screenLockMinutes` ≤ 10 si compartes espacio físico.
6. [ ] Sunshine: `allowedCidrs` igual de estricto que RDP; el PIN se introduce en la LAN; nada de reenvío de puertos en el router.
7. [ ] Instantánea/respaldo del disco de datos antes de tocar drivers (`scripts/deploy/backup-disk.ps1`).
8. [ ] `Test-GamingReadiness.ps1` sin ERROR, y su informe revisado **una vez** (no vale "sale verde siempre").
9. [ ] Revisa `netstat -ano` / el chequeo de puertos del informe: si algo escucha que tú no pediste, eso es un hallazgo, no ruido.
10. [ ] `gaming.sunshine.keepConsoleSession` consciente: la sesión de consola desbloqueada es cómoda y **es** un riesgo si alguien más tiene acceso físico al host... en la nube, no; en KVM en tu salón, sí.

## Si algo sale mal

1. **Credencial expuesta**: cambia la contraseña desde el proveedor (`az vm run-command` con
   `Set-LocalUser`, o la consola), revoca sesiones, y si el state de Terraform tenía la
   contraseña antigua, rota el state y regenera el backend.
2. **Puerto abierto por error**: `Remove-NetFirewallRule` + cierra el NSG; luego revisa el
   registro de auditoría de inicios de sesión (el informe de preparación te dice dónde).
3. **VM comprometida**: no "limpies": `terraform destroy` con el disco de datos conservado
   (`terraform state rm` del disco), y recrea la VM desde cero con las mismas fases. Es la
   vía honesta y reproducible.
4. **Ransomware/cifrado en D:**: snapshot del disco (Azure/AWS) o instantánea KVM; por eso
   `backup-disk.ps1` existe.

## Reporte de vulnerabilidades

Ver `.github/SECURITY.md`. No se parchean por issue público; se corrige el repo y se
recomienda una acción concreta al usuario (rotar credencial, recrear VM).
