#!/bin/sh
if [ -x /usr/local/emhttp/plugins/zfs.autosnapshot/scripts/post-install.sh ]; then
  /usr/local/emhttp/plugins/zfs.autosnapshot/scripts/post-install.sh || true
fi
