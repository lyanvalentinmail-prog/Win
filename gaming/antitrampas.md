# Antitrampas y máquinas virtuales: lo que hay que saber antes de instalar un juego

Esto **no es una recomendación para eludir sistemas anticheat** (eso violaría los
términos del juego y puede costarte la cuenta). Es la lista de comprobación que el
proyecto aplica para *no instalarte* algo que no va a funcionar en una VM.

## Cómo lo comprueba cada bootstrap

`scripts/win/Test-GamingReadiness.ps1` ejecuta `Get-AntiCheatRisk` (dentro del módulo
`GamingVM`), que:

1. Lee `gaming/profiles/*.json` y agrupa los juegos por `antitrampas.vm`.
2. Busca en la máquina clientes con componente de kernel instalado
   (`EAC.sys`, `BEDaisy.sys`, `vgk.sys`, `RiotKernelDrivers`): si existen y la VM es de
   nube, el informe marca `ADVERTENCIA`.
3. Comprueba si la VM corre con anidación de hipervisor / VBS habilitada
   (`Win32_ComputerSystem.HypervisorPresent`, `MEMORYCTLPOLICY` de `Win32_DeviceGuard`):
   algunos antichats interpretan esto como entorno hostil.
4. Escribe el resultado en `C:\ProgramData\WinGamingVM\informes\antichat.md` y lo devuelve
   en el JSON de estado.

## Clasificación usada en los perfiles

| Valor | Significado | Qué hace el instalador |
|---|---|---|
| `permitida` | El fabricante permite VM o el juego no tiene antichat de kernel. | Instala y configura. |
| `restringida` | Política explícita contraria a VM/hypervisor (p. ej. Vanguard, o "rechazo expreso de hipervisores"). | **No instala el perfil de control**, avisa y registra el motivo. |
| `desconocida` | Sin evidencia oficial. | Instala, pero pide confirmación explícita (`-PermitirDesconocidos`). |

## Puntos que se repiten en los foros y que son reales

- **Riot Vanguard (Valorant, League of Legends PC con Vanguard):** requiere
  arranque seguro y **no soporta máquinas virtuales**. El juego no arranca; insistir
  puede acabar en baneos por "intento de evasión de VM".
- **Easy Anti-Cheat / BattlEye en modo kernel:** en muchos títulos rechazan
  hipervisores activos o entornos con drivers sin firma. Cada juego decide.
- **VAC (Valve):** históricamente funciona en VM, porque no exige driver de kernel.
  Sigue siendo responsabilidad tuya cumplir sus términos.
- **Antichats solo de servidor** (Minecraft multiplayer con plugins, la mayoría de
  juegos single-player): no hay problema de VM.
- **Xbox App / PC Game Pass en VM:** la capa de DRM/Windows Sandbox puede rechazar
  entornos virtualizados para juegos concretos.
- **Juegos UWP/Store** requieren la Microsoft Store, ausente en Windows Server.

## La política de este repositorio

1. No se distribuyen parches, ni spoof de `VMware/Supermicro`, ni desactivación de
   seguridad del hypervisor. Nunca.
2. Si un juego está marcado `restringida`, el proyecto **no lo instala** y documenta la
   alternativa (GeForce NOW, Xbox Cloud, PC local).
3. Si decides probar un juego `desconocida`, lo haces bajo tu cuenta y sus términos:
   el log de la VM queda como registro de qué se configuró y cuándo.
