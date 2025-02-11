#!/bin/bash -i

#
# Copyright (C) 2021 IBM. All Rights Reserved.
#
# See the LICENSE file in the root directory
# of this source tree for licensing information.
#

#
# DeployToHPVS.sh
# ---------------
#     Sign a FHE Toolkit Docker image and deploy it to a Hyper Protect Virtual
#     Server (HPVS) instance in the IBM public cloud.
# 
# Author(s)
# ---------
#     Lei A.B. Wang <wlwangwl@cn.ibm.com>
#     Dan FitzGerald <danfitz@us.ibm.com>                    
# 
# Usage
# -----
#                           .-------------.
#                           V             |  .-- fedora --.
#     >>-- DeployToHPVS.sh ---| OPTIONS |-'--+------------+------------------><
#                                            :-- alpine --:
#                                            '-- ubuntu --'
#     
#   Arguments:
#
#       fedora
#       alpine
#       ubuntu         Name of the s390x FHE Toolkit container variant that you
#                      wish to deploy.  If unspecified, defaults to "fedora".
#
#   Options:
#
#       -c configFile  Generate a new configuration file at the given path using
#                      an interactive wizard.  The new configuration file with
#                      the name and path specified.  Mutually exclusive with -f.
#
#       -f configFile  Path to the configuration file for this script.  If left
#                      unspecified, the script will use the default file
#                      DeployToHPVS.conf, located in the same directory as the
#                      script.  Mutually exclusive with -c.
#
#       -h             Display this help information
#
#       -l             Deploy a locally-built FHE Toolkit container image
#                      generated by BuildDockerImage.sh.  If left unspecified,
#                      this script will assume that you are deploying a
#                      pre-built toolkit fetched from from
#                      https://hub.docker.com/u/ibmcom on DockerHub.
# 
# Requirements
# ------------
#     - Docker CE or EE must be installed, as this script utilizes the
#       `docker trust` command.
#
# Notes
# -----
#   1. Only Alpine, Fedora, and Ubuntu are supported as container operating
#      systems as those are the only ones that the FHE Toolkit for Linux project
#      has built for s390x.
#
#   2. The default behavior of this script is to attempt to use the ibmcom
#      pre-built toolkit available from Docker Hub.  This behavior can be
#      overridden with the -l option flag.
#
#   3. By default, all commands executed by these functions are silenced
#      except for when a nonzero RC is returned.  To display the commands
#      being executed and their output, issue: `export DEPLOY_TO_HPVS_DEBUG=1`.
#

################################################################################
########          Define constants and import subroutines               ########
################################################################################

# Define script constant variables
CONTAINER_MODE=ibmcom   # Default to using a container pulled from Docker Hub
DIRNAME="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
FILENAME=$(basename $0)
MANPAGE=$DIRNAME/${FILENAME%%.*}.1
NPARAM=$#               # The number of parameters passed to this script
PROGNAME=${FILENAME%%.*}

# Program default values
DEFAULT_CONFIG_FILE="${PROGNAME}.conf"
DEFAULT_HPVS_NAME='fhetoolkit-s390x-sample'
DEFAULT_LOCATION='dal13'
DEFAULT_REGISTRATION_FILE="hpvs-fhe-registration.txt"
DEFAULT_RESOURCE_PLAN_ID='bb0005a1-ec13-4ee4-86f4-0c3b15a357d5'

# TODO: Update when changing the directory structure
source ${DIRNAME}/../ConfigConstants.sh

# Import script subroutines
source ${DIRNAME}/${PROGNAME}.bashlib

################################################################################
########          Process command-line options and arguments            ########
################################################################################

# Process command-line options
c_specified=false
f_specified=false
while getopts "c:f:hl" opt; do
  case ${opt} in
    c )
      configFile=$OPTARG
      c_specified=true
      ;;
    f ) # deploy to HPVS config file
      configFile=$OPTARG
      f_specified=true
      ;;
    h ) # Usage
      print_usage $MANPAGE
      exit 0
      ;;
    l ) # Run locally built contalinern_flag_specified
      CONTAINER_MODE=local
      ;;
    \? ) # Usage
      print_usage $MANPAGE
      exit 0
      ;;
    : ) # Invalid option. Print usage
      print_fatal_and_usage "Invalid option: - $OPTARG requires an argument"
      ;;
  esac
done

# Make sure the -c and -f options weren't both specified
if [[ "$c_specified" == true ]] && [[ "$f_specified" == true ]]; then
    print_fatal_and_usage "-c and -f options are mutually exclusive"
fi

# If -c was specified, make sure that a file doesn't already exist
if [[ "$c_specified" == true ]] && [[ -e "$configFile" ]]; then
    fatal_error "A file named '$configFile' already exists"

# If the -f option wasn't passed, use the default config file
elif [ -z "$configFile" ]; then
    configFile=$DEFAULT_CONFIG_FILE
fi

