output "dns_publico" {
  value = aws_instance.win.public_dns
}

output "ip_publica" {
  value = aws_instance.win.public_ip
}

output "id_instancia" {
  value = aws_instance.win.id
}

output "obtener_contrasena_inicial" {
  description = "La contrasena se recupera con tu clave privada, NUNCA se guarda en el repo ni en outputs."
  value       = join(" ", [
    "aws ec2 get-password-data --instance-id", aws_instance.win.id,
    "--priv-launch-key ~/.ssh/", var.key_name, ".pem"
  ])
}

output "siguiente_paso" {
  value = <<-EOT
    1) Espera a que la instancia esté 'running' y el estado de chequeo 2/2:
         aws ec2 describe-instances --instance-ids $(terraform output -raw id_instancia) --query 'Reservations[0].Instances[0].State.Name'
    2) Entrega el bootstrap por SSM (sin abrir puertos) o por RDP:
         aws ssm send-command --document-name "AWS-RunPowerShellScript" \
           --instance-ids i-xxxx --commands "powershell -noprofile -executionpolicy bypass -file C:/ProgramData/WinGamingVM/Bootstrap-GamingVM.ps1"
    3) Copia config/vm.json (sin credenciales) a C:/ProgramData/WinGamingVM/config/vm.json antes del paso 2.
  EOT
}
