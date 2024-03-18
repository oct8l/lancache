# Lancache Monolithic for ARM32/ARM64/AMD64

A monolithic Lancache Docker image suite capable of caching all CDNs in a single instance

# Note
+ NTFS/FAT32 external drives will not work. `nginx` tries to `chown`, which doesn't play nice with Microsoft filesystems. Please use a nix filesystem such as `ext4`.
+ You may experience slower than expected cache speeds.

# Installation
- To install:
  -  If you don't already have `docker`, follow the instructions [here](https://docs.docker.com/engine/install/) for your OS

-  After Docker is available, run the following:

```bash
sudo git clone https://github.com/oct8l/lancache-multiarch.git
cd lancache-multiarch
nano .env
```

  * In the .env, follow annotations and modify `LANCACHE_IP` and `DNS_BIND_IP` to be the IP of the interface you want to expose this on
  * Then to bring it up, run `docker-compose up -d`

Further documentation can be found at [lancache.net](https://lancache.net/)

## Test it
http://diagnostics.lancache.net/

## Actions
This repo uses Github Actions. Click the Actions tab to view the script output.

The resulting images can be found [here](https://github.com/oct8l?tab=packages&repo_name=lancache-multiarch)
