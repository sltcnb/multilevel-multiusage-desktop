# nix/modules/appliance/desktop.nix
# -----------------------------------------------------------------------------
# The kiosk desktop + environment switching — declarative equivalent of
#   host/configure.sh  (autologin kiosk -> startx -> i3, no display manager)
#   host/switching.sh  (i3 per-env workspaces, virt-viewer, keyd, trust bar)
#
# Display chain: getty --autologin kiosk -> login shell exec startx -> i3.
# i3 launches one virt-viewer per environment, each tiled BELOW a polybar that
# reserves a top strut (the "trust bar"). keyd catches Super+1/2/3 at the evdev
# layer so switching works even while a guest holds a full SPICE keyboard grab.
# -----------------------------------------------------------------------------
{ config, lib, pkgs, applianceLib, ... }:
let
  inherit (lib) mkIf concatMapStringsSep concatStringsSep optionalString head;
  cfg = config.appliance;

  enabled = applianceLib.enabledViews cfg.subnetBase cfg.environments;
  firstIdx = if enabled == [ ] then 1 else (head enabled).workspace;

  WS_PORTAL = 8;
  WS_SHELL = 9;

  # Keyboard layout may be "layout" or "layout:variant" (e.g. fr:oss).
  kbParts = lib.splitString ":" cfg.keyboardLayout;
  kbLayout = head kbParts;
  kbVariant = if builtins.length kbParts > 1 then builtins.elemAt kbParts 1 else "";

  # --- the per-environment SPICE viewer (respawn loop) ---------------------
  # --full-screen only when there is no trust bar; with the bar, the viewer is
  # windowed and i3 tiles it below the strut. Deliberately NOT --kiosk, which
  # would take a full SPICE grab and swallow Super+1/2/3.
  viewerFS = optionalString (!cfg.trustBar.enable) "--full-screen";
  vmViewer = pkgs.writeShellScript "vm-viewer" ''
    set -u
    vm="$1"
    while true; do
      ${pkgs.virt-viewer}/bin/virt-viewer \
        --connect qemu:///system \
        ${viewerFS} \
        --hotkeys=release-cursor=ctrl+alt,toggle-fullscreen=shift+f11 \
        --wait \
        --reconnect \
        --attach "$vm" \
        2>/tmp/viewer-"$vm".log || true
      sleep 2
    done
  '';

  # --- trust bar (polybar): custom active-env pill + reserved top strut -----
  activeEnvScript = pkgs.writeShellScript "active-env" ''
    set -u
    render() {
      case "$1" in
    ${concatMapStringsSep "\n" (v:
        "      ${toString v.workspace}) c='${v.color}'; l='${v.title}';;") enabled}
        ${toString WS_PORTAL}) c='#f59e0b'; l='PORTAL';;
        ${toString WS_SHELL}) c='#6b6b6b'; l='SHELL';;
        *) c='#6b6b6b'; l="WS$1";;
      esac
      printf '%%{B%s}%%{F#ffffff} %s %%{F-}%%{B-}\n' "$c" "$l"
    }
    focused() { ${pkgs.i3}/bin/i3-msg -t get_workspaces | ${pkgs.jq}/bin/jq -r '.[]|select(.focused).num'; }
    render "$(focused)"
    ${pkgs.i3}/bin/i3-msg -t subscribe -m '[ "workspace" ]' | while read -r _; do
      render "$(focused)"
    done
  '';

  polybarConfig = pkgs.writeText "polybar-config.ini" ''
    [colors]
    bg = #0d0d0f
    fg = #e8e8ea

    [bar/trust]
    width = 100%
    height = 18
    background = ''${colors.bg}
    foreground = ''${colors.fg}
    font-0 = DejaVu Sans Mono:size=8;2
    font-1 = DejaVu Sans Mono:size=11;3
    padding-left = 1
    padding-right = 2
    module-margin = 2
    modules-left = env
    modules-right = date
    ; override-redirect=false makes polybar a real dock that RESERVES a top
    ; strut, so the windowed viewers tile below it and it can never be covered.
    override-redirect = false
    wm-restack = i3
    enable-ipc = true

    [module/env]
    type = custom/script
    exec = ${activeEnvScript}
    tail = true

    [module/date]
    type = internal/date
    interval = 5
    date = %Y-%m-%d %H:%M
    label = %date%
  '';

  polybarLaunch = pkgs.writeShellScript "trust-bar-launch" ''
    ${pkgs.procps}/bin/pkill -u "$(id -u)" -x polybar 2>/dev/null || true
    exec ${pkgs.polybar}/bin/polybar -q -c ${polybarConfig} trust
  '';

  # --- i3 config, generated from the enabled environments ------------------
  perEnvBlock = v: ''
    # --- ${v.name} (workspace ${toString v.workspace}) ---
    for_window [class="(?i)virt-viewer" title="(?i)${v.name}"] move to workspace "${toString v.workspace}: ${v.title}", border none
    bindsym $mod+${toString v.workspace} workspace number ${toString v.workspace}
    exec --no-startup-id ${vmViewer} ${v.name}
  '';

  i3Config = pkgs.writeText "i3-config" ''
    set $mod Mod4
    font pango:DejaVu Sans Mono 8
    default_border none
    default_floating_border none
    hide_edge_borders both
    focus_follows_mouse no

    exec --no-startup-id ${pkgs.xorg.xset}/bin/xset s off -dpms

    bindsym $mod+Tab workspace next
    bindsym $mod+Shift+r restart
    bindsym $mod+Shift+q kill
    bindsym $mod+Return workspace number ${toString WS_SHELL}; exec ${pkgs.xterm}/bin/xterm
    for_window [class="(?i)xterm"] floating enable, border normal

    ${concatMapStringsSep "\n" perEnvBlock enabled}

    # Land on the first enabled environment.
    exec --no-startup-id ${pkgs.i3}/bin/i3-msg workspace number ${toString firstIdx}

    ${optionalString cfg.trustBar.enable
      "exec_always --no-startup-id ${polybarLaunch}"}
  '';

  # --- vmswitch: run by keyd (as root) to drive the kiosk user's i3 --------
  # keyd fires below X, so we must locate the kiosk i3's live DISPLAY/XAUTHORITY
  # from /proc (startx stores the cookie in ~/.serverauth.*, not ~/.Xauthority).
  vmswitch = pkgs.writeShellScript "vmswitch" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.procps pkgs.gnused pkgs.coreutils pkgs.i3 pkgs.xterm ]}
    KU="${cfg.kioskUser}"
    pid="$(pgrep -u "$KU" -x i3 | head -1)" || exit 0
    [ -n "$pid" ] || exit 0
    DISPLAY="$(tr '\0' '\n' < /proc/"$pid"/environ | sed -n 's/^DISPLAY=//p')"
    XAUTHORITY="$(tr '\0' '\n' < /proc/"$pid"/environ | sed -n 's/^XAUTHORITY=//p')"
    if [ -z "$XAUTHORITY" ]; then
      for f in /home/"$KU"/.Xauthority /home/"$KU"/.serverauth.*; do [ -f "$f" ] && XAUTHORITY="$f"; done
    fi
    export DISPLAY XAUTHORITY
    case "$1" in
      term)   i3-msg "workspace number ${toString WS_SHELL}; exec ${pkgs.xterm}/bin/xterm" ;;
      portal) i3-msg "workspace number ${toString WS_PORTAL}" ;; # captive-portal helper: TODO (MVP)
      *)      i3-msg workspace number "$1" ;;
    esac
  '';

  keydMain =
    (builtins.listToAttrs (map
      (v: {
        name = "meta+${toString v.workspace}";
        value = "command(${vmswitch} ${toString v.workspace})";
      })
      enabled))
    // {
      "meta+enter" = "command(${vmswitch} term)";
      "meta+p" = "command(${vmswitch} portal)";
    };
