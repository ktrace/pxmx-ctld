# pxmx-ctld
ProxMox plugin for FreeBSD/ctld iSCSI target as backend

Totally reforged for more correct work.
- Correct add/remove LUNs
- Change config format for correct reloading
- Multiple targets support

TODO:
- tests
- make correct initial (with empty config or without config at all)
- autocreate targets and portal groups
- take blocksize from proxmox (hardcoded 4K)
- take cache options from proxmox (default)
- switch from Data::UUID to default module in proxmox
- validation for parameters and result codes
- code clean
- tests

Just work but still not for production.