# Isolate the last token, that must be our platform
shift $((OPTIND-1))
OPTINDNUMBER=$((OPTIND-1))
platform=$1

# Determine which container distributuon to launch
if ! [ "$platform" ]
then
    platform="fedora"
    write_info "Missing OS platform name - using default value '${platform}'"
else
    # Convert our platform name to all lowercase for comparison's sake
    platform="$(echo $platform | tr '[:upper:]' '[:lower:]')"
fi

if [[ "$platform" = "alpine" ]]
then
    platform="alpine" 
elif [[ "$platform" = "fedora" ]]
then
    platform="fedora"
elif [[ "$platform" = "ubuntu" ]]
then
    platform="ubuntu"
else
    # Issue our error message with the original value the user gave for 'platform'
    print_fatal_and_usage "Invalid value: '$1' - Please specify a supported platform"
fi

# If the -c flag was specified, launch the config file creation wizard
if [[ "$c_specified" == true ]]; then
    config_file_wizard $configFile
fi

# Read the config file
read_config $configFile

write_info "HPVS deployment of ${hpvsName} will now begin"

################################################################################
########             Prepare the image for HPVS deployment              ########
################################################################################

# First we determine which architecture we are running on... AMD64 or s390x
ARCH=`uname -m`
echo "$ARCH"
# Check for local vs. DockerHub build choice
if [ ${CONTAINER_MODE}x == "local"x ]; then
  #If the arch is Intel, the HPVS only runs s390x images so exit here with reasons why
  if [[ "$ARCH" == "x86_64" ]] || [[ "$ARCH" == "amd64" ]]; then
    fatal_error "Sorry, images built for Intel based architectures do not work with Hyper Protect.  Please choose an image pre-built for s390x instead.  The -l option relies on a locally built image, remove this and try again."
  fi
  FHEkit_image_name=local/fhe-toolkit-${platform}-s390x
elif [ ${CONTAINER_MODE}x == "ibmcom"x ]; then
  #image name is supposed ot be s390x, if this imahge is not in the local file system, do the docker fetch to pull it for you
  #we know we need the s390 image, if we don't find the list of images that match tha pull it and do it
  # check here ot make sure its there, and then delete it when its done
  #if we don't see any exact match fr the the imaghe name, then docker pull and grab the latest
  
  FHEkit_image_name=ibmcom/fhe-toolkit-${platform}-s390x
  docker pull $FHEkit_image_name
else
  print_fatal_and_usage "Container mode $CONTAINER_MODE is invalid"
fi

# Set the repo/image name and version
repo="fhe-toolkit-${platform}-s390x"
tag="$HElib_version"
target_image_name=${namespace}/${repo}
if [[ -z $registryURL ]] ; then
    registryURL="docker.io"
fi
target_image_name=${registryURL}/${target_image_name}
    
# Tag the image for HPVS deployment
write_info "Tag the image '$FHEkit_image_name' with '${target_image_name}:${tag}'"
docker tag $FHEkit_image_name ${target_image_name}:${tag}
#Delete the one that we fetched here
#docker rmi -f $(docker images $FHEkit_image_name -a -q)
if [[ $? != 0 ]]; then
    fatal_error "Failed to tag the image"
fi

################################################################################
########             Register, sign, and push the FHE image             ########
################################################################################

docker_login $registryURL

# If the delegationPriFile configuration variable isn't set, we will assume that
# the delegation key has already been loaded into the local Docker trust store
if [[ -n $delegationPriFile ]] && [[ "$delegationPriFile" != "" ]]; then
    load_trust_key ${delegationPassphrase} ${delegationPriFile} ${delegationkeyName}
else
    write_info "The configuration parameter 'delegationPriFile' was not specified"
    write_info "We will assume the delegation private key is already in the local Docker trust store"
fi

# Delegations in Docker Content Trust (DCT) allow you to control who can and
# cannot sign an image tag. A delegation will have a pair of private and public
# delegation keys. A delegation could contain multiple pairs of keys and
# contributors in order to allow multiple users to be part of a delegation, and
# to support key rotation.
#
# By using delegation keys, we can allow for potentially multiple people to be
# able to sign an image.  If we choose not to use delegation keys, then we will
# instead sign the image with the root certificate.
delegationKeyInfoString="The 'delegationkey' configuration parameter is"
if [[ -n ${delegationkey} && "${delegationkey}" == true ]]; then

    # Tell the notary server that we will be using it to manage trust delegation for
    # the given repository, and upload the first key to a delegation.  This will add
    # the contributor's public key to the "targets/releases" delegation, and create
    # a second "targets/${target_image_name}" delegation.
    init_repo_for_notary_server ${rootPassphrase} \
                                ${repoPassphrase} \
                                ${delegationPubFile} \
                                ${delegationkeyName} \
                                ${target_image_name} \
                                ${DCTServer}

    delegationKeyInfoString="${delegationKeyInfoString} TRUE; delegation keys will be used"
