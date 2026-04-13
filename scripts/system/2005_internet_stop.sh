#!/bin/bash

echo "[+] Tearing down 2005 internet simulation..."

# Disable packet filter
sudo pfctl -d

# Flush all pipes
sudo dnctl flush

# Optionally remove anchor (comment this out if you want to reuse)
# sudo sed -i '' '/anchor "2005_internet"/d' /etc/pf.conf
# sudo sed -i '' '/load anchor "2005_internet"/d' /etc/pf.conf
# sudo rm /etc/pf.anchors/2005_internet

echo "[+] Network simulation disabled."