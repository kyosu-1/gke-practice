variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "asia-northeast1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "asia-northeast1-a"
}

variable "github_repo" {
  description = "GitHub repository (owner/repo format)"
  type        = string
  default     = "kyosu-1/gke-practice"
}
