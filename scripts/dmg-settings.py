"""Finder layout for the Luma installer, consumed by dmgbuild."""
from pathlib import Path

root = Path(defines["root"])
application = str(root / "build/Luma.app")
format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = str(root / "Resources/AppIcon.icns")
background = str(root / "build/dmg-background.png")
icon_locations = {"Luma.app": (170, 185), "Applications": (470, 185)}
window_rect = ((160, 140), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
icon_size = 100
text_size = 14
grid_spacing = 100
