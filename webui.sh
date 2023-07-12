#!/usr/bin/env bash
#################################################
# Please do not make any changes to this file,  #
# change the variables in webui-user.sh instead #
#################################################

# If run from macOS, load defaults from webui-macos-env.sh
if [[ "$OSTYPE" == "darwin"* ]]; then
    if [[ -f webui-macos-env.sh ]]
        then
        source ./webui-macos-env.sh
    fi
fi

# Read variables from webui-user.sh
# shellcheck source=/dev/null
if [[ -f webui-user.sh ]]
then
    source ./webui-user.sh
fi

# Set defaults
# Install directory without trailing slash
if [[ -z "${install_dir}" ]]
then
    install_dir="$(pwd)"
fi

# Name of the subdirectory (defaults to stable-diffusion-webui)
if [[ -z "${clone_dir}" ]]
then
    clone_dir="stable-diffusion-controlnet-webui-databricks"
fi

# python3 executable
if [[ -z "${python_cmd}" ]]
then
    python_cmd="python3"
fi

# git executable
if [[ -z "${GIT}" ]]
then
    export GIT="git"
fi

# python3 venv without trailing slash (defaults to ${install_dir}/${clone_dir}/venv)
if [[ -z "${venv_dir}" ]]
then
    venv_dir="venv"
fi

if [[ -z "${LAUNCH_SCRIPT}" ]]
then
    LAUNCH_SCRIPT="launch.py"
fi

# this script cannot be run as root by default
# EDIT - We hardcode this as 1 as executing script in ephemeral cluster tends to default as root
can_run_as_root=1

# read any command line flags to the webui.sh script
while getopts "f" flag > /dev/null 2>&1
do
    case ${flag} in
        f) can_run_as_root=1;;
        *) break;;
    esac
done

# Disable sentry logging
export ERROR_REPORTING=FALSE

# Do not reinstall existing pip packages on Debian/Ubuntu
export PIP_IGNORE_INSTALLED=0

# Pretty print
delimiter="################################################################"

printf "\n%s\n" "${delimiter}"
printf "\e[1m\e[32mInstall script for stable-diffusion + Web UI\n"
printf "\e[1m\e[34mTested on Debian 11 (Bullseye)\e[0m"
printf "\n%s\n" "${delimiter}"

# Function to automatically install models
download_models_from_file() {  
    local models_file="$1"  
    local dest_dir="$2" 
    while IFS= read -r file_url; do  
        local file_name="$(basename "${file_url}")"  
  
        if [ ! -f "${dest_dir}/${file_name}" ]; then  
            printf "\n%s\n" "${delimiter}"
            printf "download ${file_name}"  
            printf "\n%s\n" "${delimiter}"
            wget -P "${dest_dir}/" "${file_url}" --content-disposition 
        fi  
    done < "${models_file}"  
}

# Function to go into submodule and checkout to master/main branch
checkout_to_main_for_submodule(){
  local current_dir=$(pwd)  
  local submodule_paths=$(git submodule foreach --quiet 'echo $path')  
  
  for submodule_path in $submodule_paths; do  
    cd "$current_dir/$submodule_path" || return  
    echo "Checking out to main in : $submodule_path"  
    "${GIT}" checkout $("${GIT}" remote show origin | grep 'HEAD branch' | cut -d' ' -f5)
    "${GIT}" pull origin $("${GIT}" remote show origin | grep 'HEAD branch' | cut -d' ' -f5)  
  done  
  
  cd "$current_dir" || return  
}  
# Do not run as root
if [[ $(id -u) -eq 0 && can_run_as_root -eq 0 ]]
then
    printf "\n%s\n" "${delimiter}"
    printf "\e[1m\e[31mERROR: This script must not be launched as root, aborting...\e[0m"
    printf "\n%s\n" "${delimiter}"
    exit 1
else
    printf "\n%s\n" "${delimiter}"
    printf "Running on \e[1m\e[32m%s\e[0m user" "$(whoami)"
    printf "\n%s\n" "${delimiter}"
fi

if [[ $(getconf LONG_BIT) = 32 ]]
then
    printf "\n%s\n" "${delimiter}"
    printf "\e[1m\e[31mERROR: Unsupported Running on a 32bit OS\e[0m"
    printf "\n%s\n" "${delimiter}"
    exit 1
fi

if [[ -d .git ]]
then
    printf "\n%s\n" "${delimiter}"
    printf "Repo already cloned, using it as install directory"
    printf "\n%s\n" "${delimiter}"
    install_dir="${PWD}/../"
    clone_dir="${PWD##*/}"
fi

