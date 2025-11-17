terraform {
  required_providers {
    coder  = { source = "coder/coder" }
    docker = { source = "kreuzwerker/docker" }
  }
}

locals {
  username = data.coder_workspace_owner.me.name
}

provider "coder" {}

# -------- Parameters users pick in Coder UI --------
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}
data "coder_provisioner" "me" {}

data "coder_parameter" "mode" {
  name        = "_Image Mode"
  description = "Choose how to provide the workspace image"
  type        = "string"
  default     = "build"
  option {
    name  = "Build from pasted Dockerfile"
    value = "build"
  }
  option {
    name  = "Pull from container registry"
    value = "pull"
  }
  mutable = false
}

# PASTED DOCKERFILE (used when mode == build)
data "coder_parameter" "dockerfile" {
  name        = "Dockerfile"
  description = "[BUILD-MODE] Paste a complete Dockerfile"
  type        = "string"
  # Ensure /home/workspace exists and is owned by the user  # <<<
  default     = <<-EOT
    FROM ubuntu:24.04
    RUN apt-get update && apt-get install -y sudo curl git && rm -rf /var/lib/apt/lists/*
    ARG USER=coder
    RUN useradd --groups sudo --no-create-home --shell /bin/bash $${USER} \
      && mkdir -p /home/$${USER} /home/workspace \
      && chown -R $${USER}:$${USER} /home/$${USER} /home/workspace \
      && echo "$${USER} ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/$${USER} && chmod 0440 /etc/sudoers.d/$${USER}
    USER $${USER}
    WORKDIR /home/workspace
  EOT

  validation {
    regex = ".*"
    error = "Dockerfile must not be empty"
  }
}

# REGISTRY PULL PARAMS (used when mode == pull)
data "coder_parameter" "image_name" {
  name        = "registry_image"
  description = "[PULL-MODE] Image reference (e.g., myacr.azurecr.io/team/node:20)"
  type        = "string"
  default     = "ubuntu:24.04"
}

data "coder_parameter" "registry_address" {
  name        = "registry_address"
  description = "[PULL-MODE] Registry server address (e.g., myacr.azurecr.io)"
  type        = "string"
  default     = ""
}

data "coder_parameter" "registry_username" {
  name        = "registry_username"
  description = "[PULL-MODE] Registry username (e.g., ACR admin or service principal appId)"
  type        = "string"
  default     = ""
}

data "coder_parameter" "registry_password" {
  name        = "registry_password"
  description = "[PULL-MODE] Registry password/secret"
  type        = "string"
  default     = ""
}

# -------- Providers --------
provider "docker" {
  dynamic "registry_auth" {
    for_each = data.coder_parameter.mode.value == "pull" && length(trimspace(data.coder_parameter.registry_address.value)) > 0 ? [1] : []
    content {
      address  = data.coder_parameter.registry_address.value
      username = data.coder_parameter.registry_username.value
      password = data.coder_parameter.registry_password.value
    }
  }
}

# -------- Coder agent & apps --------
resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"
  dir = "/home/workspace" 

  startup_script_behavior = "non-blocking"

  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
  }

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "RAM Usage"
    key          = "1_ram"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
}

# -------- Persistent home volume --------
resource "docker_volume" "home" {
  name = "coder-${data.coder_workspace.me.id}-home"
  lifecycle { ignore_changes = all }
}

# -------- Build or Pull the image --------
resource "local_file" "dockerfile" {
  count    = data.coder_parameter.mode.value == "build" ? 1 : 0
  filename = "${path.module}/build/Dockerfile"
  content  = data.coder_parameter.dockerfile.value
}

data "docker_registry_image" "upstream" {
  count = data.coder_parameter.mode.value == "pull" ? 1 : 0
  name  = data.coder_parameter.image_name.value
}

resource "docker_image" "workspace" {
  name = data.coder_parameter.mode.value == "pull" ? data.coder_parameter.image_name.value : "coder-${data.coder_workspace.me.id}"

  dynamic "build" {
    for_each = data.coder_parameter.mode.value == "build" ? [1] : []
    content {
      context    = "${path.module}/build"
      dockerfile = "Dockerfile"
      build_args = { USER = local.username }
    }
  }

  triggers = data.coder_parameter.mode.value == "build" ? {
    dockerfile_sha1 = sha1(data.coder_parameter.dockerfile.value)
  } : null

  pull_triggers = data.coder_parameter.mode.value == "pull" ? [data.docker_registry_image.upstream[0].sha256_digest] : null

  keep_locally = true
  depends_on   = [local_file.dockerfile]
}

resource "null_resource" "retag" {
  count = data.coder_parameter.mode.value == "pull" ? data.coder_workspace.me.start_count : 0

  triggers = {
    image_ref = data.coder_parameter.image_name.value
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      docker pull "${data.coder_parameter.image_name.value}"
      docker tag "${data.coder_parameter.image_name.value}" "${docker_image.workspace.name}:latest"
    EOT
  }
}

# -------- Run the workspace container --------
resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count

  image    = "${docker_image.workspace.name}:latest"
  name     = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  hostname = data.coder_workspace.me.name

  # Run the agent exactly like in your Python template  # <<<
  command = ["sh", "-c", coder_agent.main.init_script]
  env     = ["CODER_AGENT_TOKEN=${coder_agent.main.token}"]

  # Make Linux host discovery stable (optional but nice to have)
  # host {
  #   host = "host.docker.internal"
  #   ip   = "host-gateway"
  # }

  volumes {
    container_path = "/home"                 # <<< same as Python template
    volume_name    = docker_volume.home.name
    read_only      = false
  }
}

module "code-server" {
  count   = data.coder_workspace.me.start_count
  source  = "registry.coder.com/coder/code-server/coder"
  version = "~> 1.0"

  agent_id = coder_agent.main.id
  order    = 1
}
