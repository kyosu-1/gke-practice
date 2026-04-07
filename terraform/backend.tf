terraform {
  required_version = ">= 1.14.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.26"
    }
  }

  backend "gcs" {
    bucket = "<YOUR_PROJECT_ID>-tfstate"
    prefix = "gke-practice"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
