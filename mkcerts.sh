#!/bin/bash
#-----------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Usage ---
usage() {
    cat <<EOF
Usage: $0 [--force] <command> <prefix> [options]

Commands:
  init         <prefix>                       Generate root CA only
  add-server   <prefix> <dns_or_ip>           Generate a server certificate
  add-client   <prefix> <client_name>         Generate a client certificate
  all          <prefix> <dns_or_ip> [client]  Generate CA + server + client
  list         <prefix>                        List all generated certificates
  info         <prefix> <name>                Show details of a certificate
  check-expiry <prefix> [days]                List certs expiring within N days (default: 90)
  revoke       <prefix> <name>                Revoke a certificate (generate CRL)
  deploy       <prefix> <server_name> <user@host> [remote_dir]
                                              Copy server cert + root CA via scp

Flags:
  --force    Overwrite existing certificates without prompting

Options:
  PASSWORD=xxx   Password for client .pfx (default: 9876543210)

Examples:
  $0 init myinfra
  $0 add-server myinfra myserver.example.com
  $0 add-server myinfra 192.168.1.10
  $0 add-client myinfra jean-mobile
  $0 --force add-client myinfra jean-mobile
  $0 list myinfra
  $0 info myinfra jean-mobile
  $0 check-expiry myinfra 30
  $0 revoke myinfra jean-mobile
  $0 deploy myinfra myserver.example.com admin@myserver.example.com /etc/pki/nginx
EOF
    exit 1
}

# --- Parse --force flag ---
FORCE=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE=true
    shift
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
    usage
fi

COMMAND="${1}"
PREFIX="${2}"
DESTINATION="${SCRIPT_DIR}/_certs-${PREFIX}"
LOG_FILE="${DESTINATION}/generation.log"

load_config "${PREFIX}"

# --- Password ---
if [[ -z "${PASSWORD:-}" ]]; then
    echo "WARNING: No PASSWORD set, using default password '9876543210'."
    echo "         Use PASSWORD=yourpassword $0 ${COMMAND} ${PREFIX} ... for better security."
    PASSWORD="9876543210"
fi

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
# Sanitize a name for use as a filename (replace dots and spaces with dashes)
#-----------------------------
sanitize() {
    echo "${1}" | tr '. ' '--'
}

#-----------------------------
# Create a temporary template by replacing placeholder values
# Args: $1=base_template  $2=output_tmp_file  $3=cn_value
#       $4=host_value (dns or ip, optional)  $5=uid_override (optional)
#-----------------------------
make_template() {
    local base_template="${1}"
    local output="${2}"
    local cn_value="${3}"
    local host_value="${4:-}"
    local uid_override="${5:-}"

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

    # Replace dns_name or ip_address depending on host type
    if [[ -n "${host_value}" ]]; then
        if is_ip_address "${host_value}"; then
            echo "    (detected IP address: using ip_address instead of dns_name)"
            sed -i "s|^dns_name = .*|#dns_name = \"disabled-for-ip\"|" "${output}"
            if grep -q "^#\?ip_address" "${output}"; then
                sed -i "s|^#\?ip_address = .*|ip_address = \"${host_value}\"|" "${output}"
            else
                sed -i "/^# An IP address in case of a server/a ip_address = \"${host_value}\"" "${output}"
            fi
        else
            if grep -q "^dns_name\|^#dns_name" "${output}"; then
                sed -i "s|^#\?dns_name = .*|dns_name = \"${host_value}\"|" "${output}"
            else
                sed -i "/^# A dnsname in case of a WWW server/a dns_name = \"${host_value}\"" "${output}"
            fi
        fi
    fi
}

#-----------------------------
make_root_certificate() {
    check_overwrite "${DESTINATION}/${PREFIX}-root.key" "Root CA"
    local tmp_template
    tmp_template="$(mktemp)"
    echo ">>> Generating root CA certificate (${PREFIX}-root)..."
    make_template \
        "${SCRIPT_DIR}/templ-auth.cfg" \
        "${tmp_template}" \
        "${CA_CN}"
    certtool \
        --generate-privkey \
        --key-type=ecdsa \
        --curve=secp256r1 \
        --no-text \
        --outfile="${DESTINATION}/${PREFIX}-root.key"
    certtool \
        --generate-self-signed \
        --template="${tmp_template}" \
        --load-privkey="${DESTINATION}/${PREFIX}-root.key" \
        --no-text \
        --outfile="${DESTINATION}/${PREFIX}-root.pem"
    rm -f "${tmp_template}"
    echo "    ✓ ${DESTINATION}/${PREFIX}-root.key"
    echo "    ✓ ${DESTINATION}/${PREFIX}-root.pem"
    log_action "INIT    root CA: ${PREFIX}-root  CN=${CA_CN}  expiry=${CA_EXPIRY_DAYS}d"
}

