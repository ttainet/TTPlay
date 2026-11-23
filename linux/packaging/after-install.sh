#!/bin/bash
chmod +x /usr/bin/ttplay
chmod +x /opt/ttplay/ttplay
chmod +x /opt/ttplay/lib/crashpad_handler

if command -v gtk-update-icon-cache &> /dev/null; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true
fi

if command -v update-desktop-database &> /dev/null; then
    update-desktop-database /usr/share/applications || true
fi
