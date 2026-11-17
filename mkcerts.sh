#!/bin/bash
#-----------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Usage ---
usage() {
    cat <<EOF
Usage: $0 [--force] <command> <prefix> [options]

Commands:
  init          <prefix>                       Generate root CA only
  add-server    <prefix> <dns_or_ip> [sans...] Generate a server certificate (+ HAProxy bundle)
  add-client    <prefix> <client_name>         Generate a client certificate (+ PKCS#12 bundle)
  all           <prefix> <dns_or_ip> [client]  Generate CA + server + client
  list          <prefix>                       List all generated certificates
  info          <prefix> <name>                Show details of a certificate
  check-expiry  <prefix> [days]                List certs expiring within N days (default: 90)
  revoke        <prefix> <name>                Revoke a certificate (add to CRL)
  unrevoke      <prefix> <name>                Cancel revocation (remove from CRL)
  clear-crl     <prefix>                       Clear all revocations (reset CRL to empty)
  deploy        <prefix> <server_name> <user@host> [remote_dir]
                                               Copy server cert + root CA via scp
  export-client <prefix> <client_name> [tar]   Create a ready-to-share client archive (.tar.gz)
  migrate       <prefix>                       Migrate legacy flat layout to structured directories

Directory layout (_certs-<prefix>/):
  ca/           Root CA private key (0600) and certificate
  servers/      Subdirectory per server (key 0600, cert, full chain, HAProxy bundle)
  clients/      Subdirectory per client (key 0600, cert, .pfx 0600, root CA copy, README.txt)
  crl/          Certificate Revocation List

Flags:
  --force       Overwrite existing certificates without prompting

Options:
  PASSWORD=xxx  Password for client .pfx (default: interactive prompt or 9876543210)

Examples:
  $0 init myinfra
  $0 add-server myinfra myserver.example.com
  $0 add-server myinfra 192.168.1.10
  $0 add-server myinfra iot.bzh 10.18.127.234 127.0.0.1
  $0 add-client myinfra jean-mobile
  $0 export-client myinfra jean-mobile
  $0 list myinfra
  $0 info myinfra jean-mobile
  $0 check-expiry myinfra 30
  $0 revoke myinfra jean-mobile
  $0 deploy myinfra myserver.example.com admin@myserver.example.com /etc/pki/nginx
EOF
    exit "${1:-1}"
}

# --- Parse --help flag before anything else ---
if [[ "${1:-}" =~ ^(-h|--help|help)$ ]]; then
    usage 0
fi

# --- Parse --force flag ---
FORCE=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE=true
    shift
fi

if [[ "${1:-}" =~ ^(-h|--help|help)$ ]]; then
    usage 0
fi

# --- Check dependencies ---
if ! command -v certtool &>/dev/null; then
    echo "ERROR: certtool is not installed. Install gnutls-utils (or gnutls-bin on Debian)."
    exit 1
fi

# --- Load configuration ---
# Priority: mkcerts-{prefix}.conf > mkcerts.conf
load_config() {
    local prefix="${1:-}"
    local prefix_conf="${SCRIPT_DIR}/mkcerts-${prefix}.conf"
    local default_conf="${SCRIPT_DIR}/mkcerts.conf"

    if [[ -n "${prefix}" && -f "${prefix_conf}" ]]; then
        echo "    (using prefix-specific config: mkcerts-${prefix}.conf)"
        # shellcheck source=/dev/null
        source "${prefix_conf}"
    elif [[ -f "${default_conf}" ]]; then
        # shellcheck source=mkcerts.conf
        source "${default_conf}"
    else
        echo "ERROR: Configuration file not found: ${default_conf}"
        echo "       Copy mkcerts.conf.example to mkcerts.conf and edit it."
        exit 1
    fi

    # Validate required config fields
    for VAR in ORGANIZATION UNIT STATE COUNTRY UID_FIELD CA_CN URI EMAIL CA_EXPIRY_DAYS SERVER_EXPIRY_DAYS CLIENT_EXPIRY_DAYS; do
        if [[ -z "${!VAR:-}" ]]; then
            echo "ERROR: Missing required variable '${VAR}' in config file."
            exit 1
        fi
    done
}

if [[ $# -lt 2 ]]; then
    usage 1
fi

COMMAND="${1}"
PREFIX="${2}"

# --- Validate prefix ---
if [[ "${PREFIX}" == -* ]]; then
    echo "ERROR: Invalid prefix '${PREFIX}'. Flags like --force must come before the command (e.g., $0 --force ${COMMAND} ...)."
    exit 1
fi

if [[ "${PREFIX}" =~ [^a-zA-Z0-9._-] ]]; then
    echo "ERROR: Invalid prefix '${PREFIX}'. Only alphanumeric characters, dashes, dots, and underscores are allowed."
    exit 1
fi

DESTINATION="${SCRIPT_DIR}/_certs-${PREFIX}"
CA_DIR="${DESTINATION}/ca"
SERVERS_DIR="${DESTINATION}/servers"
CLIENTS_DIR="${DESTINATION}/clients"
CRL_DIR="${DESTINATION}/crl"
LOG_FILE="${DESTINATION}/generation.log"

load_config "${PREFIX}"

# --- Password Helper ---
ensure_password() {
    if [[ -z "${PASSWORD:-}" ]]; then
        if [[ -t 0 ]]; then
            read -s -r -p "Enter password for client .pfx (press Enter for default '9876543210'): " input_pwd
            echo ""
            if [[ -n "${input_pwd}" ]]; then
                PASSWORD="${input_pwd}"
            else
                PASSWORD="9876543210"
            fi
        else
            echo "WARNING: No PASSWORD set, using default password '9876543210'."
            echo "         Set PASSWORD=yourpassword for better security."
            PASSWORD="9876543210"
        fi
    fi
}

#-----------------------------
# Check & resolve root CA paths
#-----------------------------
find_root_ca() {
    if [[ -f "${CA_DIR}/${PREFIX}-root.key" && -f "${CA_DIR}/${PREFIX}-root.pem" ]]; then
        ROOT_KEY="${CA_DIR}/${PREFIX}-root.key"
        ROOT_PEM="${CA_DIR}/${PREFIX}-root.pem"
        return 0
    elif [[ -f "${DESTINATION}/${PREFIX}-root.key" && -f "${DESTINATION}/${PREFIX}-root.pem" ]]; then
        ROOT_KEY="${DESTINATION}/${PREFIX}-root.key"
        ROOT_PEM="${DESTINATION}/${PREFIX}-root.pem"
        return 0
    fi
    return 1
}

#-----------------------------
# Migrate legacy flat layout to structured directories
#-----------------------------
migrate_structure() {
    if [[ -d "${DESTINATION}" && ! -d "${CA_DIR}" && -f "${DESTINATION}/${PREFIX}-root.key" ]]; then
        echo ">>> Migrating legacy flat directory structure to structured subdirectories..."
        mkdir -p "${CA_DIR}" "${SERVERS_DIR}" "${CLIENTS_DIR}" "${CRL_DIR}"
        chmod 700 "${CA_DIR}"

        # 1. Move root CA
        mv "${DESTINATION}/${PREFIX}-root."* "${CA_DIR}/" 2>/dev/null || true
        chmod 600 "${CA_DIR}/${PREFIX}-root.key" 2>/dev/null || true
        chmod 644 "${CA_DIR}/${PREFIX}-root.pem" 2>/dev/null || true

        # 2. Move servers
        for key in "${DESTINATION}/${PREFIX}-server-"*.key; do
            [[ -f "${key}" ]] || continue
            local sname
            sname="$(basename "${key}" .key | sed "s/^${PREFIX}-server-//")"
            mkdir -p "${SERVERS_DIR}/${sname}"
            mv "${DESTINATION}/${PREFIX}-server-${sname}".* "${SERVERS_DIR}/${sname}/" 2>/dev/null || true
            chmod 600 "${SERVERS_DIR}/${sname}/${PREFIX}-server-${sname}.key" 2>/dev/null || true

            # Generate HAProxy combined pem if missing
            local scrt="${SERVERS_DIR}/${sname}/${PREFIX}-server-${sname}.crt"
            local skey="${SERVERS_DIR}/${sname}/${PREFIX}-server-${sname}.key"
            local shaproxy="${SERVERS_DIR}/${sname}/${PREFIX}-server-${sname}-haproxy.pem"
            if [[ -f "${scrt}" && -f "${skey}" && ! -f "${shaproxy}" ]]; then
                cat "${scrt}" "${skey}" > "${shaproxy}"
                chmod 600 "${shaproxy}"
            fi
        done

        # 3. Move clients
        for key in "${DESTINATION}/${PREFIX}-client-"*.key; do
            [[ -f "${key}" ]] || continue
            local cname
            cname="$(basename "${key}" .key | sed "s/^${PREFIX}-client-//")"
            mkdir -p "${CLIENTS_DIR}/${cname}"
            mv "${DESTINATION}/${PREFIX}-client-${cname}".* "${CLIENTS_DIR}/${cname}/" 2>/dev/null || true
            chmod 600 "${CLIENTS_DIR}/${cname}/${PREFIX}-client-${cname}.key" 2>/dev/null || true
            chmod 600 "${CLIENTS_DIR}/${cname}/${PREFIX}-client-${cname}.pfx" 2>/dev/null || true
            cp "${CA_DIR}/${PREFIX}-root.pem" "${CLIENTS_DIR}/${cname}/" 2>/dev/null || true
        done

        # 4. Move CRL
        if [[ -f "${DESTINATION}/${PREFIX}-crl.pem" ]]; then
            mv "${DESTINATION}/${PREFIX}-crl.pem" "${CRL_DIR}/" 2>/dev/null || true
        fi
        echo "    ✓ Migration complete!"
    fi
}

#-----------------------------
# Check that root CA exists for commands that require an existing PKI
#-----------------------------
require_root_ca() {
    # If legacy flat structure is detected, auto-migrate to organized directories
    if [[ -d "${DESTINATION}" && ! -d "${CA_DIR}" && -f "${DESTINATION}/${PREFIX}-root.key" ]]; then
        migrate_structure
    fi

    if ! find_root_ca; then
        echo "ERROR: Root CA not found for prefix '${PREFIX}'."
        echo "       Expected in: ${CA_DIR}/"
        echo "       Run '$0 init ${PREFIX}' first."
        local available
        available=$(find "${SCRIPT_DIR}" -maxdepth 1 -type d -name "_certs-*" 2>/dev/null | sed 's|.*/_certs-||' | sort | tr '\n' ' ')
        if [[ -n "${available// /}" ]]; then
            echo ""
            echo "       Existing prefix(es) on this system: ${available}"
        fi
        exit 1
    fi
}

#-----------------------------
# Logging helper
#-----------------------------
log_action() {
    mkdir -p "${DESTINATION}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${*}" >> "${LOG_FILE}"
}

#-----------------------------
# Check if a file exists and handle --force / prompt
# Args: $1=filepath  $2=description
#-----------------------------
check_overwrite() {
    local filepath="${1}"
    local desc="${2}"
    if [[ -f "${filepath}" ]]; then
        if [[ "${FORCE}" == true ]]; then
            echo "    WARNING: Overwriting existing ${desc} (--force)"
        else
            echo "ERROR: ${desc} already exists: ${filepath}"
            echo "       Use --force to overwrite."
            exit 1
        fi
    fi
}

#-----------------------------
# Check if a string is an IP address (IPv4 or IPv6)
#-----------------------------
is_ip_address() {
    local value="${1}"
    if [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
    if [[ "${value}" =~ ^[0-9a-fA-F:]+$ && "${value}" == *:* ]]; then
        return 0
    fi
    return 1
}

#-----------------------------
# Sanitize a name for use as a filename (replace dots and spaces with dashes, * with wildcard)
#-----------------------------
sanitize() {
    echo "${1}" | sed -e 's/\*/wildcard/g' -e 's/[\. ]/-/g'
}

#-----------------------------
# Create a temporary template by replacing placeholder values
# Args: $1=base_template  $2=output_tmp_file  $3=cn_value
#       $4=uid_override (optional)  $@=host_values (dns or ip, optional)
#-----------------------------
make_template() {
    local base_template="${1}"
    local output="${2}"
    local cn_value="${3}"
    local uid_override="${4:-}"
    shift 4
    local host_values=("$@")

    cp "${base_template}" "${output}"

    # Substitute identity + expiry fields from config
    sed -i \
        -e "s|@@ORGANIZATION@@|${ORGANIZATION}|g" \
        -e "s|@@UNIT@@|${UNIT}|g" \
        -e "s|@@STATE@@|${STATE}|g" \
        -e "s|@@COUNTRY@@|${COUNTRY}|g" \
        -e "s|@@UID_FIELD@@|${UID_FIELD}|g" \
        -e "s|@@CA_CN@@|${CA_CN}|g" \
        -e "s|@@URI@@|${URI}|g" \
        -e "s|@@EMAIL@@|${EMAIL}|g" \
        -e "s|@@CA_EXPIRY_DAYS@@|${CA_EXPIRY_DAYS}|g" \
        -e "s|@@SERVER_EXPIRY_DAYS@@|${SERVER_EXPIRY_DAYS}|g" \
        -e "s|@@CLIENT_EXPIRY_DAYS@@|${CLIENT_EXPIRY_DAYS}|g" \
        "${output}"

    # Override uid if provided (unique per cert)
    if [[ -n "${uid_override}" ]]; then
        sed -i "s|^uid = .*|uid = \"${uid_override}\"|" "${output}"
    fi

    # Replace cn
    sed -i "s|^cn = .*|cn = \"${cn_value}\"|" "${output}"

    # Remove default dns_name and ip_address to avoid duplicates
    sed -i '/^dns_name = .*/d' "${output}"
    sed -i '/^ip_address = .*/d' "${output}"

    # Append all provided host values as SANs
    for host_value in "${host_values[@]}"; do
        if [[ -z "${host_value}" ]]; then continue; fi
        if is_ip_address "${host_value}"; then
            echo "    (adding IP address: ${host_value})"
            echo "ip_address = \"${host_value}\"" >> "${output}"
        else
            echo "    (adding DNS name: ${host_value})"
            echo "dns_name = \"${host_value}\"" >> "${output}"
        fi
    done
}

#-----------------------------
make_root_certificate() {
    mkdir -p "${CA_DIR}"
    chmod 700 "${CA_DIR}"

    local root_key="${CA_DIR}/${PREFIX}-root.key"
    local root_pem="${CA_DIR}/${PREFIX}-root.pem"

    check_overwrite "${root_key}" "Root CA"
    local tmp_template
    tmp_template="$(mktemp)"
    echo ">>> Generating root CA certificate (${PREFIX}-root)..."
    make_template \
        "${SCRIPT_DIR}/templ-auth.cfg" \
        "${tmp_template}" \
        "${CA_CN}" \
        ""
    certtool \
        --generate-privkey \
        --key-type=ecdsa \
        --curve=secp256r1 \
        --no-text \
        --outfile="${root_key}"
    chmod 600 "${root_key}"

    certtool \
        --generate-self-signed \
        --template="${tmp_template}" \
        --load-privkey="${root_key}" \
        --no-text \
        --outfile="${root_pem}"
    chmod 644 "${root_pem}"

    rm -f "${tmp_template}"
    ROOT_KEY="${root_key}"
    ROOT_PEM="${root_pem}"

    echo "    ✓ ${root_key} (private key, chmod 0600)"
    echo "    ✓ ${root_pem} (root CA certificate)"
    log_action "INIT    root CA: ${PREFIX}-root  CN=${CA_CN}  expiry=${CA_EXPIRY_DAYS}d"

    # Also generate the initial empty CRL so Nginx / HAProxy can load it immediately
    generate_empty_crl
    echo "    ✓ ${CRL_DIR}/${PREFIX}-crl.pem (initial empty CRL)"
}

# Args: $1=primary_host  $@=extra_hosts (optional)
#-----------------------------
make_server_certificate() {
    local primary_host="${1}"
    local safe_name
    safe_name="$(sanitize "${primary_host}")"
    local server_dir="${SERVERS_DIR}/${safe_name}"
    mkdir -p "${server_dir}"

    local s_key="${server_dir}/${PREFIX}-server-${safe_name}.key"
    local s_pem="${server_dir}/${PREFIX}-server-${safe_name}.pem"
    local s_crt="${server_dir}/${PREFIX}-server-${safe_name}.crt"
    local s_haproxy="${server_dir}/${PREFIX}-server-${safe_name}-haproxy.pem"

    check_overwrite "${s_key}" "server cert '${primary_host}'"
    echo ">>> Generating server certificate for '${primary_host}' (${PREFIX}-server-${safe_name})..."

    local tmp_template
    tmp_template="$(mktemp)"

    make_template \
        "${SCRIPT_DIR}/templ-server.cfg" \
        "${tmp_template}" \
        "${primary_host} server" \
        "${safe_name}" \
        "$@"

    certtool \
        --generate-privkey \
        --key-type=ecdsa \
        --curve=secp256r1 \
        --no-text \
        --outfile="${s_key}"
    chmod 600 "${s_key}"

    certtool \
        --generate-certificate \
        --template="${tmp_template}" \
        --load-privkey="${s_key}" \
        --load-ca-privkey="${ROOT_KEY}" \
        --load-ca-certificate="${ROOT_PEM}" \
        --no-text \
        --outfile="${s_pem}"
    chmod 644 "${s_pem}"

    # Full chain (server cert + root CA) for Nginx / standard TLS
    cat "${s_pem}" "${ROOT_PEM}" > "${s_crt}"
    chmod 644 "${s_crt}"

    # HAProxy bundle (full chain + private key)
    cat "${s_crt}" "${s_key}" > "${s_haproxy}"
    chmod 600 "${s_haproxy}"

    # Keep a copy of Root CA in the server directory
    cp "${ROOT_PEM}" "${server_dir}/${PREFIX}-root.pem"
    chmod 644 "${server_dir}/${PREFIX}-root.pem"

    rm -f "${tmp_template}"

    echo "    ✓ ${s_key} (private key, chmod 0600)"
    echo "    ✓ ${s_pem} (server certificate)"
    echo "    ✓ ${s_crt} (full chain: server + root CA)"
    echo "    ✓ ${s_haproxy} (combined bundle for HAProxy, chmod 0600)"
    echo "    ✓ ${server_dir}/${PREFIX}-root.pem (root CA copy)"
    echo "    Verifying server certificate chain..."
    certtool --verify \
        --load-ca-certificate "${ROOT_PEM}" \
        --infile "${s_pem}"
    log_action "SERVER  ${PREFIX}-server-${safe_name}  host=${primary_host}  expiry=${SERVER_EXPIRY_DAYS}d"
}

#-----------------------------
# Args: $1=client_name
#-----------------------------
make_client_certificate() {
    local client_name="${1}"
    local safe_name
    safe_name="$(sanitize "${client_name}")"
    local client_dir="${CLIENTS_DIR}/${safe_name}"
    mkdir -p "${client_dir}"

    local c_key="${client_dir}/${PREFIX}-client-${safe_name}.key"
    local c_pem="${client_dir}/${PREFIX}-client-${safe_name}.pem"
    local c_crt="${client_dir}/${PREFIX}-client-${safe_name}.crt"
    local c_pfx="${client_dir}/${PREFIX}-client-${safe_name}.pfx"
    local c_readme="${client_dir}/README.txt"

    check_overwrite "${c_key}" "client cert '${client_name}'"
    ensure_password

    echo ">>> Generating client certificate for '${client_name}' (${PREFIX}-client-${safe_name})..."

    local tmp_template
    tmp_template="$(mktemp)"

    make_template \
        "${SCRIPT_DIR}/templ-client.cfg" \
        "${tmp_template}" \
        "${client_name} client" \
        "${safe_name}" \
        ""

    certtool \
        --generate-privkey \
        --key-type=ecdsa \
        --curve=secp256r1 \
        --no-text \
        --outfile="${c_key}"
    chmod 600 "${c_key}"

    certtool \
        --generate-certificate \
        --template="${tmp_template}" \
        --load-privkey="${c_key}" \
        --load-ca-privkey="${ROOT_KEY}" \
        --load-ca-certificate="${ROOT_PEM}" \
        --no-text \
        --outfile="${c_pem}"
    chmod 644 "${c_pem}"

    cat "${c_pem}" "${ROOT_PEM}" > "${c_crt}"
    chmod 644 "${c_crt}"

    certtool \
        --load-ca-certificate "${ROOT_PEM}" \
        --load-privkey "${c_key}" \
        --load-certificate "${c_pem}" \
        --to-p12 --p12-name "${PREFIX}@${safe_name}" \
        --password="${PASSWORD}" \
        --outder --outfile "${c_pfx}"
    chmod 600 "${c_pfx}"

    # Copy Root CA to the client directory
    cp "${ROOT_PEM}" "${client_dir}/${PREFIX}-root.pem"
    chmod 644 "${client_dir}/${PREFIX}-root.pem"

    # Create installation instructions in the client folder
    cat > "${c_readme}" <<EOF
===================================================================
mTLS Client Certificate Bundle for: ${client_name}
PKI Prefix: ${PREFIX}
Generated: $(date -u '+%Y-%m-%d %H:%M:%SZ')
===================================================================

Files in this bundle:
  1. ${PREFIX}-root.pem
     Root CA certificate. Install as a "Trusted Root Certificate"
     on your device (Android, iOS, macOS, Windows, Linux).

  2. ${PREFIX}-client-${safe_name}.pfx
     Client certificate and private key in PKCS#12 format.
     Import into your browser or device user certificates.
     PFX Password: ${PASSWORD}

Quick Installation:
-------------------
- Android:
  1. Transfer both files to the phone.
  2. Settings > Security & Privacy > More security settings > Encryption & credentials.
  3. "Install a certificate" > "CA certificate" -> Select ${PREFIX}-root.pem.
  4. "Install a certificate" > "VPN & app user certificate" -> Select ${PREFIX}-client-${safe_name}.pfx (enter password).

- iOS:
  1. Send ${PREFIX}-root.pem via AirDrop or Mail.
  2. Settings > Profile Downloaded > Install.
  3. Settings > General > About > Certificate Trust Settings > Enable full trust for Root CA.
  4. Import ${PREFIX}-client-${safe_name}.pfx into your profile or browser.

- Firefox:
  1. Settings > Privacy & Security > Certificates > View Certificates.
  2. "Authorities" tab -> Import ${PREFIX}-root.pem (check "Trust this CA to identify websites").
  3. "Your Certificates" tab -> Import ${PREFIX}-client-${safe_name}.pfx (enter password).

- Chrome / Edge / macOS Keychain / Windows:
  1. Double click ${PREFIX}-root.pem to install into "Trusted Root Certification Authorities".
  2. Double click ${PREFIX}-client-${safe_name}.pfx to import client certificate (enter password).
EOF

    rm -f "${tmp_template}"

    echo "    ✓ ${c_key} (private key, chmod 0600)"
    echo "    ✓ ${c_pem} (client certificate)"
    echo "    ✓ ${c_crt} (full chain)"
    echo "    ✓ ${c_pfx} (PKCS#12 bundle, chmod 0600)"
    echo "    ✓ ${client_dir}/${PREFIX}-root.pem (root CA copy)"
    echo "    ✓ ${c_readme} (installation instructions)"
    echo "    Verifying client certificate chain..."
    certtool --verify \
        --load-ca-certificate "${ROOT_PEM}" \
        --infile "${c_pem}"
    log_action "CLIENT  ${PREFIX}-client-${safe_name}  name=${client_name}  expiry=${CLIENT_EXPIRY_DAYS}d"
}

#-----------------------------
# export-client: package client files into an archive
#-----------------------------
cmd_export_client() {
    local name="${1:-}"
    if [[ -z "${name}" ]]; then
        echo "ERROR: Missing client name. Usage: $0 export-client <prefix> <client_name> [output_file]"
        exit 1
    fi
    local safe_name
    safe_name="$(sanitize "${name}")"
    local client_dir="${CLIENTS_DIR}/${safe_name}"

    if [[ ! -d "${client_dir}" ]]; then
        echo "ERROR: Client '${name}' not found in ${CLIENTS_DIR}/"
        exit 1
    fi

    local archive_name="${2:-${SCRIPT_DIR}/${PREFIX}-${safe_name}-bundle.tar.gz}"
    tar -czf "${archive_name}" -C "${client_dir}" \
        "${PREFIX}-client-${safe_name}.pfx" \
        "${PREFIX}-root.pem" \
        "README.txt"

    echo "✅ Exported client bundle: ${archive_name}"
    echo "   Contents: .pfx (credentials), root.pem (trust anchor), and README.txt instructions."
}

#-----------------------------
# list: display all certs in the prefix directory
#-----------------------------
cmd_list() {
    echo "Certificates in ${DESTINATION}/:"
    echo ""
    printf "  %-10s %-45s %-28s %s\n" "TYPE" "FILE" "CN" "EXPIRES"
    printf "  %-10s %-45s %-28s %s\n" "----" "----" "--" "-------"

    local pems=()
    while IFS= read -r -d $'\0' file; do
        pems+=("$file")
    done < <(find "${DESTINATION}" -type f -name "*.pem" ! -name "*-haproxy.pem" ! -name "*-crl.pem" -print0 2>/dev/null | sort -z)

    for pem in "${pems[@]}"; do
        [[ -f "${pem}" ]] || continue
        # Ignore redundant root CA copies in client or server subdirs
        if [[ "${pem}" =~ /(clients|servers)/[^/]+/${PREFIX}-root\.pem$ ]]; then
            continue
        fi

        local basename type cn expiry
        basename="$(basename "${pem}" .pem)"
        if [[ "${basename}" == *"-root" ]]; then
            type="CA"
        elif [[ "${basename}" == *"-server-"* ]]; then
            type="server"
        elif [[ "${basename}" == *"-client-"* ]]; then
            type="client"
        else
            type="unknown"
        fi

        cn="$(certtool --certificate-info --infile "${pem}" 2>/dev/null | sed -n '/Subject:.*CN=/ s/.*CN=\([^,]*\).*/\1/p; /^\s*Common Name:/ s/.*Common Name: //p' | head -n1)"
        [[ -z "${cn}" ]] && cn="n/a"
        expiry="$(certtool --certificate-info --infile "${pem}" 2>/dev/null \
            | grep -m1 "Not After:" | sed 's/.*Not After: //' || echo "n/a")"
        printf "  %-10s %-45s %-28s %s\n" "${type}" "${basename}" "${cn}" "${expiry}"
    done
    echo ""
}

#-----------------------------
# info: display full details of a specific cert
#-----------------------------
cmd_info() {
    local name="${1:-}"
    if [[ -z "${name}" ]]; then
        echo "ERROR: Missing cert name. Usage: $0 info <prefix> <name>"
        echo "       Use '$0 list ${PREFIX}' to see available certs."
        exit 1
    fi
    local safe_name
    safe_name="$(sanitize "${name}")"
    local pem=""
    for candidate in \
        "${CLIENTS_DIR}/${safe_name}/${PREFIX}-client-${safe_name}.pem" \
        "${SERVERS_DIR}/${safe_name}/${PREFIX}-server-${safe_name}.pem" \
        "${CA_DIR}/${PREFIX}-root.pem" \
        "${DESTINATION}/${PREFIX}-client-${safe_name}.pem" \
        "${DESTINATION}/${PREFIX}-server-${safe_name}.pem" \
        "${DESTINATION}/${PREFIX}-root.pem"; do
        if [[ -f "${candidate}" ]]; then
            pem="${candidate}"
            break
        fi
    done
    if [[ -z "${pem}" ]]; then
        echo "ERROR: No certificate found for '${name}' in ${DESTINATION}/"
        echo "       Use '$0 list ${PREFIX}' to see available certs."
        exit 1
    fi
    echo "Certificate info: ${pem}"
    echo ""
    certtool --certificate-info --infile "${pem}"
}

#-----------------------------
# check-expiry: list certs expiring within N days
#-----------------------------
cmd_check_expiry() {
    local threshold="${1:-90}"
    local threshold_epoch
    threshold_epoch=$(date -d "+${threshold} days" +%s)
    local found=false
    local has_expired=false

    echo "Checking certificates expiring within ${threshold} days in ${DESTINATION}/:"
    echo ""

    local pems=()
    while IFS= read -r -d $'\0' file; do
        pems+=("$file")
    done < <(find "${DESTINATION}" -type f -name "*.pem" ! -name "*-haproxy.pem" ! -name "*-crl.pem" -print0 2>/dev/null | sort -z)

    for pem in "${pems[@]}"; do
        [[ -f "${pem}" ]] || continue
        if [[ "${pem}" =~ /(clients|servers)/[^/]+/${PREFIX}-root\.pem$ ]]; then
            continue
        fi

        local expiry_str expiry_epoch basename days_left
        basename="$(basename "${pem}" .pem)"
        expiry_str="$(certtool --certificate-info --infile "${pem}" 2>/dev/null \
            | grep -m1 "Not After:" | sed 's/.*Not After: //' || echo "")"
        [[ -z "${expiry_str}" ]] && continue
        expiry_epoch="$(date -d "${expiry_str}" +%s 2>/dev/null || echo 0)"
        days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))
        if [[ ${expiry_epoch} -le ${threshold_epoch} ]]; then
            if [[ ${days_left} -le 0 ]]; then
                echo "  ⛔ EXPIRED    ${basename}  (expired ${expiry_str})"
                has_expired=true
            else
                echo "  ⚠️  ${days_left} days    ${basename}  (expires ${expiry_str})"
            fi
            found=true
        fi
    done

    if [[ "${found}" == false ]]; then
        echo "  ✅ All certificates are valid for more than ${threshold} days."
        echo ""
        return 0
    else
        echo ""
        if [[ "${has_expired}" == true ]]; then
            return 2
        else
            return 1
        fi
    fi
}

#-----------------------------
# Find cert pem by name
#-----------------------------
find_cert_pem() {
    local name="${1}"
    local safe_name
    safe_name="$(sanitize "${name}")"
    for candidate in \
        "${CLIENTS_DIR}/${safe_name}/${PREFIX}-client-${safe_name}.pem" \
        "${SERVERS_DIR}/${safe_name}/${PREFIX}-server-${safe_name}.pem" \
        "${DESTINATION}/${PREFIX}-client-${safe_name}.pem" \
        "${DESTINATION}/${PREFIX}-server-${safe_name}.pem"; do
        if [[ -f "${candidate}" ]]; then
            echo "${candidate}"
            return 0
        fi
    done
    return 1
}

#-----------------------------
# Generate an empty signed CRL
#-----------------------------
generate_empty_crl() {
    mkdir -p "${CRL_DIR}"
    local crl_template
    crl_template="$(mktemp)"
    cat > "${crl_template}" <<EOF
crl_next_update = 365
crl_revocation_date = "$(date -u '+%Y-%m-%d %H:%M:%S')"
EOF
    local crl_out="${CRL_DIR}/${PREFIX}-crl.pem"
    certtool --generate-crl \
        --load-ca-privkey "${ROOT_KEY}" \
        --load-ca-certificate "${ROOT_PEM}" \
        --template "${crl_template}" \
        --outfile "${crl_out}"
    chmod 644 "${crl_out}"
    rm -f "${crl_template}"
    touch "${CRL_DIR}/revoked.txt"
}

#-----------------------------
# Rebuild the CRL from revoked.txt
#-----------------------------
rebuild_crl() {
    mkdir -p "${CRL_DIR}"
    local revoked_list="${CRL_DIR}/revoked.txt"
    touch "${revoked_list}"

    local crl_template
    crl_template="$(mktemp)"
    cat > "${crl_template}" <<EOF
crl_next_update = 365
crl_revocation_date = "$(date -u '+%Y-%m-%d %H:%M:%S')"
EOF
    local crl_out="${CRL_DIR}/${PREFIX}-crl.pem"
    local crl_current
    crl_current="$(mktemp)"

    # 1. Base empty CRL
    certtool --generate-crl \
        --load-ca-privkey "${ROOT_KEY}" \
        --load-ca-certificate "${ROOT_PEM}" \
        --template "${crl_template}" \
        --outfile "${crl_current}"

    # 2. Accumulate all certificates listed in revoked.txt
    while IFS= read -r pem_file; do
        [[ -n "${pem_file}" && -f "${pem_file}" ]] || continue
        local crl_next
        crl_next="$(mktemp)"
        certtool --generate-crl \
            --load-ca-privkey "${ROOT_KEY}" \
            --load-ca-certificate "${ROOT_PEM}" \
            --load-crl "${crl_current}" \
            --load-certificate "${pem_file}" \
            --template "${crl_template}" \
            --outfile "${crl_next}"
        rm -f "${crl_current}"
        crl_current="${crl_next}"
    done < "${revoked_list}"

    mv "${crl_current}" "${crl_out}"
    chmod 644 "${crl_out}"
    rm -f "${crl_template}"
}

#-----------------------------
# revoke: generate or update CRL revoking a specific cert
#-----------------------------
cmd_revoke() {
    local name="${1:-}"
    if [[ -z "${name}" ]]; then
        echo "ERROR: Missing cert name. Usage: $0 revoke <prefix> <name>"
        exit 1
    fi
    local pem
    if ! pem="$(find_cert_pem "${name}")"; then
        echo "ERROR: No certificate found for '${name}' in ${DESTINATION}/"
        exit 1
    fi

    echo ">>> Revoking certificate '${name}'..."
    mkdir -p "${CRL_DIR}"
    local revoked_list="${CRL_DIR}/revoked.txt"
    touch "${revoked_list}"

    if ! grep -Fxq "${pem}" "${revoked_list}" 2>/dev/null; then
        echo "${pem}" >> "${revoked_list}"
    fi

    rebuild_crl

    local crl_out="${CRL_DIR}/${PREFIX}-crl.pem"
    echo "    ✓ CRL updated: ${crl_out}"
    echo ""
    echo "    Remember to reload your web server:"
    echo "      Nginx:   sudo systemctl reload nginx"
    echo "      HAProxy: sudo systemctl reload haproxy"
    log_action "REVOKE  ${pem}"
}

#-----------------------------
# unrevoke: cancel revocation of a certificate
#-----------------------------
cmd_unrevoke() {
    local name="${1:-}"
    if [[ -z "${name}" ]]; then
        echo "ERROR: Missing cert name. Usage: $0 unrevoke <prefix> <name>"
        exit 1
    fi
    local pem
    if ! pem="$(find_cert_pem "${name}")"; then
        echo "ERROR: No certificate found for '${name}' in ${DESTINATION}/"
        exit 1
    fi

    local revoked_list="${CRL_DIR}/revoked.txt"
    echo ">>> Unrevoking certificate '${name}'..."

    if [[ -f "${revoked_list}" ]]; then
        local tmp_list
        tmp_list="$(mktemp)"
        grep -Fxv "${pem}" "${revoked_list}" > "${tmp_list}" || true
        mv "${tmp_list}" "${revoked_list}"
    fi

    rebuild_crl

    local crl_out="${CRL_DIR}/${PREFIX}-crl.pem"
    echo "    ✓ Certificate '${name}' unrevoked! CRL updated: ${crl_out}"
    echo ""
    echo "    Remember to reload your web server to apply the changes:"
    echo "      Nginx:   sudo systemctl reload nginx"
    echo "      HAProxy: sudo systemctl reload haproxy"
    log_action "UNREVOKE ${pem}"
}

#-----------------------------
# clear-crl: reset the CRL to empty
#-----------------------------
cmd_clear_crl() {
    echo ">>> Clearing all certificate revocations for prefix '${PREFIX}'..."
    mkdir -p "${CRL_DIR}"
    local revoked_list="${CRL_DIR}/revoked.txt"
    > "${revoked_list}"

    rebuild_crl

    local crl_out="${CRL_DIR}/${PREFIX}-crl.pem"
    echo "    ✓ All revocations cleared! Empty CRL generated: ${crl_out}"
    echo ""
    echo "    Remember to reload your web server:"
    echo "      Nginx:   sudo systemctl reload nginx"
    echo "      HAProxy: sudo systemctl reload haproxy"
    log_action "CLEAR-CRL"
}

#-----------------------------
# deploy: copy server cert + root CA to a remote host via scp
#-----------------------------
cmd_deploy() {
    local server_name="${1:-}"
    local remote="${2:-}"
    local remote_dir="${3:-/etc/pki/tls/certs}"

    if [[ -z "${server_name}" || -z "${remote}" ]]; then
        echo "ERROR: Usage: $0 deploy <prefix> <server_name> <user@host> [remote_dir]"
        exit 1
    fi

    local safe_name
    safe_name="$(sanitize "${server_name}")"
    local server_dir="${SERVERS_DIR}/${safe_name}"

    local crt="${server_dir}/${PREFIX}-server-${safe_name}.crt"
    local key="${server_dir}/${PREFIX}-server-${safe_name}.key"
    local haproxy="${server_dir}/${PREFIX}-server-${safe_name}-haproxy.pem"
    local ca="${ROOT_PEM}"
    local crl="${CRL_DIR}/${PREFIX}-crl.pem"

    # Fallback to legacy path if not in server_dir
    if [[ ! -f "${crt}" && -f "${DESTINATION}/${PREFIX}-server-${safe_name}.crt" ]]; then
        crt="${DESTINATION}/${PREFIX}-server-${safe_name}.crt"
        key="${DESTINATION}/${PREFIX}-server-${safe_name}.key"
    fi

    for f in "${crt}" "${key}" "${ca}"; do
        if [[ ! -f "${f}" ]]; then
            echo "ERROR: File not found: ${f}"
            echo "       Run './mkcerts.sh add-server ${PREFIX} ${server_name}' first."
            exit 1
        fi
    done

    echo ">>> Deploying server cert for '${server_name}' to ${remote}:${remote_dir} ..."
    ssh "${remote}" "mkdir -p ${remote_dir}"
    scp "${crt}" "${key}" "${ca}" "${remote}:${remote_dir}/"
    if [[ -f "${haproxy}" ]]; then
        scp "${haproxy}" "${remote}:${remote_dir}/"
    fi
    if [[ -f "${crl}" ]]; then
        scp "${crl}" "${remote}:${remote_dir}/"
    fi

    echo "    ✓ ${PREFIX}-server-${safe_name}.crt"
    echo "    ✓ ${PREFIX}-server-${safe_name}.key"
    if [[ -f "${haproxy}" ]]; then
        echo "    ✓ ${PREFIX}-server-${safe_name}-haproxy.pem (HAProxy bundle)"
    fi
    echo "    ✓ $(basename "${ca}")"
    if [[ -f "${crl}" ]]; then
        echo "    ✓ ${PREFIX}-crl.pem (Certificate Revocation List)"
    fi
    echo ""
    echo "    Update your Nginx config:"
    echo "      ssl_certificate         ${remote_dir}/${PREFIX}-server-${safe_name}.crt;"
    echo "      ssl_certificate_key     ${remote_dir}/${PREFIX}-server-${safe_name}.key;"
    echo "      ssl_client_certificate ${remote_dir}/$(basename "${ca}");"
    echo "      ssl_crl                 ${remote_dir}/${PREFIX}-crl.pem;"
    echo ""
    echo "    Or for HAProxy:"
    echo "      bind *:443 ssl crt ${remote_dir}/${PREFIX}-server-${safe_name}-haproxy.pem ca-file ${remote_dir}/$(basename "${ca}") verify required crl-file ${remote_dir}/${PREFIX}-crl.pem"
    log_action "DEPLOY  ${PREFIX}-server-${safe_name} -> ${remote}:${remote_dir}"
}

#-----------------------------
# Command dispatch
#-----------------------------
case "${COMMAND}" in
    init)
        mkdir -p "${DESTINATION}"
        make_root_certificate
        echo ""
        echo "✅ Root CA generated in ${CA_DIR}/"
        echo "   Now add servers and clients with:"
        echo "   $0 add-server ${PREFIX} <dns_or_ip>"
        echo "   $0 add-client ${PREFIX} <client_name>"
        ;;

    add-server)
        if [[ $# -lt 3 || -z "${3:-}" ]]; then
            echo "ERROR: Missing dns_name/ip argument."
            echo "Usage: $0 add-server <prefix> <dns_or_ip> [sans...]"
            exit 1
        fi
        require_root_ca
        make_server_certificate "${@:3}"
        echo ""
        echo "✅ Server certificate for '${3}' generated in ${SERVERS_DIR}/$(sanitize "${3}")/"
        ;;

    add-client)
        if [[ $# -lt 3 || -z "${3:-}" ]]; then
            echo "ERROR: Missing client_name argument."
            echo "Usage: $0 add-client <prefix> <client_name>"
            exit 1
        fi
        require_root_ca
        make_client_certificate "${3}"
        echo ""
        echo "✅ Client certificate for '${3}' generated in ${CLIENTS_DIR}/$(sanitize "${3}")/"
        ;;

    all)
        if [[ $# -lt 3 || -z "${3:-}" ]]; then
            echo "ERROR: Missing dns_name argument."
            echo "Usage: $0 all <prefix> <dns_or_ip> [client_name]"
            exit 1
        fi
        mkdir -p "${DESTINATION}"
        local_dns="${3}"
        local_client="${4:-client}"
        make_root_certificate
        make_server_certificate "${local_dns}"
        make_client_certificate "${local_client}"
        echo ""
        echo "✅ All certificates generated in ${DESTINATION}/"
        ;;

    list)
        require_root_ca
        cmd_list
        ;;

    info)
        if [[ $# -lt 3 || -z "${3:-}" ]]; then
            echo "ERROR: Missing cert name. Usage: $0 info <prefix> <name>"
            echo "       Use '$0 list ${PREFIX}' to see available certs."
            exit 1
        fi
        require_root_ca
        cmd_info "${3}"
        ;;

    check-expiry)
        require_root_ca
        if [[ -n "${3:-}" && ! "${3}" =~ ^[0-9]+$ ]]; then
            echo "ERROR: Invalid days argument '${3}'. Must be a positive integer."
            echo "Usage: $0 check-expiry <prefix> [days]"
            exit 1
        fi
        cmd_check_expiry "${3:-90}"
        ;;

    revoke)
        if [[ $# -lt 3 || -z "${3:-}" ]]; then
            echo "ERROR: Missing cert name."
            echo "Usage: $0 revoke <prefix> <name>"
            exit 1
        fi
        require_root_ca
        cmd_revoke "${3}"
        ;;

    unrevoke)
        if [[ $# -lt 3 || -z "${3:-}" ]]; then
            echo "ERROR: Missing cert name."
            echo "Usage: $0 unrevoke <prefix> <name>"
            exit 1
        fi
        require_root_ca
        cmd_unrevoke "${3}"
        ;;

    clear-crl)
        require_root_ca
        cmd_clear_crl
        ;;

    deploy)
        if [[ $# -lt 4 ]]; then
            echo "ERROR: Missing arguments."
            echo "Usage: $0 deploy <prefix> <server_name> <user@host> [remote_dir]"
            exit 1
        fi
        require_root_ca
        cmd_deploy "${3}" "${4}" "${5:-/etc/pki/tls/certs}"
        ;;

    export-client)
        if [[ $# -lt 3 || -z "${3:-}" ]]; then
            echo "ERROR: Missing client name."
            echo "Usage: $0 export-client <prefix> <client_name> [output_archive]"
            exit 1
        fi
        require_root_ca
        cmd_export_client "${3}" "${4:-}"
        ;;

    migrate)
        require_root_ca
        echo "✅ Directory layout for prefix '${PREFIX}' is structured and up to date."
        ;;

    -h|--help|help)
        usage 0
        ;;

    *)
        echo "ERROR: Unknown command '${COMMAND}'"
        usage 1
        ;;
esac
