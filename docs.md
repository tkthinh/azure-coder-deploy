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
    - Connect as the Azure admin (server-qualified username) over SSL and create DB/user/grants:

        ```bash
          # Create database
          psql "host=$PGHOST port=5432 dbname=postgres user=pgadmin@coder-pg-db sslmode=require" \
            -c "CREATE DATABASE coder;"

          # Create app user and apply grants inside the 'coder' DB
          psql "host=$PGHOST port=5432 dbname=coder user=pgadmin@coder-pg-db sslmode=require" \
            -c "CREATE USER coder_user WITH PASSWORD 'userpw';"

          # You initially granted everything:
          # psql ".../coder ..." -c "GRANT ALL PRIVILEGES ON DATABASE coder TO coder_user;"

          # Effective minimal grants you finalized:
          psql "host=$PGHOST port=5432 dbname=coder user=pgadmin@coder-pg-db sslmode=require" \
            -c "GRANT CONNECT ON DATABASE coder TO coder_user;"
          psql "host=$PGHOST port=5432 dbname=coder user=pgadmin@coder-pg-db sslmode=require" \
            -c "GRANT USAGE, CREATE ON SCHEMA public TO coder_user;"
        ```

## Step 3: Obtain TLS Certificates with Let’s Encrypt

1. **Generate Certificates**:
   Install Nginx + Certbot (Cloudflare plugin): for `yourdomain.com`:

    ```bash
    sudo apt-get update
    sudo apt-get install -y nginx certbot python3-certbot-dns-cloudflare
    ```

    - Follow prompts (provide email, agree to terms).
    - Certificates are saved to `/etc/letsencrypt/live/yourdomain.com/`.

2. **Store Cloudflare token**:

    ```bash
    mkdir -p ~/.secrets/certbot
    printf "dns_cloudflare_api_token = %s\n" "YOUR_CF_TOKEN" > ~/.secrets/certbot/cloudflare.ini
    chmod 600 ~/.secrets/certbot/cloudflare.ini
    ```

3. **Request wildcard cert (root + wildcard)**:

    ```bash
    sudo certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
    -d coder.mydomain.com -d '*.coder.mydomain.com'
    ```

    Certificates: /etc/letsencrypt/live/coder.mydomain.com/

4. **Nginx reverse proxy to Coder on localhost:3000**:

    ```bash
    sudo bash -c 'cat >/etc/nginx/sites-available/coder.mydomain.com' <<'NGINX'
    ```

    Config:

    ```bash
    server {
    server_name coder.mydomain.com *.coder.mydomain.com;

    listen 80;
    listen [::]:80;
    return 301 https://$host$request_uri;
    }

    server {
    server_name coder.mydomain.com *.coder.mydomain.com;

    listen 443 ssl http2;
    listen [::]:443 ssl http2;

    ssl_certificate /etc/letsencrypt/live/coder.mydomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/coder.mydomain.com/privkey.pem;

    location / {
    proxy_pass http://127.0.0.1:3000
    ;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
    }
    }
    NGINX

    sudo ln -sf /etc/nginx/sites-available/coder.mydomain.com /etc/nginx/sites-enabled/
    sudo nginx -t && sudo systemctl reload nginx
    ```

5. **Certificate/key permissions (Nginx mode)**  
   Keep Let’s Encrypt defaults; no extra exposure to the `coder` user is required:

-   `fullchain.pem`: typically `0644` root:root
-   `privkey.pem`: `0600` root:root

6. Renewal hook (reload Nginx when certs renew):

````bash
sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh > /dev/null << 'EOF'
#!/bin/bash
systemctl reload nginx
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
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

1.1. **Create Configuration File**:

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

1.2. **Create Env File**:

    ```bash
    sudo mkdir -p /etc/coder.d
    sudo tee /etc/coder.d/coder.env > /dev/null << EOF
    CODER_PG_CONNECTION_URL=postgresql://coder_user:${PG_PASSWORD}@coder-pg-db.postgres.database.azure.com/coder?sslmode=require
    CODER_EXTERNAL_AUTH_0_ID=primary-github
    CODER_EXTERNAL_AUTH_0_TYPE=github
    CODER_EXTERNAL_AUTH_0_CLIENT_ID=${GITHUB_CLIENT_ID}
    CODER_EXTERNAL_AUTH_0_CLIENT_SECRET=${GITHUB_CLIENT_SECRET}

    ARM_CLIENT_ID=${ARM_CLIENT_ID}
    ARM_CLIENT_SECRET=${ARM_CLIENT_SECRET}
    ARM_TENANT_ID=${ARM_TENANT_ID}
    ARM_SUBSCRIPTION_ID=${ARM_SUBSCRIPTION_ID}

    #CODER_OAUTH2_GITHUB_CLIENT_ID=${GITHUB_CLIENT_ID}
    #CODER_OAUTH2_GITHUB_CLIENT_SECRET=${GITHUB_CLIENT_SECRET}
    #CODER_OAUTH2_GITHUB_ALLOW_SIGNUPS=true
    #CODER_OAUTH2_GITHUB_ALLOW_EVERYONE=true
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
```

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
