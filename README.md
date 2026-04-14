# mTLS Authentication with GnuTLS

**Author:** Fulup Le Foll (fulup@iot.bzh)  
**License:** MIT  
**Date:** March 2026

---

## What is mTLS and why use it?

**TLS** (Transport Layer Security) typically authenticates only the **server** — it lets a client verify it's talking to the right server (e.g., via Let's Encrypt). However, it doesn't verify who the **client** is.

**mTLS** (mutual TLS) goes further: **both the server and the client authenticate each other** using X.509 certificates. This means:

- ✅ The client verifies the server's identity (like standard HTTPS)
- ✅ The server verifies the client's identity (only authorized devices/users can connect)
- 🔒 No password, no VPN, no token — just cryptographic proof of identity

This is ideal for **self-hosted services** (Home Assistant, Nextcloud, mail servers, etc.) where you want to ensure that only your own devices can access your infrastructure.

---

## Prerequisites

- **GnuTLS** (`certtool` command) must be installed on your system:

  ```bash
  # Fedora / RHEL / CentOS
  sudo dnf install gnutls-utils

  # Debian / Ubuntu
  sudo apt install gnutls-bin

  # Arch Linux
  sudo pacman -S gnutls
  ```

---

## Installation

Clone the repository and create your local configuration:

```bash
git clone https://github.com/Tux-Solar/mtls-gnutls-config.git
cd mtls-gnutls-config

# Create your personal config from the example
cp mkcerts.conf.example mkcerts.conf

# Edit mkcerts.conf with your organization details
```

> **Note:** `mkcerts.conf` is listed in `.gitignore` so your personal identity data is never committed. Only `mkcerts.conf.example` is versioned.

---

## Configuration

The script uses a centralized configuration system. You can have a global `mkcerts.conf` or prefix-specific overrides.

### 1. Centralized Identity (`mkcerts.conf`)

Edit this file once. These values are automatically injected into every certificate:

```bash
ORGANIZATION="MyCompany"
UNIT="IT Security"
STATE="Bretagne"
COUNTRY="FR"
UID_FIELD="admin"              # Owner of the CA
CA_CN="my-mtls-root-ca"
CA_EXPIRY_DAYS=36500          # ~100 years
SERVER_EXPIRY_DAYS=730        # 2 years
CLIENT_EXPIRY_DAYS=365        # 1 year
```

### 2. Prefix-specific Overrides

If you manage multiple separate PKIs, you can create a file named `mkcerts-{prefix}.conf` (e.g., `mkcerts-work.conf`). If it exists, the script will use it instead of the default `mkcerts.conf`.

---

## Usage Summary

The script follows a `command <prefix> [options]` pattern.

### Core Commands

| Command | Description |
|:---|:---|
| `init <prefix>` | Initialize the Root CA for this prefix. |
| `add-server <prefix> <host>` | Generate a server certificate (host can be DNS or IP). |
| `add-client <prefix> <name>` | Generate a client certificate for a specific user/device. |
| `all <prefix> <host> [user]` | Shortcut: Run init + add-server + add-client in one go. |

### Management Commands

| Command | Description |
|:---|:---|
| `list <prefix>` | List all certificates generated for this prefix. |
| `info <prefix> <name>` | Show full X.509 details for a specific certificate. |
| `check-expiry <prefix> [days]` | List certificates expiring within N days (default: 90). |
| `revoke <prefix> <name>` | Revoke a certificate and generate a CRL. |
| `deploy <prefix> <host> <user@remote> [path]` | Copy server certs to a remote host via scp. |

### Flags & Options

- `--force`: Add this before the command to overwrite existing files without asking.
- `PASSWORD=xxx`: Set the password for client `.pfx` files (default: `9876543210`).

---

## Step-by-Step Guide

### 1. Initialize your CA
```bash
./mkcerts.sh init myinfra
```

### 2. Add a Server
The script automatically detects if you provide an IP or a DNS and sets `ip_address` or `dns_name` correctly. It also gives the server its own unique `uid`.
```bash
./mkcerts.sh add-server myinfra home.example.com
./mkcerts.sh add-server myinfra 192.168.1.50
```

### 3. Add a Client
Each client gets a unique certificate with its own `uid`.
```bash
PASSWORD=StrongPass ./mkcerts.sh add-client myinfra phone-sylvain
```

### 4. Manage and Verify
```bash
./mkcerts.sh list myinfra
./mkcerts.sh check-expiry myinfra 30
```

---

## Deployment

### Nginx Configuration

Copy the `.crt` (full chain) and `.key` to your server.

```nginx
server {
    listen 443 ssl;
    server_name home.example.com;

    # Server Identity
    ssl_certificate     /etc/nginx/certs/myinfra-server-home-example-com.crt;
    ssl_certificate_key /etc/nginx/certs/myinfra-server-home-example-com.key;

    # mTLS Authentication
    ssl_client_certificate /etc/nginx/certs/myinfra-root.pem;
    ssl_verify_client on;

    # Optional: CRL (Revocation List)
    # ssl_crl /etc/nginx/certs/myinfra-crl.pem;
}
```

### HAProxy Configuration (Centralized mTLS)

HAProxy is ideal for centralizing mTLS and CRL management. You only need to update the CRL in one place.

```haproxy
frontend https-in
    bind *:443 ssl crt /etc/ssl/certs/home.example.com.pem ca-file /etc/ssl/ca/myinfra-root.pem verify required crl-file /etc/ssl/ca/myinfra-crl.pem

    # Pass the client's Subject DN (containing the unique UI) to the backend
    http-request set-header X-SSL-Client-DN %[ssl_c_s_dn]
    
    # Pass specifically the UID if needed
    http-request set-header X-SSL-Client-UID %[ssl_c_s_dn(uid)]

    default_backend my_nodes

backend my_nodes
    server node1 10.0.0.1:80 check
```

> **Note:** In HAProxy, the server certificate and its private key must be concatenated into a single `.pem` file for the `crt` directive.

### Client Installation

1. **Root CA** (`{prefix}-root.pem`): Import as "Trusted Root Authority" in your OS/Browser.
2. **Client Identity** (`{prefix}-client-{name}.pfx`): Import into your browser or mobile device (requires the password set during generation).

## Bash Autocompletion

To make the script even easier to use, you can enable bash autocompletion. This will allow you to press `TAB` to complete commands, prefixes, and even certificate names.

### Enable for current session:
```bash
source mkcerts-completion.bash
```

### Enable permanently:
Add the following line to your `~/.bashrc`:
```bash
source /path/to/mtls-gnutls-config/mkcerts-completion.bash
```

---

## Troubleshooting

| Problem | Solution |
|:---|:---|
| `certtool: command not found` | Install `gnutls-utils` or `gnutls-bin`. |
| `File already exists` | Use the `--force` flag: `./mkcerts.sh --force add-client ...` |
| `400 Bad Request` (Nginx) | No client certificate presented or certificate not trusted by the root CA. |
| `Certificate not trusted` | Ensure you imported the `root.pem` into the correct trust store. |
| `Permission denied` | Check that your user has write access to the `_certs-...` directories. |

---

## Security Notes

1. **Protect `root.key`**: This is your most critical file. If leaked, your entire mTLS security is compromised.
2. **Logs**: The script maintains a `generation.log` in each `_certs-...` folder to track all actions.
3. **UIDs**: Each certificate now has a unique `uid` (server host or client name) for easier identification in logs.

---

## License

MIT — See [LICENSE](./LICENSE) for details.
