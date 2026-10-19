## Que cambia

- [ ] Config / JSON Schemas
- [ ] Scripts de Windows (PowerShell)
- [ ] Infraestructura (Terraform)
- [ ] Catalogo de apps / selecciones
- [ ] Perfiles de control / layouts tactiles
- [ ] Documentacion

## Honestidad funcional (obligatorio)

<!-- Marca solo lo que de verdad has probado. Si no has ejecutado nada en una VM,
     escribelo: el proyecto prefiere un "no verificado" a una promesa vacia. -->

- [ ] `python scripts/validate/validate.py` pasa
- [ ] `python -m pytest` pasa
- [ ] Ejecutado en una VM Windows real (indica edicion/SKU y fase probada)
- [ ] Ningun texto del repo promete tactil universal, mando via Windows App, GPU sin GPU,
      rendimiento de cloud gaming, VM gratuita ni soporte oficial de Microsoft para gaming en Server

## Seguridad

- [ ] Sin credenciales, tokens, SAS, .pfxtfvars, ni estados de Terraform
- [ ] Ningun servicio expuesto sin lista de control de acceso; `allowedCidrs` nunca `0.0.0.0/0`
- [ ] Fuentes de instalacion nuevas anadidas a `apps/sources.json` y verificadas en el snapshot
- [ ] Nada que desactive Defender o borre los backups de registro

## Docs

- [ ] `README.md` / `docs/` / `CHANGELOG.md` actualizados
- [ ] Limites del proveedor/edicion documentados donde corresponde

Closes #
