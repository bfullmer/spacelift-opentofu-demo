output "release_name" {
  description = "Generated release identifier for this environment."
  value       = random_pet.release_name.id
}

output "service_port" {
  description = "Port assigned to this release."
  value       = random_integer.port.result
}

output "manifest_path" {
  description = "Path of the rendered release manifest."
  value       = local_file.release_manifest.filename
}
