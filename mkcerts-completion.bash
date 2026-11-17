# Bash completion for mkcerts.sh
# To enable: source mkcerts-completion.bash

_mkcerts_completions() {
    local cur prev words cword
    
    # Use _get_comp_words_by_ref if available, otherwise fallback to COMP_WORDS
    if declare -F _get_comp_words_by_ref >/dev/null; then
        _get_comp_words_by_ref -n : cur prev words cword
    else
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
    fi

    local commands="init add-server add-client all list info check-expiry revoke unrevoke clear-crl deploy export-client migrate"
    local flags="--force"

    # Identify command position (skip flags)
    local cmd=""
    local cmd_idx=1
    for ((i=1; i<cword; i++)); do
        if [[ "${words[i]}" != "--force" ]]; then
            cmd_idx=$i
            break
        fi
    done
    cmd="${words[$cmd_idx]}"

    # 1. Completion for the command itself or flags
    if [[ $cword -eq 1 ]] || { [[ $cword -eq 2 ]] && [[ "${words[1]}" == "--force" ]]; }; then
        if [[ "$cur" == -* ]]; then
             COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
        else
             COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        fi
        return 0
    fi

    # 2. Completion for the prefix (usually following the command)
    if [[ $cword -eq $((cmd_idx + 1)) ]]; then
        local prefixes=$(find . -maxdepth 1 -type d -name "_certs-*" 2>/dev/null | sed 's|./_certs-||' | sort | uniq || true)
        COMPREPLY=( $(compgen -W "$prefixes" -- "$cur") )
        return 0
    fi

    # 3. Completion for certificate names (following the prefix)
    if [[ $cword -eq $((cmd_idx + 2)) ]]; then
        local prefix="${words[$((cmd_idx + 1))]}"
        local cert_dir="_certs-$prefix"
        if [[ -d "$cert_dir" ]]; then
            case "$cmd" in
                info|revoke|unrevoke)
                    # List all server and client names (new directory layout and legacy flat)
                    local names=()
                    if [[ -d "$cert_dir/servers" ]]; then
                        names+=( $(find "$cert_dir/servers" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null) )
                    fi
                    if [[ -d "$cert_dir/clients" ]]; then
                        names+=( $(find "$cert_dir/clients" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null) )
                    fi
                    local flat_names=$(find "$cert_dir" -maxdepth 1 -name "*.pem" 2>/dev/null | xargs -n1 basename 2>/dev/null | sed -e "s/^$prefix-//" -e "s/^client-//" -e "s/^server-//" -e "s/.pem$//" || true)
                    names+=( $flat_names )
                    local unique_names=$(printf "%s\n" "${names[@]}" | sort -u | tr '\n' ' ')
                    COMPREPLY=( $(compgen -W "$unique_names" -- "$cur") )
                    ;;
                deploy)
                    # List only server names
                    local names=()
                    if [[ -d "$cert_dir/servers" ]]; then
                        names+=( $(find "$cert_dir/servers" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null) )
                    fi
                    local flat_names=$(find "$cert_dir" -maxdepth 1 -name "$prefix-server-*.pem" 2>/dev/null | xargs -n1 basename 2>/dev/null | sed -e "s/^$prefix-server-//" -e "s/.pem$//" || true)
                    names+=( $flat_names )
                    local unique_names=$(printf "%s\n" "${names[@]}" | sort -u | tr '\n' ' ')
                    COMPREPLY=( $(compgen -W "$unique_names" -- "$cur") )
                    ;;
                export-client)
                    # List only client names
                    local names=()
                    if [[ -d "$cert_dir/clients" ]]; then
                        names+=( $(find "$cert_dir/clients" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null) )
                    fi
                    local flat_names=$(find "$cert_dir" -maxdepth 1 -name "$prefix-client-*.pem" 2>/dev/null | xargs -n1 basename 2>/dev/null | sed -e "s/^$prefix-client-//" -e "s/.pem$//" || true)
                    names+=( $flat_names )
                    local unique_names=$(printf "%s\n" "${names[@]}" | sort -u | tr '\n' ' ')
                    COMPREPLY=( $(compgen -W "$unique_names" -- "$cur") )
                    ;;
            esac
        fi
        return 0
    fi
}

# Apply completion to both ./mkcerts.sh and mkcerts.sh (if in PATH)
complete -F _mkcerts_completions ./mkcerts.sh
complete -F _mkcerts_completions mkcerts.sh
