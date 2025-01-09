## Deploy AAPH with lua plguin for nginx ingress controller

----------
### Prerequisite 
1. Registration token from Akamai ACC 
2. Docker container registry password 

### Deployment steps
Clone or copy this repo 
```shell
git clone https://github.com/akamai/aaph.git
```

Update aaph-values.yaml with correct image and resource allocation

Run script to install or upgrade aaph in k8s
```shell
./deploy-aaph-lua.sh -f aaph-values.yaml -l aaph.lua -t <token> -p  <docker repo password> -r ingress-nginx --install-origin -v
use -v for verbose output
use -k to merge new kubeconfig
```

```shell
# uses
./deploy-aaph-lua.sh -h

This script automates the installation or upgrade of the NGINX Ingress controller with AAPH Lua plugin support.

Usage: ./deploy-aaph-lua.sh [OPTIONS]

Options:
  -f, --values-file <file>                    Path to the values.yaml file for configuring the Ingress controller
  -l, --lua-file <file>                       Path to the Lua plugin file for the AAPH WAF plugin
  -t, --reg-token <token>                     AAH Registration Token (required for the installation)
  -r, --release-name <release-name>           Chart release name (default: nginx-ingress)
  -k, --kubeconfig <file>                     Path to a new kubeconfig file (merges with existing kubeconfig and switches to the latest context)
  -p, --docker-password <password>            Docker registry password for pulling images from owaap.azurecr.io
  -v, --verbose                               Enable verbose output for detailed logging
  -h, --help                                  Show this help message and exit
  --install-origin                            Installation of the test origin(Juice Shop and NGINX Echo Server)

Examples:
# 1. Merge a new kubeconfig with the existing kubeconfig and switch to the latest context:
  ./deploy-aaph-lua.sh -k /path/to/new/kubeconfig.yaml

# 2. Install/upgrade the NGINX Ingress controller with the AAPH Lua plugin and install two origins:
#    1. Juice Shop
#    2. NGINX Echo Server
  ./deploy-aaph-lua.sh -f aaph-values.yaml -l aaph.lua -r ingress-nginx -t 00J0HVZK0G00H0H0W00XRA0BPS -p asdersadfsaeradgaer --install-origin

# 3. Install/upgrade the NGINX Ingress controller with the AAPH Lua plugin but skip origin installation:
  ./deploy-aaph-lua.sh -f aaph-values.yaml -l aaph.lua -r ingress-nginx -t 00J0HVZK0G00H0H0W00XRA0BPS -p asdersadfsaeradgaer 

# 5. Install/upgrade the NGINX Ingress controller with latest app version 
  ./deploy-aaph-lua.sh -f aaph-values.yaml -l aaph.lua -r ingress-nginx -t 00J0HVZK0G00H0H0W00XRA0BPS -p asdersadfsaeradgaer

Note:
- Using the -k option will merge the new kubeconfig file with the existing one and switch to the latest context.
- This script is idempotent, meaning you can run it multiple times without triggering unnecessary changes.
- Updating the token alone will not restart the pods unless other significant changes are made.
```
## Clean up 

Run clean up script to clean up all resources installed by deployment script 
clean-up script will 
- Remove all helm releases in namespace ingress-nginx and origin 
- Remove lua plugin file configmap 
- Remove docker image pull and registration token secret from namespace
```shell
./cleanup.sh
```
