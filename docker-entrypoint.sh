#!/bin/sh
set -e

SYNC=0
for arg in "$@"; do
    shift
    if [ "$arg" = "--sync" ]; then SYNC=1; continue; fi
    set -- "$@" "$arg"
done

if [ "$SYNC" = 1 ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    MODELS_TOML="${MODELS_TOML:-$SCRIPT_DIR/models.toml}"
    CONFIG_INI="${CONFIG_INI:-$SCRIPT_DIR/config.ini}"
    MODELS_DIR="${MODELS_DIR:-$SCRIPT_DIR/models}"
else
    MODELS_TOML="${MODELS_TOML:-/models.toml}"
    CONFIG_INI="${CONFIG_INI:-/config.ini}"
    MODELS_DIR="${MODELS_DIR:-/models}"
fi

[ -f "$MODELS_TOML" ] || { echo "Error: $MODELS_TOML not found" >&2; exit 1; }

# download tool
DL=""
if command -v wget >/dev/null 2>&1; then
    DL="wget -c -O"
elif command -v curl >/dev/null 2>&1; then
    DL="curl -L -o"
else
    echo "Error: need wget or curl" >&2; exit 1
fi

# ── parse models.toml & generate config.ini ────────────────────────────

awk -v config="$CONFIG_INI" -v sh_out="/tmp/models.sh" '
function trim(s) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    gsub(/^"|"$/, "", s)
    return s
}
BEGIN { in_model = 0; n = 0 }
/^\[global\]/     { in_global = 1; in_model = 0; next }
/^\[\[models\]\]/ {
    if (in_model && name != "") flush()
    in_global = 0; in_model = 1
    name = ""; repo = ""; file = ""; mtp_file = ""; mtp_repo = ""
    next
}
in_global && /=/ {
    split($0, a, "=")
    k = a[1]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
    v = trim(a[2])
    if (v == "true")  v = "on"
    if (v == "false") v = "off"
    g[k] = k " = " v
}
in_model {
    if (/^name = /)     name = trim(substr($0, index($0, "=") + 2))
    if (/^repo = /)     repo = trim(substr($0, index($0, "=") + 2))
    if (/^file = /)     file = trim(substr($0, index($0, "=") + 2))
    if (/^mtp-repo = /) mtp_repo = trim(substr($0, index($0, "=") + 2))
    if (/^mtp-file = /) mtp_file = trim(substr($0, index($0, "=") + 2))
}
function flush() {
    n_ = n
    models_name[n_] = name; models_repo[n_] = repo
    models_file[n_] = file; models_mtp[n_] = mtp_file
    models_mtpr[n_] = mtp_repo
    n++
}
END {
    if (in_model && name != "") flush()

    # write config.ini
    printf "[*]\n" > config
    for (k in g) print g[k] > config
    printf "\n" > config
    for (i = 0; i < n; i++) {
        printf "[%s]\n", models_name[i] > config
        printf "model = /models/%s\n", models_file[i] > config
        if (models_mtp[i] != "") {
            printf "model-draft = /models/%s\n", models_mtp[i] > config
        }
        printf "\n" > config
    }
    close(config)

    # write shell-sourcable model data
    printf "MODEL_COUNT=%d\n", n > sh_out
    for (i = 0; i < n; i++) {
        printf "MODEL_NAME_%d=%s\n", i, models_name[i] > sh_out
        printf "MODEL_REPO_%d=%s\n", i, models_repo[i] > sh_out
        printf "MODEL_FILE_%d=%s\n", i, models_file[i] > sh_out
        printf "MODEL_MTP_%d=%s\n", i, models_mtp[i] > sh_out
        printf "MODEL_MTPR_%d=%s\n", i, models_mtpr[i] > sh_out
    }
    close(sh_out)
}
' "$MODELS_TOML"

echo "Generated $CONFIG_INI"

. /tmp/models.sh
rm -f /tmp/models.sh

[ "$MODEL_COUNT" -gt 0 ] || {
    echo "Warning: no models defined"
    [ "$SYNC" = 1 ] && exit 0
    exec ./llama-server "$@"
}

# ── download missing models ────────────────────────────────────────────

i=0
while [ "$i" -lt "$MODEL_COUNT" ]; do
    eval name='$MODEL_NAME_'"$i"
    eval repo='$MODEL_REPO_'"$i"
    eval file='$MODEL_FILE_'"$i"
    eval mtp='$MODEL_MTP_'"$i"
    eval mtpr='$MODEL_MTPR_'"$i"

    echo "$name"
    local_path="$MODELS_DIR/$file"

    if [ -f "$local_path" ]; then
        echo "  ✓  exists"
    else
        echo "  ↓  Downloading..."
        mkdir -p "$(dirname "$local_path")"
        $DL "$local_path.tmp" "https://huggingface.co/$repo/resolve/main/$file" && mv "$local_path.tmp" "$local_path" || { rm -f "$local_path.tmp"; exit 1; }
        echo "  ✓  done"
    fi

    if [ -n "$mtp" ]; then
        mtp_path="$MODELS_DIR/$mtp"
        if [ -f "$mtp_path" ]; then
            echo "  MTP: $(basename "$mtp") - exists"
        else
            echo "  ↓  Downloading MTP: $(basename "$mtp")..."
            mkdir -p "$(dirname "$mtp_path")"
            $DL "$mtp_path.tmp" "https://huggingface.co/${mtpr:-$repo}/resolve/main/$mtp" && mv "$mtp_path.tmp" "$mtp_path" || { rm -f "$mtp_path.tmp"; exit 1; }
            echo "  ✓  done"
        fi
    fi

    i=$((i + 1))
done

# ── start llama-server ─────────────────────────────────────────────────

[ "$SYNC" = 1 ] && { echo "✓  Sync complete"; exit 0; }

exec ./llama-server --models-preset /config.ini --jinja --no-mmap -fa on --sleep-idle-seconds 600 --threads 8 --threads-batch 16 --batch-size 512 --host 0.0.0.0 --port 8080 --verbose
