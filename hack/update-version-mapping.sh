#!/usr/bin/env bash

set -euo pipefail

function usage() {
    cat <<EOF
usage: $0 (-m|--message_file) <message_file> (-i|--input_file) <version_mapping_file>
EOF

}

if [ "$#" -lt 4 ]; then
    usage
    exit 1
fi

while [ "$#" -gt 0 ]; do
    case $1 in
    -m | --message_file)
        message_file="$2"
        [ ! -f "$message_file" ] && (
            usage
            echo "File $message_file does not exist!"
            exit 1
        )
        shift
        shift
        ;;
    -i | --input_file)
        original_input_file="$2"
        [ ! -f "$original_input_file" ] && (
            usage
            echo "File $original_input_file does not exist!"
            exit 1
        )
        shift
        shift
        ;;
    *)
        usage
        exit 1
        ;;
    esac
done

tmp_version_mapping_file=$(mktemp "/tmp/$original_input_file.XXXXXXXXX")

jq '. + '"$(jq -r '{ (.artifact.nvr | split("-")[-2] | split(".")[0:2] | join(".") | ltrimstr("v")): { "index_image": .index.index_image, "bundle_version": (.index.added_bundle_images[] | select(. | contains("hco-bundle-registry")) | split(":") | .[1] ) } }' "$message_file")" "$original_input_file" >"$tmp_version_mapping_file"

rm -f "$original_input_file"
mv "$tmp_version_mapping_file" "$original_input_file"
