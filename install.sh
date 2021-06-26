#!/bin/sh

cp CTLD.pm /usr/share/perl5/PVE/Storage/LunCmd
cp ZFSPlugin.pm.patch /usr/share/perl5/PVE/Storage/
cp pvemanagerlib.js.patch /usr/share/pve-manager/js

cd /usr/share/perl5/PVE/Storage/
patch -p0 < ZFSPlugin.pm.patch

cd /usr/share/pve-manager/js
patch -p0 < pvemanagerlib.js.patch

systemctl restart pvedaemon #pvedaemon reload
systemctl restart pveproxy #pveproxy reload
systemctl restart pvestatd

echo "Logout from PVE webgui and clean the browser cache and login again."
echo "Ctld should be available as a iSCSI provider without restart any node or cluster service."

#refresh config?
