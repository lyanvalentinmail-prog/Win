# Soporte

Este es un proyecto personal, sin equipo y sin SLA. Lo que puedes esperar con honestidad:

| Canal | Para | Expectativa |
| --- | --- | --- |
| [Discussions](https://github.com/lyanvalentinmail-prog/Win/discussions) | dudas de uso, ajustes de latencia, experiencias por proveedor/región, compartir perfiles | respuesta cuando la vea (días) |
| [Issues](../../issues/new/choose) | un bug reproducible con comando + salida, o una mejora concreta | triage con etiqueta; un fix no está garantizado |
| Aviso privado de seguridad | algo que exponga a tu VM o a otros usuarios | ver `SECURITY.md` (3/14 días) |
| PR | algo que ya has probado en una VM real y validado con `scripts/validate/validate.py` | se revisa; si toca catálogo, se piden las verificaciones de fuentes |

## Antes de pedir ayuda

1. Ejecuta el validador en tu copia: `python scripts/validate/validate.py --verbose`.
2. Entra en la VM y ejecuta `scripts/win/Test-GamingReadiness.ps1`: el informe dice qué está
   aplicado, qué no y **por qué**. La mitad de las dudas se resuelven ahí.
3. Mira el checklist de `docs/11-prueba-de-aceptacion.md` y dime qué items están sin marcar.
4. Indica siempre: proveedor + SKU + región, `windows.edition`, `remote.tipo` y
   `gaming.channel`, versión del repo (`cat VERSION`) y cliente (dispositivo + Windows App o
   Moonlight + red).

## Lo que no se va a resolver desde aquí

- "Monta tú la VM por mí" (implica tus credenciales y tu facturación).
- "Consigue que el juego X con antichat de kernel funcione en la VM": no se hace, y el
  proyecto no da ayuda para eludirlo (`gaming/antitrampas.md`).
- "¿Puedo usar esto para dar acceso a 20 personas?" — la arquitectura es de una persona; se
  puede discutir el diseño, pero no existe un modo multiusuario soportado hoy.
- Precios y disponibilidad: los fija tu proveedor; el repo no puede saber tu cuota ni tu
  catálogo regional.
