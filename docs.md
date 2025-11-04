# Installing Coder Server on an Azure VM with Private PostgreSQL

This guide provides a complete, error-free process to install and configure the Coder server (`coderd`) on an Azure VM (Ubuntu) with a private Azure Database for PostgreSQL Flexible Server as the control-plane database. The setup ensures the Coder Web UI is accessible at `https://yourdomain.com` and uses a private PostgreSQL instance for production-grade reliability.

## Prerequisites

-   **Azure VM**:
    -   Ubuntu 20.04 or later (e.g., `Standard_D2s_v3`).
    -   Public IP address assigned.
    -   DNS name: `yourdomain.com`.
    -   Part of a Virtual Network (e.g., `coder-vm-vnet`) with a Network Security Group (e.g., `coder-vm-nsg`).
-   **User Access**: SSH access with `sudo` privileges (e.g., `azureuser`).
-   **Tools**: `curl`, `certbot`, `postgresql-client` (installed below).
-   **Azure CLI**: Optional for managing Azure resources.
-   **Azure Subscription**: Access to create a PostgreSQL Flexible Server.

## Step 1: Set Up Azure Networking

Configure the Azure Network Security Group (NSG) and Virtual Network (VNet) to ensure connectivity for Coder and PostgreSQL.

1. **Verify Public IP and DNS**:

    - In the Azure Portal, go to your VM > Overview.
    - Note the public IP address.
    - Ensure the DNS name is set to `yourdomain.com`:
    - Verify DNS resolution:
        ```bash
        dig yourdomain.com
        ```
        Confirm the resolved IP matches the VM’s public IP (`curl -s ifconfig.me`).

2. **Configure NSG Rules**:

    - Add inbound rules for TCP 80 (HTTP), TCP 443 (HTTPS), and UDP 3478/19302 (STUN for DERP).
    - Add an outbound rule for TCP 5432 (PostgreSQL) to allow VM-to-database connectivity.
    - In the Azure Portal: VM > Networking > Inbound port rules > Add:
        - **Rule 1**: Protocol: TCP, Source: Any, Destination: Any, Port: 80, Action: Allow, Priority: 100, Name: AllowHTTP.
        - **Rule 2**: Protocol: TCP, Source: Any, Destination: Any, Port: 443, Action: Allow, Priority: 101, Name: AllowHTTPS.
        - **Rule 3**: Protocol: UDP, Source: Any, Destination: Any, Port: 3478,19302, Action: Allow, Priority: 102, Name: AllowSTUN.
    - Outbound rule: VM > Networking > Outbound port rules > Add:
        - Protocol: TCP, Source: Any, Destination: Any, Port: 5432, Action: Allow, Priority: 103, Name: AllowPostgres.

3. **Create a Dedicated Subnet for PostgreSQL**:
    - In the Azure Portal, go to Virtual networks > `coder-vm-vnet` > Subnets > + Subnet.
    - Settings:
        - Name: `pg-subnet`
        - Address range: `10.0.2.0/24` (adjust if needed, must not overlap with other subnets).
        - Subnet delegation: `Microsoft.DBforPostgreSQL/flexibleServers`.
        - Service endpoints: Leave off.
    - Save the subnet.

## Step 2: Create Azure PostgreSQL Flexible Server

1. **Create the Server**:

    - In the Azure Portal: Create a resource > Azure Database for PostgreSQL flexible server > Create.
    - **Basics**:
        - Server name: `pg-coder-db`
        - Region: Same as the Coder VM (e.g., Southeast Asia).
        - Admin username: `pgadmin`
        - Password: `StrongPassword!` (save this securely).
        - Compute tier: `Development` (e.g., Burstable, B1ms for testing; scale later).
    - **Networking**:
        - Connectivity method: **Private access (VNet Integration)**.
        - Virtual network: `coder-vm-vnet`.
        - Subnet: `pg-subnet`.
        - Private DNS zone: Create a new one (e.g., `pg-coder-db.privatelink.postgres.database.azure.com`).
        - Public access: **Disabled**.
    - Review + create. Wait for deployment (5-10 minutes).

2. **Verify Connectivity from VM**:
    - SSH into the VM.
    - Test DNS and connectivity:
        ```bash
        PGHOST="pg-coder-db.postgres.database.azure.com"
        nslookup $PGHOST  # Should resolve to a private 10.x.x.x address
        nc -vz $PGHOST 5432  # Should succeed
        ```
    - If it fails:
        - Ensure the VM and DB are in the same VNet (or peered VNets).
        - Verify the NSG allows outbound TCP 543.

## Step 3: Obtain TLS Certificates with Let’s Encrypt

1. **Generate Certificates**:
   Use Certbot in standalone mode to get certificates for `yourdomain.com`:

    ```bash
    sudo certbot certonly --standalone -d yourdomain.com
    ```

    - Follow prompts (provide email, agree to terms).
    - Certificates are saved to `/etc/letsencrypt/live/yourdomain.com/`.

2. **Copy Certificates for Coder**:

    ```bash
    sudo mkdir -p /etc/coder/certs
    sudo cp /etc/letsencrypt/live/yourdomain.com/fullchain.pem /etc/coder/certs/
    sudo cp /etc/letsencrypt/live/yourdomain.com/privkey.pem /etc/coder/certs/
    sudo chown coder:coder /etc/coder/certs/fullchain.pem /etc/coder/certs/privkey.pem
    sudo chmod 644 /etc/coder/certs/fullchain.pem
    sudo chmod 640 /etc/coder/certs/privkey.pem
    ```