# Check prerequisites
gpu_info=$(lspci 2>/dev/null | grep -E "VGA|Display")
case "$gpu_info" in
    *"Navi 1"*)
        export HSA_OVERRIDE_GFX_VERSION=10.3.0
        if [[ -z "${TORCH_COMMAND}" ]]
        then
            pyv="$(${python_cmd} -c 'import sys; print(".".join(map(str, sys.version_info[0:2])))')"
            if [[ $(bc <<< "$pyv <= 3.10") -eq 1 ]] 
            then
                # Navi users will still use torch 1.13 because 2.0 does not seem to work.
                export TORCH_COMMAND="pip install torch==1.13.1+rocm5.2 torchvision==0.14.1+rocm5.2 --index-url https://download.pytorch.org/whl/rocm5.2"
            else
                printf "\e[1m\e[31mERROR: RX 5000 series GPUs must be using at max python 3.10, aborting...\e[0m"
                exit 1
            fi
        fi
    ;;
    *"Navi 2"*) export HSA_OVERRIDE_GFX_VERSION=10.3.0
    ;;
    *"Renoir"*) export HSA_OVERRIDE_GFX_VERSION=9.0.0
        printf "\n%s\n" "${delimiter}"
        printf "Experimental support for Renoir: make sure to have at least 4GB of VRAM and 10GB of RAM or enable cpu mode: --use-cpu all --no-half"
        printf "\n%s\n" "${delimiter}"
    ;;
    *)
    ;;
esac
if ! echo "$gpu_info" | grep -q "NVIDIA";
then
    if echo "$gpu_info" | grep -q "AMD" && [[ -z "${TORCH_COMMAND}" ]]
    then
        export TORCH_COMMAND="pip install torch==2.0.1+rocm5.4.2 torchvision==0.15.2+rocm5.4.2 --index-url https://download.pytorch.org/whl/rocm5.4.2"
    fi
fi

for preq in "${GIT}" "${python_cmd}"
do
    if ! hash "${preq}" &>/dev/null
    then
        printf "\n%s\n" "${delimiter}"
        printf "\e[1m\e[31mERROR: %s is not installed, aborting...\e[0m" "${preq}"
        printf "\n%s\n" "${delimiter}"
        exit 1
    fi
done

if ! "${python_cmd}" -c "import venv" &>/dev/null
then
    printf "\n%s\n" "${delimiter}"
    printf "\e[1m\e[31mERROR: python3-venv is not installed, aborting...\e[0m"
    printf "\n%s\n" "${delimiter}"
    exit 1
fi

cd "${install_dir}"/ || { printf "\e[1m\e[31mERROR: Can't cd to %s/, aborting...\e[0m" "${install_dir}"; exit 1; }
if [[ -d "${clone_dir}" ]]
then
    cd "${clone_dir}"/ || { printf "\e[1m\e[31mERROR: Can't cd to %s/%s/, aborting...\e[0m" "${install_dir}" "${clone_dir}"; exit 1; }
else
    printf "\n%s\n" "${delimiter}"
    printf "Clone stable-diffusion-webui"
    printf "\n%s\n" "${delimiter}"
    "${GIT}" clone https://github.com/cvives-cvent/stable-diffusion-controlnet-webui-databricks.git "${clone_dir}"
    cd "${clone_dir}"/ || { printf "\e[1m\e[31mERROR: Can't cd to %s/%s/, aborting...\e[0m" "${install_dir}" "${clone_dir}"; exit 1; }
    "${GIT}" checkout preconfig || { printf "\e[1m\e[31mERROR: Can't checkout to feature branch, aborting...\e[0m"; exit 1; }
    "${GIT}" submodule update --init --recursive  || { printf "\e[1m\e[31mERROR: Can't git submodule init, aborting...\e[0m"; exit 1; }
    "${GIT}" submodule update --recursive || { printf "\e[1m\e[31mERROR: Can't git submodule update, aborting...\e[0m"; exit 1; }
    checkout_to_main_for_submodule
fi

# Read variables from webui-user.sh
# we repeat this after installation as there are some variables that read from repo files
# shellcheck source=/dev/null
if [[ -f webui-user.sh ]]
then
    source ./webui-user.sh
fi

# Activate or create python evironment. Will always create if NO_DEFAULT_VENV exists
if [[ -z "${VIRTUAL_ENV}"  || ! -z "${NO_DEFAULT_VENV}" ]];
then
    printf "\n%s\n" "${delimiter}"
    printf "Create and activate python venv"
    printf "\n%s\n" "${delimiter}"
    cd "${install_dir}"/"${clone_dir}"/ || { printf "\e[1m\e[31mERROR: Can't cd to %s/%s/, aborting...\e[0m" "${install_dir}" "${clone_dir}"; exit 1; }
    if [[ ! -d "${venv_dir}" ]]
    then
        "${python_cmd}" -m venv "${venv_dir}"
        first_launch=1
    fi
    # shellcheck source=/dev/null
    if [[ -f "${venv_dir}"/bin/activate ]]
    then
        source "${venv_dir}"/bin/activate
    else
        printf "\n%s\n" "${delimiter}"
        printf "\e[1m\e[31mERROR: Cannot activate python venv, aborting...\e[0m"
        printf "\n%s\n" "${delimiter}"
        exit 1
    fi
