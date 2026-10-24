"""Make per-instance co-op ini files from the game's Postal2.ini and User.ini.

Usage: python -I mkcoopini.py [--res WxH] [--stock-menu] [--player-name N] <game System dir> <name> [<name> ...]
Writes P2Coop<name>.ini and P2Coop<name>User.ini for each name (e.g. Host Client1).
  --res WxH        windowed size (default 1024x768)
  --stock-menu     keep Shell.ShellRootWindow as the menu (default: P2Coop.CoopRootWindow)
  --player-name N  the same player name in every User.ini (like real players with the stock one)
"""
import argparse
import os
import re

# Packages a client needs to resolve single-player classes (stock MP list has only MP packages).
EXTRA_SERVER_PACKAGES = ["GameTypes", "BasePeople", "People", "AIPack", "AWPawns", "AWInventory",
                         "AWPStuff", "EDStuff", "FX2", "Postal2Holidays", "P2Coop"]

STOCK_MENU, COOP_MENU = "Shell.ShellRootWindow", "P2Coop.CoopRootWindow"


def overrides(res, menu):
    """Section -> {key: value} forced into the game ini."""
    w, h = res.lower().split("x")
    return {
        "WinDrv.WindowsClient": {"StartupFullscreen": "False", "WindowedViewportX": w,
                                 "WindowedViewportY": h, "CaptureMouse": "False"},
        # A host that loads a save serves the save itself as the level package, which clients
        # download (16 MB); at the stock 20000 bytes/s that took about 13 minutes.
        "IpDrv.TcpNetDriver": {"MaxConnPerIPPerMinute": "64", "MaxClientRate": "1000000",
                               "MaxInternetClientRate": "1000000"},
        "Engine.Player": {"ConfiguredInternetSpeed": "1000000", "ConfiguredLanSpeed": "1000000"},
        # Test copies are silent; the audio device stays on so sound lengths behave as in play.
        "ALAudio.ALAudioSubsystem": {"MusicVolume": "0.0", "AmbientVolume": "0.0", "SoundVolume": "0.0"},
        # CoopRootWindow fixes the join crash below the menu's MinRes.
        "Engine.Engine": {"BaseMenu": menu},
        # The map and newspaper screens switch to MinRes (1024x768) while they show; test copies
        # keep their window size so windows side by side do not overlap.
        "Postal2Game.P2Screen": {"MinRes": res.lower()},
        # Co-op saves have their own folder, as install.ps1 sets it.
        "Core.System": {"SavePath": "..\\SaveCoop"},
    }


def read(path):
    with open(path, encoding="latin-1") as f:
        return f.read().split("\n")


def write(path, lines):
    with open(path, "w", encoding="latin-1", newline="\r\n") as f:
        f.write("\n".join(lines))


def section_body(src, name):
    out, inside = [], False
    for line in src:
        m = re.match(r"\[(.+)\]\s*$", line.strip())
        if m:
            inside = m.group(1) == name
            continue
        if inside and line.strip():
            out.append(line)
    return out


def make_game_ini(src, forced, menu):
    out, section, seen = [], None, set()

    def flush(sec):
        # Keys of an overridden section that were not present in the source.
        for k, v in forced.get(sec, {}).items():
            if (sec, k) not in seen:
                out.append("%s=%s" % (k, v))
        if sec == "Engine.GameEngine":
            for p in EXTRA_SERVER_PACKAGES:
                out.append("ServerPackages=%s" % p)

    for line in src:
        m = re.match(r"\[(.+)\]\s*$", line.strip())
        if m:
            if section is not None:
                flush(section)
            section = m.group(1)
            out.append(line)
            continue
        key = line.split("=", 1)[0].strip()
        if section == "Engine.GameEngine":
            # No query port, master server uplink, LAN beacon or web server for co-op.
            if key == "ServerActors":
                continue
            if key == "ServerPackages" and line.split("=", 1)[1].strip() in EXTRA_SERVER_PACKAGES:
                continue
        if section is not None and key in forced.get(section, {}):
            seen.add((section, key))
            line = "%s=%s" % (key, forced[section][key])
        out.append(line)
    if section is not None:
        flush(section)
    # Overridden sections the source does not have at all.
    present = set(m.group(1) for m in (re.match(r"\[(.+)\]\s*$", l.strip()) for l in src) if m)
    for sec, keys in forced.items():
        if sec not in present:
            out += ["", "[%s]" % sec] + ["%s=%s" % (k, v) for k, v in keys.items()]
    if menu != STOCK_MENU:
        # A subclass reads its config vars from its own section.
        out += ["", "[%s]" % menu] + section_body(src, STOCK_MENU)
    return out


def make_user_ini(src, name):
    out, section = [], None
    for line in src:
        m = re.match(r"\[(.+)\]\s*$", line.strip())
        if m:
            section = m.group(1)
        elif section == "DefaultPlayer" and line.startswith("Name="):
            line = "Name=%s" % name
        out.append(line)
    return out


def main():
    ap = argparse.ArgumentParser(usage=__doc__)
    ap.add_argument("--res", default="1024x768")
    ap.add_argument("--stock-menu", action="store_true")
    ap.add_argument("--player-name", default="", help="same player name for every copy (default: its own name)")
    ap.add_argument("system")
    ap.add_argument("names", nargs="+")
    a = ap.parse_args()
    menu = STOCK_MENU if a.stock_menu else COOP_MENU
    game = make_game_ini(read(os.path.join(a.system, "Postal2.ini")), overrides(a.res, menu), menu)
    user = read(os.path.join(a.system, "User.ini"))
    os.makedirs(os.path.join(a.system, "..", "SaveCoop"), exist_ok=True)
    for n in a.names:
        write(os.path.join(a.system, "P2Coop%s.ini" % n), game)
        write(os.path.join(a.system, "P2Coop%sUser.ini" % n), make_user_ini(user, a.player_name or n))
        print("wrote P2Coop%s.ini, P2Coop%sUser.ini (%s, %s)" % (n, n, a.res, menu))


if __name__ == "__main__":
    main()
