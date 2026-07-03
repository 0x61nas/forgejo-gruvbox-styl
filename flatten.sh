#!/bin/sh
# flatten.sh — Convert a Stylus (.styl) theme file into flattened plain CSS
#
# Usage:
#   ./flatten.sh [--strip-important] <input.styl> <variant> [output.css]

set -eu

strip_important=0
input=""
variant=""
output=""

while [ $# -gt 0 ]; do
    case "$1" in
        --strip-important)
            strip_important=1
            ;;
        -*)
            echo "Usage: $0 [--strip-important] <input.styl> <variant> [output.css]" >&2
            exit 1
            ;;
        *)
            if [ -z "$input" ]; then
                input="$1"
            elif [ -z "$variant" ]; then
                variant="$1"
            elif [ -z "$output" ]; then
                output="$1"
            else
                echo "flatten.sh: too many arguments" >&2
                exit 1
            fi
            ;;
    esac
    shift
done

if [ -z "$input" ] || [ -z "$variant" ]; then
    echo "Usage: $0 [--strip-important] <input.styl> <variant> [output.css]" >&2
    exit 1
fi

if [ ! -f "$input" ]; then
    echo "flatten.sh: input file not found: $input" >&2
    exit 1
fi

case "$variant" in
    light-soft) variant_full="light-soft-theme-variant"  ;;
    light)      variant_full="light-theme-variant"       ;;
    light-hard) variant_full="light-hard-theme-variant"  ;;
    dark-soft)  variant_full="dark-soft-theme-variant"   ;;
    dark)       variant_full="dark-theme-variant"        ;;
    dark-hard)  variant_full="dark-hard-theme-variant"   ;;
    *)
        # Accept full variant name directly
        variant_full="$variant"
        ;;
esac

# ---------------------------------------------------------------------------
# Extract metadata from the UserStyle header
# ---------------------------------------------------------------------------
name=$(grep '^@name[[:space:]]' "$input" | sed 's/^@name[[:space:]]*//')
version=$(grep '^@version[[:space:]]' "$input" | sed 's/^@version[[:space:]]*//')
repo=$(grep '^@homepageURL' "$input" | sed 's/^@homepageURL[[:space:]]*//')
license=$(grep '^@license[[:space:]]' "$input" | sed 's/^@license[[:space:]]*//')

# Defaults if not found
: "${name:=Forgejo Gruvbox}"
: "${version:=1.0.0}"
: "${repo:=https://github.com/0x61nas/forgejo-gruvbox-styl}"
: "${license:=MIT}"

gen_header="/*
 * Theme: $name
 * Version: $version
 * Repository: $repo
 * License: $license
 */"

# ---------------------------------------------------------------------------
# Awk processor — handles header removal, @-moz-document removal,
#                  variant conditional evaluation, and CSS output
# ---------------------------------------------------------------------------
process_awk() {
    awk \
        -v variant="$variant_full" \
        -v gen_header="$gen_header" \
        '
function brace_net(s) {
    n = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "{") n++
        if (c == "}") n--
    }
    return n
}

BEGIN {
    state = "header"
    depth = 0
    cond_state = "none"
    cond_depth = 0
    in_hdr = 0
    in_doc = 0
    header_printed = 0
    variant_root_buf = ""
    in_variant_root = 0
    var_root_depth = 0
    in_shared_root = 0
    shared_root_depth = 0
}

# Print generated header once at the very beginning
!header_printed {
    print gen_header
    header_printed = 1
}

# === State: header — skip the UserStyle metadata comment ===
state == "header" {
    if (/^\/\* ==UserStyle==/) { in_hdr = 1 }
    if (in_hdr) {
        if (/^==\/UserStyle== \*\/$/) {
            in_hdr = 0
            state = "body"
        }
        next
    }
    state = "body"
}

# === State: body ===
# Skip @-moz-document domain(...) wrapper
/^@-moz-document/ { in_doc = 1; next }
in_doc && /\{$/    { in_doc = 0; next }
in_doc             { next }

# === Variant conditional handling ===
{
    if (/^(    )?if theme-variant is / || /^(    )?else if theme-variant is /) {
        if (cond_state == "done") {
            cond_state = "skip"
            cond_depth = brace_net($0)
            next
        }
        if (index($0, variant)) {
            cond_state = "capture"
            cond_depth = brace_net($0)
        } else {
            cond_state = "skip"
            cond_depth = brace_net($0)
        }
        next
    }
}

cond_state == "skip" {
    cond_depth += brace_net($0)
    if (cond_depth <= 0) cond_state = "none"
    next
}

cond_state == "capture" {
    cond_depth += brace_net($0)
    if (cond_depth <= 0) { cond_state = "done"; next }

    # Enter variant :root — buffer its content for merging
    if (/^\s+:root\s*\{\s*$/) {
        in_variant_root = 1
        var_root_depth = 1
        next
    }

    if (in_variant_root) {
        var_root_depth += brace_net($0)
        if (var_root_depth <= 0) {
            in_variant_root = 0
            if (cond_depth <= 0) cond_state = "done"
            next
        }
        gsub(/^[[:space:]]+/, "", $0)
        variant_root_buf = variant_root_buf "    " $0 "\n"
        if (cond_depth <= 0) cond_state = "done"
        next
    }
}

# === Regular content (outside or past conditionals) ===
{
    sub(/^    /, "", $0)
    bn = brace_net($0)

    # Shared :root — merge variant properties here
    if (/^:root\s*\{\s*$/) {
        in_shared_root = 1
        shared_root_depth = 1
        depth += bn
        print ":root {"
        if (variant_root_buf != "") {
            printf "%s", variant_root_buf
        }
        next
    }

    if (in_shared_root) {
        shared_root_depth += bn
        depth += bn
        if (shared_root_depth <= 0) {
            print "}"
            in_shared_root = 0
            next
        }
        print $0
        next
    }

    depth += bn
    if (depth < 0) next
    print
}
' "$1"
}

if [ "$strip_important" -eq 1 ]; then
    if [ -n "$output" ]; then
        process_awk "$input" | sed 's/[[:space:]]*!important//g' > "$output"
    else
        process_awk "$input" | sed 's/[[:space:]]*!important//g'
    fi
else
    if [ -n "$output" ]; then
        process_awk "$input" > "$output"
    else
        process_awk "$input"
    fi
fi
