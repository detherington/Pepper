# dmgbuild settings for the Pepper installer (scripts/release.sh), the same
# as Muesli's (~/Muesli/Config/dmg/settings.py): Off White window with the
# iridescent band, the app on the left, an Applications alias on the right,
# "Drag Pepper to Applications" beneath. The background comes from
# scripts/render-dmg-background.swift.
import os.path

app = defines.get("app", "build/Build/Products/Release/Pepper.app")

format = "ULMO"   # LZMA: about the size of the hdiutil image Pepper made before (UDZO came out a third larger)
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (170, 200), "Applications": (490, 200)}
background = "scripts/dmg/background.png"   # 1x: Finder draws Retina TIFFs and 144-dpi PNGs at double size
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
icon_size = 128
text_size = 13
arrange_by = None
