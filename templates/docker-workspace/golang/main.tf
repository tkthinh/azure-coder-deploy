terraform {
  required_providers {
    coder  = { source = "coder/coder" }
    docker = { source = "kreuzwerker/docker" }
  }
}

# Default: local Docker socket. If your Docker is remote, replace with a fixed URI.
# Example TCP: host = "tcp://10.0.0.5:2375"
# Example SSH: host = "ssh://ubuntu@docker-host"
provider "docker" {
  # host = "unix:///var/run/docker.sock"
}

provider "coder" {}

data "coder_workspace" "me" {}

# --- Text input: Git repository to clone ---
data "coder_parameter" "repo_url" {
  name         = "repo_url"
  display_name = "Git repository to clone"
  description  = "HTTPS or SSH URL (leave blank to use an empty workspace)"
  type         = "string"
  form_type    = "input"
  default      = "https://github.com/tkthinh/empty.git"
  # Optional: simple URL-ish guardrail (still allows blank)
  validation {
    regex = "^(|git@[^\\s]+\\.git|https?://[^\\s]+)$"
    error = "Enter a valid HTTPS or SSH Git URL, or leave blank."
  }
}

locals {
  # EDIT HERE: use your prebuilt org image (recommended) or an official runtime
  image        = "golang:1.25.3-trixie"
  ws_id        = data.coder_workspace.me.id
  ws_name      = lower(data.coder_workspace.me.name)
  project_root = "/home"

  repo_url             = trim(data.coder_parameter.repo_url.value, " ")
  placeholder_repo_url = "https://github.com/tkthinh/empty.git"
  effective_repo_url   = trim(local.repo_url, " ") != "" ? local.repo_url : (trim(local.placeholder_repo_url, " ") != "" ? local.placeholder_repo_url : "")
  do_git_clone         = trim(local.effective_repo_url, " ") != ""
}

resource "coder_agent" "dev" {
  os   = "linux"
  arch = "amd64"
  dir = "/home/workspace"

  startup_script_behavior = "non-blocking"

  # Handy dashboard telemetry
  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }
}

resource "coder_script" "oh_my_posh" {
  agent_id           = coder_agent.dev.id
  display_name       = "Setup Oh My Posh"
  run_on_start       = true
  start_blocks_login = true
  script             = templatefile("${path.module}/scripts/install-theme.sh", {})
}

# resource "coder_script" "vscode_exts" {
#   agent_id             = coder_agent.dev.id
#   display_name         = "Install VS Code Desktop extensions"
#   run_on_start         = true
#   start_blocks_login   = false 
#   script               = file("${path.module}/scripts/install-vscode-exts.sh")
#   # Optional ordering if you rely on other scripts first:
#   # depends_on         = [coder_script.oh_my_posh]
# }


resource "docker_volume" "home" {
  name = "coder-${local.ws_id}-home"
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count

  image    = local.image
  name     = "coder-${local.ws_id}"
  hostname = local.ws_name

  command = ["sh", "-c", coder_agent.dev.init_script]
  env     = ["CODER_AGENT_TOKEN=${coder_agent.dev.token}"]

  volumes {
    volume_name    = docker_volume.home.name
    container_path = "/home"
  }
}

module "code-server" {
  count   = data.coder_workspace.me.start_count
  source  = "registry.coder.com/coder/code-server/coder"
  version = "~> 1.0"

  agent_id = coder_agent.dev.id
  order    = 1
}

module "git-clone" {
  count   = data.coder_workspace.me.start_count == 0 || !local.do_git_clone ? 0 : 1
  source  = "registry.coder.com/coder/git-clone/coder"
  version = "1.2.0"

  agent_id = coder_agent.dev.id

  # Where to clone
  base_dir = local.project_root
  url      = local.effective_repo_url
  folder_name = "workspace"
}