#-----------------------------
# Args: $1=server_name (dns or ip)
#-----------------------------
make_server_certificate() {
    local server_dns="${1}"
    local safe_name
    safe_name="$(sanitize "${server_dns}")"
    local tmp_template
    tmp_template="$(mktemp)"

    check_overwrite "${DESTINATION}/${PREFIX}-server-${safe_name}.key" "server cert '${server_dns}'"
    echo ">>> Generating server certificate for '${server_dns}' (${PREFIX}-server-${safe_name})..."

    make_template \
        "${SCRIPT_DIR}/templ-server.cfg" \
        "${tmp_template}" \
        "${server_dns} server" \
        "${server_dns}" \
        "${safe_name}"

    certtool \
        --generate-privkey \
        --key-type=ecdsa \
        --curve=secp256r1 \
        --no-text \
        --outfile="${DESTINATION}/${PREFIX}-server-${safe_name}.key"
    certtool \
        --generate-certificate \
        --template="${tmp_template}" \
        --load-privkey="${DESTINATION}/${PREFIX}-server-${safe_name}.key" \
        --load-ca-privkey="${DESTINATION}/${PREFIX}-root.key" \
        --load-ca-certificate="${DESTINATION}/${PREFIX}-root.pem" \
        --no-text \
        --outfile="${DESTINATION}/${PREFIX}-server-${safe_name}.pem"
    cat "${DESTINATION}/${PREFIX}-server-${safe_name}.pem" \
        "${DESTINATION}/${PREFIX}-root.pem" \
        > "${DESTINATION}/${PREFIX}-server-${safe_name}.crt"

    rm -f "${tmp_template}"

    echo "    ✓ ${DESTINATION}/${PREFIX}-server-${safe_name}.key"
    echo "    ✓ ${DESTINATION}/${PREFIX}-server-${safe_name}.pem"
    echo "    ✓ ${DESTINATION}/${PREFIX}-server-${safe_name}.crt (full chain)"
    echo "    Verifying server certificate chain..."
    certtool --verify \
        --load-ca-certificate "${DESTINATION}/${PREFIX}-root.pem" \
        --infile "${DESTINATION}/${PREFIX}-server-${safe_name}.pem"
    log_action "SERVER  ${PREFIX}-server-${safe_name}  host=${server_dns}  expiry=${SERVER_EXPIRY_DAYS}d"
}

#-----------------------------
# Args: $1=client_name
#-----------------------------
make_client_certificate() {
    local client_name="${1}"
    local safe_name
    safe_name="$(sanitize "${client_name}")"
    local tmp_template
    tmp_template="$(mktemp)"

    check_overwrite "${DESTINATION}/${PREFIX}-client-${safe_name}.key" "client cert '${client_name}'"
    echo ">>> Generating client certificate for '${client_name}' (${PREFIX}-client-${safe_name})..."

    make_template \
        "${SCRIPT_DIR}/templ-client.cfg" \
        "${tmp_template}" \
        "${client_name} client" \
        "" \
        "${safe_name}"

    certtool \
        --generate-privkey \
        --key-type=ecdsa \
        --curve=secp256r1 \
        --no-text \
        --outfile="${DESTINATION}/${PREFIX}-client-${safe_name}.key"
    certtool \
        --generate-certificate \
        --template="${tmp_template}" \
        --load-privkey="${DESTINATION}/${PREFIX}-client-${safe_name}.key" \
        --load-ca-privkey="${DESTINATION}/${PREFIX}-root.key" \
        --load-ca-certificate="${DESTINATION}/${PREFIX}-root.pem" \
        --no-text \
        --outfile="${DESTINATION}/${PREFIX}-client-${safe_name}.pem"
    cat "${DESTINATION}/${PREFIX}-client-${safe_name}.pem" \
        "${DESTINATION}/${PREFIX}-root.pem" \
        > "${DESTINATION}/${PREFIX}-client-${safe_name}.crt"

    certtool \
        --load-ca-certificate "${DESTINATION}/${PREFIX}-root.pem" \
        --load-privkey "${DESTINATION}/${PREFIX}-client-${safe_name}.key" \
        --load-certificate "${DESTINATION}/${PREFIX}-client-${safe_name}.pem" \
        --to-p12 --p12-name "${PREFIX}@${safe_name}" \
        --password="${PASSWORD}" \
        --outder --outfile "${DESTINATION}/${PREFIX}-client-${safe_name}.pfx"

    rm -f "${tmp_template}"

    echo "    ✓ ${DESTINATION}/${PREFIX}-client-${safe_name}.key"
    echo "    ✓ ${DESTINATION}/${PREFIX}-client-${safe_name}.pem"
    echo "    ✓ ${DESTINATION}/${PREFIX}-client-${safe_name}.crt (full chain)"
    echo "    ✓ ${DESTINATION}/${PREFIX}-client-${safe_name}.pfx (PKCS#12)"
    echo "    Verifying client certificate chain..."
    certtool --verify \
        --load-ca-certificate "${DESTINATION}/${PREFIX}-root.pem" \
        --infile "${DESTINATION}/${PREFIX}-client-${safe_name}.pem"
    log_action "CLIENT  ${PREFIX}-client-${safe_name}  name=${client_name}  expiry=${CLIENT_EXPIRY_DAYS}d"
}

