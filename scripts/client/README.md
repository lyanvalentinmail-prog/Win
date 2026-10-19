# scripts/client — del lado del usuario, no de la VM

Estos scripts se ejecutan en **tu equipo** (portatil de Windows, o el host que hace de salto).
Ninguno cambia nada dentro de la VM.

| Script | Cuando | Que toca |
| --- | --- | --- |
| `Configurar-ClienteWindowsApp.ps1` | primera conexion y cada cambio de red | HKCU del cliente, energia del adaptador, `.rdp` opcional |
| `Test-ConexionRemota.ps1` | ante "va lento" o "no conecta" | solo red: TCP/UDP, RTT, jitter, perdida, MTU, TLS |
| `Montar-TunelSSH.ps1` | si no abres el 3389 (modo recomendado) | levanta el tunel y escribe un `.rdp` a 127.0.0.1 |
| `Preparar-MandoAndroide.ps1` | antes de jugar desde el movil | nada: emite la lista de comprobaciones reales |
| `Perfiles-Moonlight-Cliente.md` | montar los controles tactiles | documentacion, no ejecucion |

```powershell
# Ejemplo: desde el portatil, con la VM detras de un salto
.\Test-ConexionRemota.ps1 -Hostname vm.midominio.tls
.\Montar-TunelSSH.ps1 -Salto 'azureuser@20.30.40.50' -DestinoVM '10.20.1.4:3389'
.\Configurar-ClienteWindowsApp.ps1 -Hostname 127.0.0.1 -CrearRdp
```

## Que NO hacen (y por que)

- **No redirigen mandos ni crean controles tactiles**: Windows App no lo permite. El mando
  virtual y el overlay tactil viven en el cliente Moonlight (o en Steam Link), y se preparan
  en el propio dispositivo; `Preparar-MandoAndroide.ps1` lo que hace es decirte que opciones
  tocar y que limites tiene.
- **No optimizan la VM**: eso es `scripts/win/Set-GamingOptimizations.ps1`.
- **No bajan la latencia por arte de magia**: miden y evitan modos de ahorro de energia;
  la RTT la manda la distancia fisica y la ruta.
- **No escriben en HKLM** ni piden elevacion: si necesitas politicas de maquina, aplica
  los ficheros `.rdp` del servidor o la GPO descrita en `docs/05-acceso-remoto.md`.
