"""Finder layout for the SpeedBar disk image (loaded by dmgbuild)."""

files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
window_rect = ((180, 160), (720, 400))
icon_locations = {"SpeedBar.app": (195, 223), "Applications": (525, 223)}
icon_size = 102
text_size = 14
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
