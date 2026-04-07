output "cluster_endpoint" {
  value     = google_container_cluster.main.endpoint
  sensitive = true
}

output "cluster_name" {
  value = google_container_cluster.main.name
}

output "artifact_registry_url" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.main.repository_id}"
}

output "github_actions_sa_email" {
  value = google_service_account.github_actions.email
}

output "workload_identity_provider" {
  value = google_iam_workload_identity_pool_provider.github.name
}
