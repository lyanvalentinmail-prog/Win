# Reglas compartidas por los modulos de infra/.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

rule "terraform_naming_convention" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

# No hay plugin de azurerm/aws en el runner sin red al registry de tflint: las
# comprobaciones especificas de proveedor se hacen con `terraform validate`.
