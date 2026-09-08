cat << 'EOF' > generate_datacenter_notes.sh
#!/usr/bin/env bash

# File to temporarily store the accumulated markdown notes
DC_NOTES_FILE="/tmp/datacenter_notes.md"

# 1. Base Datacenter Header (Using HTML decimal codes for emojis)
echo "# &#127981; Datacenter Cluster Hardware Profile Inventory" > $DC_NOTES_FILE
echo "---" >> $DC_NOTES_FILE
echo "" >> $DC_NOTES_FILE
echo "Click on any node below to expand its full hardware command metrics map." >> $DC_NOTES_FILE
echo "" >> $DC_NOTES_FILE

# 2. Loop through every available node in the Proxmox Cluster
for NODE_NAME in $(pvesh get /nodes --output-format json | grep -o '"node":"[^"]*' | cut -d'"' -f4); do

    echo "Processing metrics mapping for: $NODE_NAME..."
    
    # Wrap each node's profile inside an HTML collapsible tag block
    echo "<details>" >> $DC_NOTES_FILE
    echo "<summary><b>&#9881; Expand Node Profile Summary: $NODE_NAME</b></summary>" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE
    echo "### &#129465; Core System Specs" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE
    
    echo "- **Model/Chassis:** \`dmidecode -s system-product-name\`" >> $DC_NOTES_FILE
    echo "     \`\`\`text" >> $DC_NOTES_FILE
    echo "     root@${NODE_NAME}:~# dmidecode -s system-product-name" >> $DC_NOTES_FILE
    echo "     > $(pvesh create /nodes/$NODE_NAME/execute --command "dmidecode -s system-product-name" --output-format json 2>/dev/null | grep -o '"stdout":"[^"]*' | cut -d'"' -f4 | sed 's/\\n//g' || echo 'Unknown Chassis')" >> $DC_NOTES_FILE
    echo "     \`\`\`" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE

    echo "- **Motherboard:** \`dmidecode -s baseboard-product-name\`" >> $DC_NOTES_FILE
    echo "     \`\`\`text" >> $DC_NOTES_FILE
    echo "     root@${NODE_NAME}:~# dmidecode -s baseboard-product-name" >> $DC_NOTES_FILE
    echo "     > $(pvesh create /nodes/$NODE_NAME/execute --command "dmidecode -s baseboard-product-name" --output-format json 2>/dev/null | grep -o '"stdout":"[^"]*' | cut -d'"' -f4 | sed 's/\\n//g' || echo 'Unknown Board')" >> $DC_NOTES_FILE
    echo "     \`\`\`" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE

    echo "- **CPU:** \`lscpu | grep \"Model name\" | sed 's/Model name:[ \t]*//'\`" >> $DC_NOTES_FILE
    echo "     \`\`\`text" >> $DC_NOTES_FILE
    echo "     root@${NODE_NAME}:~# lscpu | grep \"Model name\" | sed 's/Model name:[ \t]*//'" >> $DC_NOTES_FILE
    echo "     > $(pvesh create /nodes/$NODE_NAME/execute --command "lscpu" --output-format json 2>/dev/null | grep -o '"stdout":"[^"]*' | cut -d'"' -f4 | grep "Model name" | sed 's/Model name:[ \t]*//' | sed 's/\\n//g')" >> $DC_NOTES_FILE
    echo "     \`\`\`" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE

    echo "- **RAM Total:** \`free -h | awk '/Mem:/ {print \$2}'\`" >> $DC_NOTES_FILE
    echo "     \`\`\`text" >> $DC_NOTES_FILE
    echo "     root@${NODE_NAME}:~# free -h | awk '/Mem:/ {print \$2}'" >> $DC_NOTES_FILE
    echo "     > $(pvesh create /nodes/$NODE_NAME/execute --command "free -h" --output-format json 2>/dev/null | grep -o '"stdout":"[^"]*' | cut -d'"' -f4 | grep "Mem:" | awk '{print $2}')" >> $DC_NOTES_FILE
    echo "     \`\`\`" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE

    echo "- **RAM Slots Layout:** \`dmidecode --type memory ...\`" >> $DC_NOTES_FILE
    echo "     \`\`\`text" >> $DC_NOTES_FILE
    echo "     root@${NODE_NAME}:~# dmidecode --type memory | grep -E \"Size|Speed|Type|Manufacturer\" | grep -v \"No Module Installed\"" >> $DC_NOTES_FILE
    pvesh create /nodes/$NODE_NAME/execute --command "dmidecode --type memory" --output-format json 2>/dev/null | grep -o '"stdout":"[^"]*' | cut -d'"' -f4 | sed 's/\\n/\n/g' | grep -E "Size|Speed|Type|Manufacturer" | grep -v "No Module Installed" | sed 's/^/     > /' >> $DC_NOTES_FILE
    echo "     \`\`\`" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE

    echo "- **Boot Drive Physical Serial:** \`lsblk -o NAME,SIZE,MODEL,SERIAL | grep -E \"sda|nvme0n1\"\`" >> $DC_NOTES_FILE
    echo "     \`\`\`text" >> $DC_NOTES_FILE
    echo "     root@${NODE_NAME}:~# lsblk -o NAME,SIZE,MODEL,SERIAL | grep -E \"sda|nvme0n1\"" >> $DC_NOTES_FILE
    pvesh create /nodes/$NODE_NAME/execute --command "lsblk -o NAME,SIZE,MODEL,SERIAL" --output-format json 2>/dev/null | grep -o '"stdout":"[^"]*' | cut -d'"' -f4 | sed 's/\\n/\n/g' | grep -E "sda|nvme0n1" | sed 's/^/     > /' >> $DC_NOTES_FILE
    echo "     \`\`\`" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE
    echo "---" >> $DC_NOTES_FILE

    echo "### &#128452; Storage Arrays & Disks" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE
    echo "- **All Connected Disks:** \`lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINTS\`" >> $DC_NOTES_FILE
    echo "     \`\`\`text" >> $DC_NOTES_FILE
    echo "     root@${NODE_NAME}:~# lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINTS" >> $DC_NOTES_FILE
    pvesh create /nodes/$NODE_NAME/execute --command "lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINTS" --output-format json 2>/dev/null | grep -o '"stdout":"[^"]*' | cut -d'"' -f4 | sed 's/\\n/\n/g' | sed 's/^/     > /' >> $DC_NOTES_FILE
    echo "     \`\`\`" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE

    echo "- **ZFS Pool Status:** \`zpool list\`" >> $DC_NOTES_FILE
    echo "     \`\`\`text" >> $DC_NOTES_FILE
    echo "     root@${NODE_NAME}:~# zpool list" >> $DC_NOTES_FILE
    pvesh create /nodes/$NODE_NAME/execute --command "zpool list" --output-format json 2>/dev/null | grep -o '"stdout":"[^"]*' | cut -d'"' -f4 | sed 's/\\n/\n/g' | sed 's/^/     > /' >> $DC_NOTES_FILE
    echo "     \`\`\`" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE

    echo "- **LVM Free Space:** \`vgs\`" >> $DC_NOTES_FILE
    echo "     \`\`\`text" >> $DC_NOTES_FILE
    echo "     root@${NODE_NAME}:~# vgs" >> $DC_NOTES_FILE
    pvesh create /nodes/$NODE_NAME/execute --command "vgs" --output-format json 2>/dev/null | grep -o '"stdout":"[^"]*' | cut -d'"' -f4 | sed 's/\\n/\n/g' | sed 's/^/     > /' >> $DC_NOTES_FILE
    echo "     \`\`\`" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE
    echo "---" >> $DC_NOTES_FILE

    echo "### &#127104; Network & PCI Topology" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE
    echo "- **Active Network Interfaces:** \`ip -br link\`" >> $DC_NOTES_FILE
    echo "     \`\`\`text" >> $DC_NOTES_FILE
    echo "     root@${NODE_NAME}:~# ip -br link" >> $DC_NOTES_FILE
    pvesh create /nodes/$NODE_NAME/execute --command "ip -br link" --output-format json 2>/dev/null | grep -o '"stdout":"[^"]*' | cut -d'"' -f4 | sed 's/\\n/\n/g' | sed 's/^/     > /' >> $DC_NOTES_FILE
    echo "     \`\`\`" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE

    echo "- **Proxmox Network Bridges:** \`cat /etc/pve/interfaces | grep vmbr\`" >> $DC_NOTES_FILE
    echo "     \`\`\`text" >> $DC_NOTES_FILE
    echo "     root@${NODE_NAME}:~# cat /etc/pve/interfaces | grep vmbr" >> $DC_NOTES_FILE
    pvesh create /nodes/$NODE_NAME/execute --command "cat /etc/pve/interfaces" --output-format json 2>/dev/null | grep -o '"stdout":"[^"]*' | cut -d'"' -f4 | sed 's/\\n/\n/g' | grep vmbr | sed 's/^/     > /' >> $DC_NOTES_FILE
    echo "     \`\`\`" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE

    echo "- **GPUs / PCIe Devices:** \`lspci\`" >> $DC_NOTES_FILE
    echo "     \`\`\`text" >> $DC_NOTES_FILE
    echo "     root@${NODE_NAME}:~# lspci | grep -E \"VGA|3D|Controller\"" >> $DC_NOTES_FILE
    pvesh create /nodes/$NODE_NAME/execute --command "lspci" --output-format json 2>/dev/null | grep -o '"stdout":"[^"]*' | cut -d'"' -f4 | sed 's/\\n/\n/g' | grep -E "VGA|3D|Controller" | sed 's/^/     > /' >> $DC_NOTES_FILE
    echo "     \`\`\`" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE

    echo "</details>" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE
    echo "---" >> $DC_NOTES_FILE
    echo "" >> $DC_NOTES_FILE
done

# 3. Direct API write to Datacenter Note description 
echo "Pushing all data to Proxmox Datacenter Notes..."
pvesh set /cluster/options --description "$(cat $DC_NOTES_FILE)"

# Cleanup temp file
rm -f $DC_NOTES_FILE
echo "Done!"
EOF

chmod +x generate_datacenter_notes.sh
./generate_datacenter_notes.sh