in
{
  config = mkIf cfg.enable {
    # --- Autologin (no display manager) --------------------------------------
    services.getty.autologinUser = cfg.kioskUser;

    # Login shell on VT1 (kiosk only) launches X; root on tty2 gets a plain shell.
    environment.loginShellInit = ''
      if [ -z "''${DISPLAY:-}" ] && [ "''${XDG_VTNR:-}" = "1" ] && [ "$(id -un)" = "${cfg.kioskUser}" ]; then
        exec startx
      fi
    '';

    # --- X + i3 (startx session, no DM) --------------------------------------
    services.xserver = {
      enable = true;
      displayManager.startx.enable = true;
      windowManager.i3 = {
        enable = true;
        configFile = i3Config;
      };
      desktopManager.xterm.enable = false;
      xkb = {
        layout = kbLayout;
        variant = kbVariant;
      };
    };
    services.displayManager.defaultSession = lib.mkDefault "none+i3";

    # --- keyd: Super+N below the SPICE grab ----------------------------------
    services.keyd = {
      enable = true;
      keyboards.default = {
        ids = [ "*" ];
        settings.main = keydMain;
      };
    };

    environment.systemPackages = with pkgs; [
      i3
      polybar
      xterm
      xorg.xset
    ];
    fonts.packages = [ pkgs.dejavu_fonts ];
  };
}