3. **Set Up Certificate Renewal**:
   Create a renewal hook to update certs and restart Coder:

    ```bash
    sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    sudo tee /etc/letsencrypt/renewal-hooks/deploy/restart-coder.sh > /dev/null << EOF
    #!/bin/bash
    cp /etc/letsencrypt/live/yourdomain.com/fullchain.pem /etc/coder/certs/
    cp /etc/letsencrypt/live/yourdomain.com/privkey.pem /etc/coder/certs/
    chown coder:coder /etc/coder/certs/fullchain.pem /etc/coder/certs/privkey.pem
    chmod 644 /etc/coder/certs/fullchain.pem
    chmod 640 /etc/coder/certs/privkey.pem
    systemctl restart coder
    EOF
    sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-coder.sh
    ```

    Test renewal:

    ```bash
    sudo certbot renew --dry-run
    ```

## Step 4: Install Coder Server

1. **Run the Install Script**:
   Install the latest stable Coder release:

    ```bash
    curl -L https://coder.com/install.sh | sh
    ```

2. **Verify Installation**:
    ```bash
    coder version
    ```
    Ensure the binary is at `/usr/bin/coder`:
    ```bash
    which coder
    ```

## Step 5: Configure Coder with YAML

1. **Create Configuration File**:

    ```bash
    sudo mkdir -p /etc/coder.d
    sudo tee /etc/coder.d/coder.yaml > /dev/null << EOF
    networking:
      accessURL: https://yourdomain.com
      http:
        httpAddress: 0.0.0.0:80
        sessionDuration: 24h
        proxyHealthInterval: 1m
      tls:
        enable: true
        address: 0.0.0.0:443
        certFiles:
          - /etc/coder/certs/fullchain.pem
        keyFiles:
          - /etc/coder/certs/privkey.pem
      secureAuthCookie: true
      browserOnly: false
      derp:
        enable: true
        regionID: 1001
        regionCode: sg
        regionName: 'Azure-SG DERP'
        stunAddresses:
          - 'stun.l.google.com:19302'
          - 'stun1.l.google.com:19302'
        blockDirect: false
    EOF
    ```

2. **Set Permissions**:
    ```bash
    sudo chown coder:coder /etc/coder.d/coder.yaml
    sudo chmod 644 /etc/coder.d/coder.yaml
    ```

## Step 6: Configure Systemd Service

1. **Create an Empty `coder.env`**:
   The default `coder.service` requires a non-empty `/etc/coder.d/coder.env`, but since we’re using YAML, an empty file suffices:

    ```bash
    sudo touch /etc/coder.d/coder.env
    sudo chown coder:coder /etc/coder.d/coder.env
    sudo chmod 600 /etc/coder.d/coder.env
    ```

2. **Override Systemd Service**:

    ```bash
    sudo EDITOR=vim systemctl edit coder
    ```

    Set the contents to:

    ```
    [Service]
    ExecStart=
    ExecStart=/usr/bin/coder server --config /etc/coder.d/coder.yaml
    [Unit]
    ConditionFileNotEmpty=
    ```

3. **Reload Systemd**:

    ```bash
    sudo systemctl daemon-reload
    ```

4. **Verify Service Configuration**:
    ```bash
    systemctl cat coder
    ```
    Ensure the override appears:
    ```
    # /usr/lib/systemd/system/coder.service
    ...
    ExecStart=/usr/bin/coder server
    ...
    # /etc/systemd/system/coder.service.d/override.conf
    [Unit]
    Description=Coder Server
    After=network.target
    ConditionFileNotEmpty=
    ```

[Service]
ExecStart=
ExecStart=/usr/bin/coder server --config=/etc/coder.d/coder.yaml
Restart=always
User=coder
Environment= CODER_CONFIG_PATH=/etc/coder.d/coder.yaml

[Install]
WantedBy=multi-user.target

````

## Step 7: Start and Enable Coder Service
1. **Start the Service**:
```bash
sudo systemctl start coder
````

2. **Enable on Boot**:

    ```bash
    sudo systemctl enable coder
    ```

3. **Check Status**:

    ```bash
    sudo systemctl status coder
    ```

    Expected: `Active: active (running)`.

4. **Monitor Logs**:
    ```bash
    journalctl -u coder -f
    ```
    Look for:
    ```
    Started HTTP listener at http://0.0.0.0:80
    Started TLS/HTTPS listener at https://0.0.0.0:443
    View the Web UI: https://yourdomain.com
    ```

## Step 8: Install Docker

1. **Uninstall old version**:

    ```bash
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do sudo apt-get remove $pkg; done
    ```

2. **Set up repository**:

    ```bash
    # Add Docker's official GPG key:
     sudo apt-get update
     sudo apt-get install ca-certificates curl
     sudo install -m 0755 -d /etc/apt/keyrings
     sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
     sudo chmod a+r /etc/apt/keyrings/docker.asc

     # Add the repository to Apt sources:
     echo \
     "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
     $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
     sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
     sudo apt-get update
    ```

3. **Install Docker packages**:

    ```bash
    sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ```

4. **Start Docker**:

    ```bash
    sudo systemctl status docker
    ```

5. **Add coder to docker**:
    ```bash
    sudo usermod -aG docker coder
    chmod 666 /var/run/docker.sock
    ```

## Step 9: Verify Access

1. **Local Test**:

    ```bash
    curl http://localhost
    curl -k https://localhost
    ```

    Both should return HTML or redirect to HTTPS.

2. **External Test**:
   Open `https://yourdomain.com` in a browser.

    - You should see the Coder login/registration page.
    - Create an admin user by following the prompts.

3. **Check Ports**:
    ```bash
    sudo netstat -tuln | grep '80\|443'
    ```
    Expected:
    ```
    tcp 0 0 0.0.0.0:80 0.0.0.0:* LISTEN
    tcp 0 0 0.0.0.0:443 0.0.0.0:* LISTEN
    ```