else
    delegationPassphrase=${repoPassphrase}
    
    if [[ -z ${delegationkey} ]]; then
        delegationKeyInfoString="${delegationKeyInfoString} unset"
    elif [[ "${delegationkey}" == false ]]; then
        delegationKeyInfoString="${delegationKeyInfoString} FALSE"
    fi
    
    delegationKeyInfoString="${delegationKeyInfoString}; delegation keys will not be used"
fi
write_info "${delegationKeyInfoString}"

# Sign the FHE Toolkit image with our delegation key, and push it to the container registry
sign_and_push_oci ${rootPassphrase} \
                  ${delegationPassphrase} \
                  ${target_image_name} \
                  ${tag} \
                  ${DCTServer}

################################################################################
########           Generate the registration definition file            ########
################################################################################

# Load the default vendor public key
gpg_load_public_key ${gpgVendorKeyName} ${gpgVendorPubFile}

# Load the default vendor private key
gpg_load_private_key ${gpgVendorKeyName} ${gpgVendorPriFile} ${gpgVendorKeyPassphrase}

# Load the public key needed to encrypt the HPVS registration definition file
rtoaDestName=$(gpg_load_public_key_for_regfile_encryption)
write_success "Imported the public key '${rtoaDestName}'"

# If the registrationFile configuration variable wasn't specified, use the
# default registration file name
if [[ -z $registrationFile ]]; then
    write_info "The registrationFile configuration variable was not set, using the default '${DEFAULT_REGISTRATION_FILE}'"
    registrationFile=${DEFAULT_REGISTRATION_FILE}
fi

# Call Python BuildRegistrationDefinition to generate the registration json file
build_registration_definition_file ${DIRNAME}/${registrationFile} \
                                   ${gpgVendorPubFile} \
                                   ${dockerUser} \
                                   ${dockerPW} \
                                   ${namespace} \
                                   ${repo} \
                                   ${registryURL}

# Encrypt and sign the registration definition file
encrypt_and_sign ${registrationFile} ${rtoaDestName} ${gpgVendorKeyName} ${gpgVendorKeyPassphrase}

################################################################################
########            Provision a Hyper Protect Virtual Server            ########
################################################################################

# Get the IAM token for our IBM Cloud account
write_info "Determining IAM token for IBM Cloud account"
if [[ -z $APIKey ]]; then
    write_info "The 'APIKey' configuration value was not set; defaulting to 'dockerPW' value"
    APIKey=$dockerPW
fi
token=$(get_iam_token $APIKey)

# If the cloud deployment location was not set, use the default
if [[ -z $location ]]; then
    write_info "The 'location' configuration value was not set, defaulting to '$DEFAULT_LOCATION'"
    location=$DEFAULT_LOCATION
fi

# If no name was specified for our new HPVS instance, use the default
if [[ -z $hpvsName ]]; then
    write_info "The 'hpvsName' configuration value was not set, defaulting to '$DEFAULT_HPVS_NAME'"
    hpvsName=$DEFAULT_HPVS_NAME
fi

# If no IBM Cloud resource group was specified, determine and use the default
if [[ -z $resource_group ]] || [[ "$resource_group" == "" ]]; then
    write_info "The 'resource_group' configuration value was not set, will use the default group for this account"
    
    # Get the IBM cloud account ID associated with our IAM token
    account_id=$(get_ibm_cloud_id $token $APIKey)
    write_log "Determined that account ID is '${account_id}'"
    
    # Get the ID of the default resource group for this account
    resource_group=$(get_default_resource_group_id $account_id $token)
    if [[ -z $resource_group ]]; then
        fatal_error "Unable to determine resource groups for account '$account_id'"
    else
        write_info "Default resource group for account '$account_id' is '$resource_group'"
    fi 
fi

# If no HPVS resource plan was specified, use the default
if [[ -z $resource_plan_id ]] || [[ "$resource_plan_id" == "" ]]; then
    write_info "The 'resource_plan_id' configuration value was not set, defaulting to '$DEFAULT_RESOURCE_PLAN_ID'"
    resource_plan_id=$DEFAULT_RESOURCE_PLAN_ID
fi

# Provision our new HPVS instance
echo "Provisiton instance"
#provision_hpvs_instance $registrationFile $hpvsName $location $resource_group $resource_plan_id $tag
#instanceID=12345
instanceID=$(provision_hpvs_instance $registrationFile $hpvsName $location $resource_group $resource_plan_id $tag)
#while instanceID == -1 keep trying
#sleep for a few seconds and go again
# if it continuously fails then fail for good
#Failed to privision to ibm cloud trying again in 1 second
#tried multiple times but no worky
write_info "Provisioning request for service instance '${instanceID}' was accepted"
write_info "To check the provisioning status run:"
write_info "    ibmcloud hpvs instance ${instanceID}"

docker_logout
exit 0
