locals {
  resource_level = var.org_integration ? "ORGANIZATION" : "PROJECT"
  resource_id    = var.org_integration ? var.organization_id : module.lacework_cfg_svc_account.project_id
  project_id     = data.google_project.selected.project_id
  exclude_folders = length(var.folders_to_exclude) != 0
  service_account_name = var.use_existing_service_account ? (
    var.service_account_name
    ) : (
    length(var.service_account_name) > 0 ? var.service_account_name : "${var.prefix}-${random_id.uniq.hex}"
  )
  service_account_json_key = jsondecode(var.use_existing_service_account ? (
    base64decode(var.service_account_private_key)
    ) : (
    base64decode(module.lacework_cfg_svc_account.private_key)
  ))
  default_project_roles = [
    "roles/browser",
    "roles/iam.securityReviewer",
    "roles/cloudasset.viewer"
  ]
  default_organization_roles = [
    "roles/browser",
    "roles/iam.securityReviewer",
    "roles/cloudasset.viewer"
  ]
  // if org_integration is false, project_roles = local.default_project_roles
  project_roles = var.org_integration ? [] : local.default_project_roles
  // if org_integration is true, organization_roles = local.default_organization_roles
  organization_roles = (var.org_integration && !local.exclude_folders) ? (
    local.default_organization_roles
    ) : (
    (var.org_integration && local.exclude_folders) ? (
      ["roles/resourcemanager.organizationViewer"]
      ) : (
      []
    )
  )
  default_folder_roles = (var.org_integration && local.exclude_folders) ? (
    [
      "roles/browser",
      "roles/iam.securityReviewer",
      "roles/cloudasset.viewer",
      google_organization_iam_custom_role.lacework_custom_organization_role.0.name
    ]
    ) : (
    []
  )
  folders = [
    (var.org_integration && local.exclude_folders) ? setsubtract(data.google_folders.my-org-folders[0].folders[*].name, var.folders_to_exclude) : toset([])
  ]
  root_projects = [
    (var.org_integration && local.exclude_folders) ? toset(data.google_projects.my-org-projects[0].projects[*].project_id) : toset([])
  ]
  folder_roles = (var.org_integration && local.exclude_folders) ? (
    setproduct(local.folders[0][*], local.default_folder_roles)
    ) : (
    []
  )
  root_project_roles = (var.org_integration && local.exclude_folders) ? (
    setproduct(local.root_projects[0][*], local.default_folder_roles)
    ) : (
    []
  )
}

resource "random_id" "uniq" {
  byte_length = 4
}

data "google_project" "selected" {
  project_id = var.project_id
}

module "lacework_cfg_svc_account" {
  source               = "lacework/service-account/gcp"
  version              = "~> 1.0"
  create               = var.use_existing_service_account ? false : true
  service_account_name = local.service_account_name
  project_id           = local.project_id
}

// Roles for a PROJECT level integration
resource "google_project_iam_custom_role" "lacework_custom_project_role" {
  project     = local.project_id
  role_id     = "lwComplianceRole_${random_id.uniq.hex}"
  title       = "Lacework Compliance Role"
  description = "Lacework Compliance Role"
  permissions = ["bigquery.datasets.get", "compute.projects.get", "pubsub.topics.get", "storage.buckets.get", "compute.sslPolicies.get"]
  count       = local.resource_level == "PROJECT" ? 1 : 0
}


resource "google_project_iam_member" "lacework_custom_project_role_binding" {
  project    = local.project_id
  role       = google_project_iam_custom_role.lacework_custom_project_role.0.name
  member     = "serviceAccount:${local.service_account_json_key.client_email}"
  depends_on = [google_project_iam_custom_role.lacework_custom_project_role]
  count      = local.resource_level == "PROJECT" ? 1 : 0
}

resource "google_project_iam_member" "for_lacework_service_account" {
  for_each = toset(local.project_roles)
  project  = local.project_id
  role     = each.value
  member   = "serviceAccount:${local.service_account_json_key.client_email}"
}

// Roles for an ORGANIZATION level integration

data "google_folders" "my-org-folders" {
  count     = (var.org_integration && local.exclude_folders) ? 1 : 0
  parent_id = "organizations/${var.organization_id}"
}

data "google_projects" "my-org-projects" {
  count  = (local.exclude_folders && var.include_root_projects) ? 1 : 0
  filter = "parent.id=${var.organization_id}"
}

resource "google_organization_iam_custom_role" "lacework_custom_organization_role" {
  role_id     = "lwOrgComplianceRole_${random_id.uniq.hex}"
  org_id      = var.organization_id
  title       = "Lacework Org Compliance Role"
  description = "Lacework Org Compliance Role"
  permissions = ["bigquery.datasets.get", "compute.projects.get", "pubsub.topics.get", "storage.buckets.get", "compute.sslPolicies.get"]
  count       = local.resource_level == "ORGANIZATION" ? 1 : 0
}

resource "google_organization_iam_member" "lacework_custom_organization_role_binding" {
  org_id     = var.organization_id
  role       = google_organization_iam_custom_role.lacework_custom_organization_role.0.name
  member     = "serviceAccount:${local.service_account_json_key.client_email}"
  depends_on = [google_organization_iam_custom_role.lacework_custom_organization_role]
  count      = (local.resource_level == "ORGANIZATION" && !local.exclude_folders) ? 1 : 0
}

resource "google_organization_iam_member" "for_lacework_service_account" {
  for_each = toset(local.organization_roles)
  org_id   = var.organization_id
  role     = each.value
  member   = "serviceAccount:${local.service_account_json_key.client_email}"
}

resource "google_folder_iam_member" "for_lacework_service_account" {
  count  = length(local.folder_roles)
  folder = local.folder_roles[count.index][0]
  role   = local.folder_roles[count.index][1]
  member = "serviceAccount:${local.service_account_json_key.client_email}"
}

resource "google_project_iam_member" "for_lacework_service_account_root_projects" {
  count   = length(local.root_project_roles)
  project = local.root_project_roles[count.index][0]
  role    = local.root_project_roles[count.index][1]
  member  = "serviceAccount:${local.service_account_json_key.client_email}"
}

resource "google_project_service" "required_apis" {
  for_each = var.required_config_apis
  project  = local.project_id
  service  = each.value

  disable_on_destroy = false
}

# wait for X seconds for things to settle down in the GCP side
# before trying to create the Lacework external integration
resource "time_sleep" "wait_time" {
  create_duration = var.wait_time
  depends_on = [
    module.lacework_cfg_svc_account,
    google_project_service.required_apis,
    google_organization_iam_member.for_lacework_service_account,
    google_project_iam_member.for_lacework_service_account
  ]
}

resource "lacework_integration_gcp_cfg" "default" {
  name           = var.lacework_integration_name
  resource_id    = local.resource_id
  resource_level = local.resource_level
  credentials {
    client_id      = local.service_account_json_key.client_id
    private_key_id = local.service_account_json_key.private_key_id
    client_email   = local.service_account_json_key.client_email
    private_key    = local.service_account_json_key.private_key
  }
  depends_on = [time_sleep.wait_time]
}