else
    printf "\n%s\n" "${delimiter}"
    printf "python venv already activate: ${VIRTUAL_ENV}"
    printf "\n%s\n" "${delimiter}"
fi


# Dowwnload models if MODELS_TO_DOWNLOAD is set  
if [[ -f "${MODELS_TO_DOWNLOAD}" ]]; then  
     download_models_from_file "${MODELS_TO_DOWNLOAD}"  "${install_dir}/${clone_dir}/extensions/sd-webui-controlnet/models"
else  
    printf "\n%s\n" "${delimiter}"
    printf "The file '${MODELS_TO_DOWNLOAD}' does not exist. Skipping model download."  
    printf "\n%s\n" "${delimiter}"
fi  
  
# Dowwnload models if STABLE_DIFFUSION_MODELS_TO_DOWNLOAD is set  
if [[ -f "${STABLE_DIFFUSION_MODELS_TO_DOWNLOAD}" ]]; then  
     download_models_from_file "${STABLE_DIFFUSION_MODELS_TO_DOWNLOAD}"  "${install_dir}/${clone_dir}/models/Stable-diffusion"
else  
    printf "\n%s\n" "${delimiter}"
    printf "The file '${STABLE_DIFFUSION_MODELS_TO_DOWNLOAD}' does not exist. Skipping model download."  
    printf "\n%s\n" "${delimiter}"
fi
    
# Download models if LORA_MODELS_TO_DOWNLOAD is set  
if [[ -f "${LORA_MODELS_TO_DOWNLOAD}" ]]; then  
     download_models_from_file "${LORA_MODELS_TO_DOWNLOAD}"  "${install_dir}/${clone_dir}/models/Lora"
else  
    printf "\n%s\n" "${delimiter}"
    printf "The file '${LORA_MODELS_TO_DOWNLOAD}' does not exist. Skipping model download."  
    printf "\n%s\n" "${delimiter}"
fi
    
# Download embeddings if EMBEDDINGS_TO_DOWNLOAD is set  
if [[ -f "${EMBEDDINGS_TO_DOWNLOAD}" ]]; then  
     download_models_from_file "${EMBEDDINGS_TO_DOWNLOAD}"  "${install_dir}/${clone_dir}/embeddings"
else  
    printf "\n%s\n" "${delimiter}"
    printf "The file '${EMBEDDINGS_TO_DOWNLOAD}' does not exist. Skipping model download."  
    printf "\n%s\n" "${delimiter}"
fi    

prepare_tcmalloc() {
    if [[ "${OSTYPE}" == "linux"* ]] && [[ -z "${NO_TCMALLOC}" ]] && [[ -z "${LD_PRELOAD}" ]]; then
        TCMALLOC="$(PATH=/usr/sbin:$PATH ldconfig -p | grep -Po "libtcmalloc(_minimal|)\.so\.\d" | head -n 1)"
        if [[ ! -z "${TCMALLOC}" ]]; then
            echo "Using TCMalloc: ${TCMALLOC}"
            export LD_PRELOAD="${TCMALLOC}"
        else
            printf "\e[1m\e[31mCannot locate TCMalloc (improves CPU memory usage)\e[0m\n"
        fi
    fi
}


KEEP_GOING=1
export SD_WEBUI_RESTART=tmp/restart
while [[ "$KEEP_GOING" -eq "1" ]]; do
    if [[ ! -z "${ACCELERATE}" ]] && [ ${ACCELERATE}="True" ] && [ -x "$(command -v accelerate)" ]; then
        printf "\n%s\n" "${delimiter}"
        printf "Accelerating launch.py..."
        printf "\n%s\n" "${delimiter}"
        prepare_tcmalloc
        accelerate launch --num_cpu_threads_per_process=6 "${LAUNCH_SCRIPT}" "$@"
    else
        printf "\n%s\n" "${delimiter}"
        printf "Launching launch.py..."
        printf "\n%s\n" "${delimiter}"
        prepare_tcmalloc
        "${python_cmd}" "${LAUNCH_SCRIPT}" "$@"
    fi

    if [[ ! -f tmp/restart ]]; then
        KEEP_GOING=0
    fi
done
