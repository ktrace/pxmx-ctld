#!/bin/sh

cp CTLD.pm /usr/share/perl5/PVE/Storage/Luncmd
cp ZFSPlugin.pm.patch /usr/share/perl5/PVE/Storage/
cp pvemanagerlib.js.patch /usr/share/pve-manager/js

cd /usr/share/perl5/PVE/Storage/
patch -p0 < ZFSPlugin.pm.patch

cd /usr/share/pve-manager/js
patch -p0 < pvemanagerlib.js.patch

#pveproxy reload
#refresh config?
