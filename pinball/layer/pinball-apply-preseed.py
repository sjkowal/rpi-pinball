#!/usr/bin/env python3
import crypt
import os
import pathlib
import subprocess
import sys
import tomllib

PRESEED = "/boot/firmware/rpi-preseed.toml"


def hash_pw(pw):
    return crypt.crypt(pw, crypt.mksalt(crypt.METHOD_SHA512))


def apply_system(data):
    hostname = data.get("system", {}).get("hostname")
    if not hostname:
        return
    old = pathlib.Path("/etc/hostname").read_text().strip()
    pathlib.Path("/etc/hostname").write_text(hostname + "\n")
    subprocess.run(
        ["sed", "-i", f"s/127\\.0\\.1\\.1.*{old}/127.0.1.1\\t{hostname}/g", "/etc/hosts"],
        check=False,
    )


def apply_user(data):
    user = data.get("user", {})
    name = user.get("name")
    password = user.get("password")
    if not (name and password):
        return
    if not user.get("password_encrypted", False):
        password = hash_pw(password)
    subprocess.run(["/usr/lib/userconf-pi/userconf", name, password], check=True)


def current_user_home():
    line = subprocess.run(
        ["getent", "passwd", "1000"], capture_output=True, text=True, check=True
    ).stdout
    fields = line.strip().split(":")
    return fields[0], fields[5]


def apply_ssh(data):
    ssh = data.get("ssh", {})
    if not ssh.get("enabled", True):
        return
    user, home = current_user_home()
    keys = ssh.get("authorized_keys", [])
    if keys:
        ssh_dir = pathlib.Path(home, ".ssh")
        ssh_dir.mkdir(mode=0o700, exist_ok=True)
        auth = ssh_dir / "authorized_keys"
        auth.write_text("\n".join(keys) + "\n")
        auth.chmod(0o600)
        subprocess.run(["chown", "-R", f"{user}:{user}", str(ssh_dir)], check=False)
    import_id = ssh.get("ssh_import_id")
    if import_id:
        subprocess.run(
            ["runuser", "-u", user, "--", "ssh-import-id", import_id], check=False
        )
    if ssh.get("password_authentication") is False:
        with open("/etc/ssh/sshd_config", "a") as f:
            f.write("PasswordAuthentication no\n")
    subprocess.run(["systemctl", "enable", "ssh"], check=False)


def apply_wlan(data):
    wlan = data.get("wlan", {})
    ssid = wlan.get("ssid")
    if not ssid:
        return
    psk = wlan.get("password", "")
    # NetworkManager's psk= field, like wpa_supplicant's own, accepts either
    # a plaintext passphrase or a raw 64-hex-char pre-derived PSK directly --
    # pass whatever Imager gave us straight through, no re-encoding needed.
    conn = (
        "[connection]\n"
        f"id={ssid}\n"
        "type=wifi\n"
        "\n"
        "[wifi]\n"
        f"ssid={ssid}\n"
        f"hidden={'true' if wlan.get('hidden') else 'false'}\n"
        "\n"
        "[wifi-security]\n"
        "key-mgmt=wpa-psk\n"
        f"psk={psk}\n"
        "\n"
        "[ipv4]\n"
        "method=auto\n"
        "\n"
        "[ipv6]\n"
        "method=auto\n"
    )
    path = pathlib.Path(f"/etc/NetworkManager/system-connections/{ssid}.nmconnection")
    path.write_text(conn)
    path.chmod(0o600)
    country = wlan.get("country")
    if country:
        pathlib.Path("/etc/default/crda").write_text(f'REGDOMAIN={country}\n')


def apply_locale(data):
    locale = data.get("locale", {})
    tz = locale.get("timezone")
    if tz:
        subprocess.run(["rm", "-f", "/etc/localtime"], check=False)
        pathlib.Path("/etc/timezone").write_text(tz + "\n")
        subprocess.run(
            ["dpkg-reconfigure", "-f", "noninteractive", "tzdata"], check=False
        )
    keymap = locale.get("keymap")
    if keymap:
        pathlib.Path("/etc/default/keyboard").write_text(
            f'XKBMODEL="pc105"\nXKBLAYOUT="{keymap}"\nXKBVARIANT=""\nXKBOPTIONS=""\n'
        )
        subprocess.run(
            ["dpkg-reconfigure", "-f", "noninteractive", "keyboard-configuration"],
            check=False,
        )


def main():
    if not os.path.exists(PRESEED):
        return
    with open(PRESEED, "rb") as f:
        data = tomllib.load(f)

    apply_system(data)
    apply_user(data)
    apply_ssh(data)
    apply_wlan(data)
    apply_locale(data)

    os.remove(PRESEED)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"pinball-apply-preseed: {e}", file=sys.stderr)
        sys.exit(1)