#-----------------------------
# list: display all certs in the prefix directory
#-----------------------------
cmd_list() {
    if [[ ! -d "${DESTINATION}" ]]; then
        echo "ERROR: No certificates found for prefix '${PREFIX}'. Run 'init ${PREFIX}' first."
        exit 1
    fi
    echo "Certificates in ${DESTINATION}/:"
    echo ""
    printf "  %-10s %-45s %-28s %s\n" "TYPE" "FILE" "CN" "EXPIRES"
    printf "  %-10s %-45s %-28s %s\n" "----" "----" "--" "-------"
    for pem in "${DESTINATION}"/*.pem; do
        [[ -f "${pem}" ]] || continue
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
        cn="$(certtool --certificate-info --infile "${pem}" 2>/dev/null \
            | grep -m1 "^\s*Common Name:" | sed 's/.*Common Name: //' || echo "n/a")"
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
        echo "ERROR: Missing cert name. Usage: $0 info ${PREFIX} <name>"
        echo "       Use '$0 list ${PREFIX}' to see available certs."
        exit 1
    fi
    local safe_name
    safe_name="$(sanitize "${name}")"
    local pem=""
    for candidate in \
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
    if [[ ! -d "${DESTINATION}" ]]; then
        echo "ERROR: No certificates found for prefix '${PREFIX}'."
        exit 1
    fi
    local threshold_epoch
    threshold_epoch=$(date -d "+${threshold} days" +%s)
    local found=false
    echo "Checking certificates expiring within ${threshold} days in ${DESTINATION}/:"
    echo ""
    for pem in "${DESTINATION}"/*.pem; do
        [[ -f "${pem}" ]] || continue
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
            else
                echo "  ⚠️  ${days_left} days    ${basename}  (expires ${expiry_str})"
            fi
            found=true
        fi
    done
    if [[ "${found}" == false ]]; then
        echo "  ✅ All certificates are valid for more than ${threshold} days."
    fi
    echo ""
}

#-----------------------------
# revoke: generate a CRL revoking a specific cert
#-----------------------------
cmd_revoke() {
    local name="${1:-}"
    if [[ -z "${name}" ]]; then
        echo "ERROR: Missing cert name. Usage: $0 revoke ${PREFIX} <name>"
        exit 1
    fi
    local safe_name
    safe_name="$(sanitize "${name}")"
    local pem=""
    for candidate in \
        "${DESTINATION}/${PREFIX}-client-${safe_name}.pem" \
        "${DESTINATION}/${PREFIX}-server-${safe_name}.pem"; do
        if [[ -f "${candidate}" ]]; then
            pem="${candidate}"
            break
        fi
    done
    if [[ -z "${pem}" ]]; then
        echo "ERROR: No certificate found for '${name}' in ${DESTINATION}/"
        exit 1
    fi

    echo ">>> Revoking certificate '${name}'..."
    local crl_template
    crl_template="$(mktemp)"
    cat > "${crl_template}" <<EOF
crl_next_update = 365
crl_revocation_date = "$(date -u '+%Y-%m-%d %H:%M:%S')"
EOF
    local crl_out="${DESTINATION}/${PREFIX}-crl.pem"
    certtool --generate-crl \
        --load-ca-privkey "${DESTINATION}/${PREFIX}-root.key" \
        --load-ca-certificate "${DESTINATION}/${PREFIX}-root.pem" \
        --load-certificate "${pem}" \
        --template "${crl_template}" \
        --outfile "${crl_out}"
    rm -f "${crl_template}"
    echo "    ✓ CRL generated: ${crl_out}"
    echo ""
    echo "    To use in Nginx, add to your server block:"
    echo "      ssl_crl ${crl_out};"
    log_action "REVOKE  ${pem}"
}

#-----------------------------
# deploy: copy server cert + root CA to a remote host via scp
#-----------------------------
cmd_deploy() {
    local server_name="${1:-}"
    local remote="${2:-}"
    local remote_dir="${3:-/etc/pki/tls/certs}"

    if [[ -z "${server_name}" || -z "${remote}" ]]; then
        echo "ERROR: Usage: $0 deploy ${PREFIX} <server_name> <user@host> [remote_dir]"
        exit 1
    fi

    local safe_name
    safe_name="$(sanitize "${server_name}")"
    local crt="${DESTINATION}/${PREFIX}-server-${safe_name}.crt"
    local key="${DESTINATION}/${PREFIX}-server-${safe_name}.key"
    local ca="${DESTINATION}/${PREFIX}-root.pem"

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
    echo "    ✓ ${PREFIX}-server-${safe_name}.crt"
    echo "    ✓ ${PREFIX}-server-${safe_name}.key"
    echo "    ✓ ${PREFIX}-root.pem"
    echo ""
    echo "    Update your Nginx config:"
    echo "      ssl_certificate     ${remote_dir}/${PREFIX}-server-${safe_name}.crt;"
    echo "      ssl_certificate_key ${remote_dir}/${PREFIX}-server-${safe_name}.key;"
    echo "      ssl_client_certificate ${remote_dir}/${PREFIX}-root.pem;"
    log_action "DEPLOY  ${PREFIX}-server-${safe_name} -> ${remote}:${remote_dir}"
}

#-----------------------------
# Command dispatch
#-----------------------------
mkdir -p "${DESTINATION}"

case "${COMMAND}" in
    init)
        make_root_certificate
        echo ""
        echo "✅ Root CA generated in ${DESTINATION}/"
        echo "   Now add servers and clients with:"
        echo "   $0 add-server ${PREFIX} <dns_or_ip>"
        echo "   $0 add-client ${PREFIX} <client_name>"
        ;;

    add-server)
        if [[ $# -lt 3 ]]; then
            echo "ERROR: Missing dns_name/ip argument."
            echo "Usage: $0 add-server ${PREFIX} <dns_or_ip>"
            exit 1
        fi
        if [[ ! -f "${DESTINATION}/${PREFIX}-root.key" ]]; then
            echo "ERROR: Root CA not found. Run '$0 init ${PREFIX}' first."
            exit 1
        fi
        make_server_certificate "${3}"
        echo ""
        echo "✅ Server certificate for '${3}' generated in ${DESTINATION}/"
        ;;

    add-client)
        if [[ $# -lt 3 ]]; then
            echo "ERROR: Missing client_name argument."
            echo "Usage: $0 add-client ${PREFIX} <client_name>"
            exit 1
        fi
        if [[ ! -f "${DESTINATION}/${PREFIX}-root.key" ]]; then
            echo "ERROR: Root CA not found. Run '$0 init ${PREFIX}' first."
            exit 1
        fi
        make_client_certificate "${3}"
        echo ""
        echo "✅ Client certificate for '${3}' generated in ${DESTINATION}/"
        ;;

    all)
        if [[ $# -lt 3 ]]; then
            echo "ERROR: Missing dns_name argument."
            echo "Usage: $0 all ${PREFIX} <dns_or_ip> [client_name]"
            exit 1
        fi
        local_dns="${3}"
        local_client="${4:-client}"
        make_root_certificate
        make_server_certificate "${local_dns}"
        make_client_certificate "${local_client}"
        echo ""
        echo "✅ All certificates generated in ${DESTINATION}/"
        ;;

    list)
        cmd_list
        ;;

    info)
        cmd_info "${3:-}"
        ;;

    check-expiry)
        cmd_check_expiry "${3:-90}"
        ;;

    revoke)
        if [[ $# -lt 3 ]]; then
            echo "ERROR: Missing cert name."
            echo "Usage: $0 revoke ${PREFIX} <name>"
            exit 1
        fi
        cmd_revoke "${3}"
        ;;

    deploy)
        if [[ $# -lt 4 ]]; then
            echo "ERROR: Missing arguments."
            echo "Usage: $0 deploy ${PREFIX} <server_name> <user@host> [remote_dir]"
            exit 1
        fi
        cmd_deploy "${3}" "${4}" "${5:-/etc/pki/tls/certs}"
        ;;

    -h|--help)
        usage
        ;;

    *)
        echo "ERROR: Unknown command '${COMMAND}'"
        usage
        ;;
esac
