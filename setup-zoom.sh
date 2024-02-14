#!/bin/sh

# sudo wget -O /usr/share/keyrings/mwt.asc "https://mirror.mwt.me/my/gpgkey"
# echo "deb [arch=amd64 signed-by=/usr/share/keyrings/mwt.asc by-hash=force] https://mirror.mwt.me/my/deb any zoom" | sudo tee /etc/apt/sources.list.d/mwt.list

sudo apt update
sudo apt install -y zoom
