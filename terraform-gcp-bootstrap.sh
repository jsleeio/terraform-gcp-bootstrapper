#!/bin/sh

# MIT License
# 
# Copyright (c) 2023 John Slee
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

_die() {
  echo "FATAL: $*" >&2
  exit 1
}

_check_software_prerequisites() {
  for app in jq git gcloud gsutil ; do
    which $app > /dev/null || _die "missing prerequisite: $app"
  done
}

_must() {
  if [ "$dryrun" = "yes" ] ; then
    echo "not-executing: $*"
  else
    echo "executing: $*"
    "$@" || _die "$@"
  fi
}

_find_repository_name() {
  _rn_remote="$(git config --get remote.origin.url || _die 'unable to get Git remote')"
  basename -s .git "$_rn_remote"
  # trying to avoid using bashisms like 'local' here in case we
  # want to run this in an Alpine container
  unset _rn_remote
}

_find_billing_account() {
  gcloud alpha billing accounts list \
    --format=json \
    | jq -r '.[] | select(.open) | .name | split("/") | .[1]'
}

repository_name="$(_find_repository_name)"
labels="kind=experiment,source=$(_find_repository_name)"
project=""
region="us-west2"
dryrun=no
github_token_file="$HOME/shell-secrets/tokens/github/$repository_name"
github_cloudbuild_install_id_file="$HOME/shell-secrets/tokens/github/cloudbuild_install_id"

while getopts "l:np:r:" opt ; do
  case "$opt" in
    l) labels="$OPTARG"  ;;
    n) dryrun=yes        ;;
    p) project="$OPTARG" ;;
    r) region="$OPTARG"  ;;
    *) _die "usage: bootstrap.sh [-p PROJECT] [-l K1=V1,K2=V2,...]"
  esac
done

## preflight checks --- don't want to get partway through creating stuff and then fail
##                      leaving the user with cleanup, if we can avoid it
_check_software_prerequisites
[ -z "$project" ]                           && _die "project must be provided"
[ -z "$repository_name" ]                   && _die "can't find Git repository name. Does it have a remote?"
[ -f "$github_token_file" ]                 || _die "can't find Github token file: $github_token_file"
[ -f "$github_cloudbuild_install_id_file" ] || _die "can't find Github Cloud Build install ID file"

# ready for positional args later
shift $((OPTIND-1))

billing_account=$(_find_billing_account)

[ -z "$billing_account" ] && _die "billing account not found"

github_token=$(cat "$github_token_file")
github_cloudbuild_install_id=$(cat "$github_cloudbuild_install_id_file" \
  || _die "can't read Cloud Build app install ID file")

_must gcloud projects create \
  --labels="$labels" \
  "$project"

# we'll use this a couple of times later
project_number=$(gcloud projects describe \
  --format='value(projectNumber)' \
  "$project" \
  || _die "can't get project numerical ID")

_must gcloud alpha billing projects link \
  --billing-account="$billing_account" \
  "$project"

# makes the gsutil bits easier
_must gcloud config set project "$project"

# enable some APIs. we don't strictly need iam or cloudresourcemanager here but
# iam is almost certainly going to be needed in the experiment, and
# cloudresourcemanager is required for the `google_project` datasource which is
# also likely to be required. So do it upfront
_must gcloud services enable \
  cloudbuild.googleapis.com \
  cloudresourcemanager.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  secretmanager.googleapis.com \
  storage.googleapis.com \
  --project="$project"

_must gcloud storage buckets create \
  --public-access-prevention \
  --location="$region" \
  --project="$project" \
  "gs://terraform-state-$project"

_must gsutil -u "$project" versioning set on "gs://terraform-state-$project"

_must gcloud projects add-iam-policy-binding \
  --member "serviceAccount:${project_number}@cloudbuild.gserviceaccount.com" \
  --role roles/editor \
  "$project"

# github setup notes: https://cloud.google.com/build/docs/automating-builds/github/connect-repo-github#gcloud
printf "%s" "$github_token" \
  | _must gcloud secrets create \
      --data-file=- \
      github-cloudbuild-token

_must gcloud secrets add-iam-policy-binding \
  --member="serviceAccount:service-${project_number}@gcp-sa-cloudbuild.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" \
  github-cloudbuild-token

_must gcloud alpha builds connections create github \
  --authorizer-token-secret-version="projects/${project}/secrets/github-cloudbuild-token/versions/1" \
  --app-installation-id="$github_cloudbuild_install_id" \
  --region="$region" \
  github-cloudbuild

_must gcloud alpha builds repositories create \
  "$repository_name" \
  --remote-uri="https://github.com/jsleeio/${repository_name}.git" \
  --connection=github-cloudbuild \
  --region="$region"

# more notes: https://cloud.google.com/build/docs/automating-builds/github/build-repos-from-github?generation=2nd-gen
#
# also
#
# fucken hell google
_must gcloud alpha builds triggers create github \
  --name="${repository_name}-deploy" \
  --repository="projects/${project}/locations/${region}/connections/github-cloudbuild/repositories/${repository_name}" \
  --branch-pattern='^main$' \
  --build-config=cloudbuild.yaml \
  --region="$region"

_must gcloud alpha builds triggers create manual \
  --name="${repository_name}-deploy-manual" \
  --repository="projects/${project}/locations/${region}/connections/github-cloudbuild/repositories/${repository_name}" \
  --build-config=cloudbuild.yaml \
  --region="${region}" \
  --branch=main

_must gcloud alpha builds triggers create manual \
  --name="${repository_name}-destroy" \
  --repository="projects/${project}/locations/${region}/connections/github-cloudbuild/repositories/${repository_name}" \
  --build-config=cloudbuild-destroy.yaml \
  --region="${region}" \
  --branch=main

echo "creating: trigger-deploy.sh"
printf '#!/bin/sh\n\ngcloud builds triggers run %s --region=%s --project=%s\n' \
  "${repository_name}-deploy-manual" "${region}" "${project}" > trigger-deploy.sh

echo "creating: trigger-destroy.sh"
printf '#!/bin/sh\n\ngcloud builds triggers run %s --region=%s --project=%s\n' \
  "${repository_name}-destroy" "${region}" "${project}" > trigger-destroy.sh
chmod 755 trigger-deploy.sh trigger-destroy.sh

echo "creating: terraform.tf"
(
  echo "# most configuration here is passed into 'terraform init' instead" ; \
  echo '' ; \
  echo 'terraform {' ; \
  echo '  backend "gcs" {}' ; \
  echo '}'
) > terraform.tf

echo "creating: outputs.tf"
(
  echo 'output "greeting" {' ; \
  echo '  value = "Hello, world!"' ; \
  echo '}'
) > outputs.tf

founddeployyaml=no
if sourcedir="$(dirname "$0")" ; then
  if cp "$sourcedir/cloudbuild-sample.yaml" cloudbuild.yaml ; then
    founddeployyaml=yes
  fi
  if cp "$sourcedir/cloudbuild-destroy-sample.yaml" cloudbuild-destroy.yaml ; then
    founddestroyyaml=yes
  fi
fi
if [ "$founddeployyaml" = "no" ] ; then
  echo "WARNING: you will need to supply cloudbuild.yaml as I can't find it"
fi
if [ "$founddestroyyaml" = "no" ] ; then
  echo "WARNING: you will need to supply cloudbuild-destroy.yaml as I can't find it"
fi
