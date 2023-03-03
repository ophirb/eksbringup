Must-have Installations

* docker desktop
https://docs.docker.com/desktop/install/mac-install/

* eksctl
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"
brew tap weaveworks/tap
brew install weaveworks/tap/eksctl

* kubectl
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.24.10/2023-01-30/bin/darwin/amd64/kubectl
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
sudo chown root: /usr/local/bin/kubectl
source <(kubectl completion zsh)  # set up autocomplete in zsh into the current shell
echo '[[ $commands[kubectl] ]] && source <(kubectl completion zsh)' >> ~/.zshrc # add autocomplete permanently to your zsh shell

* python3, pip
just make sure python3 and pip3 are installed

* awscli
pip install awscli

* jq
brew install autoconf automake libtool
brew install jq

* helm
brew install helm



Configurations

* awscli






