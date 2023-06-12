# terraform-gcp-bootstrapper

## what is this?

This shell script automates many boring setup bits for Github, GCP Cloud Build
and Terraform, so you can get to work on your actual idea much faster.

You supply:

* a Github repository
* a Github personal access token (details and opinions below)
* the application ID for Google Cloud Build once you've set it up in your Github account

It will setup in GCP:

* a new project to contain your experiment, associated with your billing account
* a Terraform state bucket
* a Secret in Secret Manager for your Github personal access token
* a Github platform connection in Cloud Build
* a Github repository connection in Cloud Build
* a git branch push trigger in Cloud Build
* various IAM bits to make it all work

You can copy verbatim from here to your repository:

* Cloud Build sample pipeline that runs Terraform and stores state in the state bucket
* a Terraform backend definition, because you need one and why type it every time?
* a "Hello, world" Terraform output definition to give it something to chew on

Perfect for quick experiments and prototypes.

## YOU are responsible for your GCP cost, data and uptime!

Ugly disclaimers time.

_I am not responsible for your Google Cloud Platform bill_. *YOU* need to
understand the cost impact of all resources and other billable usage in your
account, and control it accordingly.

_I am also not responsible for your Google Cloud Platform data_. This
implementation is designed to fail fast if anything doesn't look right, and all
resources are created in a new project (and it attempts to avoid accidentally
creating them in another project, such as if you happened to run...

```
gcloud config set project SOMEOTHERPROJECT
```

... while it is still creating resources in your new project. So it should be
pretty safe, but ... ultimately the responsibility rests with you.

## YOU are responsible for your Github account and access token security!

Audit your tokens regularly and consider how and where they are used. Consider
creating them with expiry dates, knowing of course that if you do your pipeline
will eventually stop working.

## Install dependencies

Some preparation required. You only need to do these once.

### Google Cloud CLI initial setup

Skip this if you can already `gcloud projects create`.

Otherwise, go here: https://cloud.google.com/sdk/docs/install

### Google Cloud CLI alpha components

Once you have `gcloud` working with your Google Cloud account, you'll also need
to install the optional `alpha` components, as some of the Cloud Build
features, and also the ability to link a project to a billing account, are not
yet in the general release version of `gcloud`.

```
gcloud components install alpha
```

Note that these are `alpha` components and should be treated as such.

### Google Cloud Build application in Github Marketplace

Add the [Cloud Build application](https://github.com/marketplace/google-cloud-build)
to your Github account.

Once added, go to your [application settings page](https://github.com/settings/installations)
and copy the Configure button's link for the Google Cloud Build application. It
should look like this

```
https://github.com/settings/installations/38510777
```

You only just the number at the end. It will be a different number to the above
example.

Put it (use your number, not mine!) in a file
`$HOME/shell-secrets/tokens/github/cloudbuild_install_id`, and protect the
directory from snooping other users, if any:

```
mkdir -p "$HOME/shell-secrets/tokens/github/"
chmod 700 "$HOME/shell-secrets/tokens/github/"
echo 38510777 > "$HOME/shell-secrets/tokens/github/cloudbuild_install_id"
```

That's it!


## Setup an experiment!

### Per-project Github setup:

1. create a Github repository for your experiment

2. go back to the [application settings page](https://github.com/settings/installations)
   and hit the Configure button for the Google Cloud Build application. Ensure
   it is allowed access to the repository you just created. If you allowed it
   access to all of your repositories, you won't need to do this, but I assume
   you didn't :-)

3. create a Github [personal access token](https://github.com/settings/tokens)
   with `repo` and `user:read` privileges. Use the repository name for the
   token comment so you can identify its purpose later. Put the token in
   `$HOME/shell-secrets/tokens/github/NAME_OF_REPOSITORY_HERE`, eg. if your
   repository is `https://github.com/example/tf-gcp-rpg`, your filename
   would be `$HOME/shell-secrets/tokens/github/tf-gcp-rpg`. I hope this makes
   sense.

### Actually do things

1. clone this repository somewhere

```
cd "$HOME/repo"
git clone git@github.com:jsleeio/terraform-gcp-bootstrapper.git
```

2. clone your new experiment's repository (adjust names accordingly)

```
cd "$HOME/repo"
git clone git@github.com:example/tf-gcp-experiment
cd tf-gcp-experiment
```

3. run it from within your new repo somewhere, and give it a name to use for
   the new GCP project it will create for your experiment. My preference is to
   use the same name for repository and project.

```
$HOME/repo/terraform-gcp-bootstrapper/terraform-gcp-bootstrapper.sh -p YOURPROJECT
```


4. if all went well, add the example cloudbuild pipeline definition and
   Terraform test files, commit and push:

```
cp $HOME/repo/terraform-gcp-bootstrapper/cloudbuild-sample.yaml cloudbuild.yaml
cp $HOME/repo/terraform-gcp-bootstrapper/terraform.tf terraform.tf
cp $HOME/repo/terraform-gcp-bootstrapper/output-greeting.tf output-greeting.tf
git add cloudbuild.yaml terraform.tf output-greeting.tf
git commit -m 'initial setup'
git push
```

5. go into the Cloud Build console in your new project. Was a build triggered?
   Did it work? Did you get a greeting in the log?

## regarding Github personal access tokens

The instructions here suggest a token per experiment. This is annoying, to be
sure, but it suits the context (experiments you create and destroy as required)
quite well:

* you'll always know what each token is for

* each token is only stored within Secret Manager within project in which it is
  used; there are no annoying cross-project relationships to audit/setup

* destroying one experiment and its corresponding token won't break deployments
  for other still-live experiments

* Github's [personal access token page](https://github.com/settings/tokens)
  will give you a nice summary of how recently you've worked on each of your
  experiments, and maybe remind you to destroy some and save some money

TLDR you _*can*_ use the same token for everything and it'll work just fine,
but I don't recommend it.

## other random notes

I wrote this primarily for me, and in that context it is a huge improvement and
helps me get up and running much, much faster --- no need to dig around in
documentation. Additionally, I've now documented the exact steps for myself.

Some parts of it, like the Github personal access token, are still annoying,
but as far as I'm aware Github don't allow automation of that part. Maybe
prompting the user in the terminal would be a better choice there, though, vs.
storing it in a file.

No attempt at multiple development branches is made. This is for experiments
and proofs-of-concept --- you're probably committing directly to `main`. In a
production context the "run a `terraform plan` on a feature branch before
merging a PR" vibe isn't safe anyway, as there are no measures preventing you
using your production deployment credentials from within the context of
Terraform's `external` provider.

## license

MIT License

Copyright (c) 2023 John Slee

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
