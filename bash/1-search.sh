#!/bin/bash


set -e


if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path_to_sdk_root>"
    exit 1
fi

if [ ! -d "$1" ]; then
    echo "Error: Directory '$1' does not exist."
    exit 1
fi

project_path="$1"
current_dir="$(realpath "${BASH_SOURCE[0]}")"
echo "current_dir: ${current_dir}"

main(){

    # find ${project_path} -name .git -type l -exec bash -c 'realpath "$(dirname "{}")"' \; | sed 's|/\.git||' | sed 's|^\./||' > subprojects.txt
    find ${project_path} -name .git -type l -exec bash -c 'realpath "$(dirname "{}")"' \;  > subprojects.txt

}

main "$@"