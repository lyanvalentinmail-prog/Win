# Política de seguridad

## Alcance

Se consideran de seguridad: el acceso remoto a la VM (RDP/Windows App, Sunshine/Moonlight,
túneles), la verificación de origen de los instaladores, el manejo de credenciales y
configuración, y el aislamiento del host en la vía KVM.

**No** es un problema de seguridad del proyecto: que un proveedor no soporte gaming en
imágenes de Server, que un antichat bloquee la VM, que un SKU no tenga GPU, o que la licencia
de un driver requiera contrato. Eso son límites documentados (`docs/02`, `docs/06`,
`gaming/antitrampas.md`), no vulnerabilidades.

## Reportar

Abre un **aviso de seguridad privado** en GitHub (Security → Report a vulnerability) en lugar
de un issue público, especialmente si el informe incluye una IP, un DNS, un token o una
captura con tu configuración. Respuesta objetivo: 3 días laborables para confirmar, 14 para
un primer análisis con propuesta de mitigación.

Incluye: versión del repo (`cat VERSION`), proveedor y SKU, edición de Windows, qué fase o
script, y la salida relevante de los logs
(`C:\ProgramData\WinGamingVM\logs\*.log`, ya sin secretos).

## Lo que este proyecto hace por diseño

1. **Sin credenciales en el repositorio.** `.gitignore` excluye `config/vm.json`,
   `terraform.tfvars`, `*.tfstate`, `*.rdp`, `*.key`, `*.pfx` y los payloads de cloud-init;
   Terraform usa variables `sensitive` sin valor por defecto; el validador **falla** si
   aparece un patrón de contraseña, token o clave privada (`.github/workflows/validate.yml`).
2. **Ningún servicio expuesto sin control de acceso.** Las reglas de entrada (NSG de Azure,
   SG de AWS, firewall de Windows, reglas de Sunshine) se crean **solo** con CIDR declaradas.
   Sin CIDR y sin túnel declarado, las reglas de Windows se dejan **deshabilitadas** y el
   script explica cómo continuar. El validador convierte `0.0.0.0/0` en error.
3. **NLA y cifrado alto** (`UserAuthentication=1`, `SecurityLayer=1`, `MinEncryptionLevel=3`).
4. **Defender intacto.** Ninguna ruta del proyecto desactiva la protección en tiempo real;
   las exclusiones solo existen si las pides explícitamente y están limitadas por esquema y
   por una lista negra de servicios.
5. **Origen verificado.** Toda app se instala por winget desde un `id` declarado en el
   catálogo y descargada de un host de la lista blanca `apps/sources.json`; después de
   instalar se comprueba el firmante Authenticode del ejecutable declarado.
6. **Registro antes de escribir.** Cada clave de registro tocada se exporta a
   `<BaseDir>\backup\reg-backup-*.reg` y `Remove-GamingVM.ps1` puede restaurarla.
7. **Auditoría y caducidad de sesión**: `auditpol` para inicio de sesión y privilegios,
   `MaxIdleTime` y bloqueo por inactividad desde `security.*`.
8. **El acceso se prueba, no se asume**: `Test-GamingReadiness.ps1` revisa puertos en
   escucha, exposición real y coherencia `allowedCidrs` ↔ reglas, y sale con `2` si hay
   bloqueos.

## Lo que depende de ti (no lo puede resolver un repositorio)

- Una contraseña larga y única en la cuenta del proveedor y en el usuario de Windows.
- Un state de Terraform en un backend cifrado y con control de acceso (contiene la
  contraseña del administrador si la pasaste por ahí).
- Mantener el cliente Windows App/Moonlight actualizado y el túnel (Tailscale/Bastion/SSH)
  con autenticación fuerte y MFA.
- No usar la VM para servicios de terceros sin aislarla: es una máquina de una persona.
- En KVM: el host es tu responsabilidad (parches, IOMMU correcto, sin puertos
  redundantes en el bridge, `swtpm` protegido).

## Variantes no soportadas

Cualquier modificación que elimine la verificación de fuentes, que abra puertos sin CIDR o
que desactive las políticas de seguridad deja el proyecto fuera de soporte: si tienes un
escenario que lo exige (por ejemplo, acceso para varias personas), se discute primero en
`docs/12-ideas-evaluadas.md` y en un RFC del repo antes de escribir código.
