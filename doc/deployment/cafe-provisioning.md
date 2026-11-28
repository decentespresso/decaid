# Café and commercial device provisioning

How to harden a Decaid tablet in a place where you don't control every device
nearby: a café, a roastery, an office, or anywhere else guests and staff use
the same building's network. It applies to Decaid 0.9.3 and later, and it
is written for whoever sets the tablets up, at one site or several.

At home you don't need this. Decaid ships in compatibility mode so that Home
Assistant, MCP clients, skins and scripts on your own network work without
tokens, and on a network where you trust every device that is the right
setting.

## Checklist

Print this and tick it off per tablet. The links lead to each step.

**Before service**

- [ ] Decaid is on a release you have tested, and so are its plugins and skin
      ([Set the tablet up](#1-set-the-tablet-up))
- [ ] Every installed plugin is one you chose, and you have read its
      permissions; the rest are removed, or unloaded with auto-load off
- [ ] Plugin settings are filled in (accounts, upload options)
- [ ] **Automatic update checks** is off
- [ ] Old API tokens are revoked
- [ ] **Settings → Security → Require authorization for extension management**
      is on, and the page reads **Protected mode (ON)**
      ([Turn on protected mode](#2-turn-on-protected-mode))
- [ ] The tablet is on its own network, and nothing else can open a connection
      to it ([Restrict the network](#3-restrict-the-network))
- [ ] Each remote client has its own named token, stored in a password manager
      ([Manage it remotely](#4-manage-it-remotely))
- [ ] USB debugging and Wireless debugging are off
      ([The tablet itself](#5-the-tablet-itself))

**Record**

- [ ] Who owns this tablet and who to call when it misbehaves
- [ ] Decaid, plugin and skin versions, and the name of each token

## What you are protecting against

Decaid runs a web server on the tablet. A skin, a plugin and any integration
you add all talk to the machine through it. So can any other device that can
reach the tablet over the network, unless something stops it.

| A device that can reach the tablet can | Compatibility mode (OFF, the default) | Protected mode (ON) |
|---|---|---|
| Install, replace, configure or remove plugins and skins, and approve new plugin permissions. A plugin is code, so this is running code on the tablet | Yes | Only with an `extensions:manage` token |
| Start a shot or steam, change machine settings and calibration, upload machine firmware | Yes | Yes |
| Read and change shots, beans, profiles and plugin data, read the logs, and read through your linked Decent account | Yes | Yes |

Two things follow.

- **On a shared network, compatibility mode is not safe.** Guest Wi-Fi that can
  reach the tablet gives every guest the first row.
- **Protected mode covers extension management only.** The second and third
  rows stay open to every device on the network until Decaid can require a
  token for the whole API, which is tracked in
  [#1216](https://github.com/decentespresso/decaid/issues/1216). Until then
  the network has to close them, and
  [Restrict the network](#3-restrict-the-network) is a required step.

Tokens are also sent over plain HTTP. Anyone who can watch the network a token
crosses can copy it. HTTPS for the API is tracked in
[#925](https://github.com/decentespresso/decaid/issues/925).

## 1. Set the tablet up

Do this before you turn protected mode on. Some of it is awkward afterwards.

1. **Install a release you have tested.** Use the same Decaid version on every
   tablet at a site.
2. **Update plugins and the skin, then turn automatic updates off.** Open
   **Plugins** from the dashboard and choose **Check for updates** in the menu
   at the top; do the same in **Skins**. Then, in **Settings → Updates**, turn
   **Automatic update checks** off (on some platforms it is labelled
   **Automatic skin and plugin updates**). While it is on, Decaid checks every
   12 hours and installs whatever each plugin's and skin's source has
   published, with nobody watching.
   [Keep it that way](#6-keep-it-that-way) covers updating by hand.
3. **Review what is installed.** In **Plugins**, check where each plugin came
   from and read its permissions. Remove any you don't use or don't recognise.
   A plugin that comes with the app returns at the next start if removed, so
   for those choose **Unload** and turn **Auto-load on startup** off instead.
   A plugin that holds `manage.extensions` can manage plugins and skins, which
   is full control of the tablet; keep one only if you mean to manage the
   tablet through it ([Manage it remotely](#4-manage-it-remotely)).
4. **Fill in plugin settings now.** Skins and plugin pages have their own
   dialogs for this, such as the Visualizer settings in DYE2, and those dialogs
   stop working in protected mode. Afterwards you change plugin settings from
   **Plugins → Settings** on the tablet.
5. **Revoke tokens you no longer need.** Open **Settings → Security → API
   tokens**. Under **API access tokens**, revoke anything left from testing.
6. **Write down the owner.** Record who is responsible for this tablet, who
   staff call when it misbehaves, and where its tokens are stored.

## 2. Turn on protected mode

1. On the tablet, open **Settings → Security**.
2. Turn on **Require authorization for extension management**.
3. The heading changes from **Compatibility mode (OFF)** to **Protected mode
   (ON)**, and the card below it reads **What protected mode covers**.

The change applies to the next request, with no restart, and it survives one.

The switch can only be changed on the tablet. It cannot be set through the
API, by a plugin, or by restoring a backup, and a backup does not contain it.

### What stops working

In protected mode a skin or a plugin page has no authority to manage
extensions, so its own management controls answer `HTTP 401`:

- Streamline's plugin on and off switches and plugin settings, its DYE2
  install, its plugin update and approval buttons, and its skin switching over
  the API;
- DYE2's Visualizer settings dialog;
- the plugin and skin controls on the bundled settings page
  (`/api/v1/plugins/settings.reaplugin/ui`).

Everything else in the skin works as before, and so does making coffee. Make
these changes on the tablet's own screens instead: **Plugins** for loading,
unloading, settings, updates and removal, and **Skins** for choosing a skin.
Don't turn the switch off to get a skin dialog back.

## 3. Restrict the network

Required for now. Protected mode leaves machine control and data open to every
device that can reach the tablet (see
[What you are protecting against](#what-you-are-protecting-against)), so the
network has to close them. When Decaid can require a token for the whole API
([#1216](https://github.com/decentespresso/decaid/issues/1216)), this section
becomes an extra layer.

**The rule: nothing may open a connection to the tablet, and the tablet may
open connections out.**

1. Put the tablets on their own VLAN or SSID. Keep guest Wi-Fi, the till,
   staff phones and office computers off it.
2. Deny every inbound connection to the tablets, from other networks and from
   other devices on the same one (often called client or AP isolation).
3. Allow the tablets out to the internet. They fetch updates, upload shots and
   reach whatever services their plugins use.
4. Add an exception only for a host you can name, such as a Home Assistant
   server or a management computer, and only to the port it needs.

Block by address, not by port. The ports are listed so you can write the
exceptions:

| Port | What it serves |
|---|---|
| 8080 | The REST and WebSocket API. This is the one that matters |
| 4001 | The built-in API documentation viewer |
| 3000 | The skin entry point, which redirects to the skin's own port |
| 24800 and up | Skin pages, one assigned port per skin |

The machine and most scales connect over Bluetooth or USB, so these rules
don't affect them. A device the tablet connects to over Wi-Fi, such as a Wi-Fi
scale, has to be reachable from the tablet.

To check it, try from a phone or laptop on the guest Wi-Fi:

```bash
curl --max-time 5 "http://<tablet address>:8080/api/v1/info"
```

It must end in a curl error such as `Failed to connect` or `timed out`. If it
prints Decaid's version, the network is still open.

## 4. Manage it remotely

There are two ways to manage a tablet without standing at it. They trust
different things.

| | A named token | A management plugin |
|---|---|---|
| What it is | A client elsewhere calls the tablet's API and sends `Authorization: Bearer <token>` | A plugin on the tablet holds `manage.extensions` and calls the management routes in process, usually on instruction from its own server |
| What crosses the network | The token, in plain HTTP, on every request | Nothing inbound. The plugin opens its own connection out |
| What must be reachable | Port 8080 on the tablet, from the client | The plugin's server, from the tablet |
| Who you are trusting | Whoever holds the token, and every network it crosses | The plugin, wherever its updates come from, the server it listens to, and every other plugin loaded beside it |
| What it can do | Everything in extension management, which includes running code on the tablet | The same |
| How to revoke it | Revoke the token on the tablet. It stops working at once | Remove the plugin on the tablet. To keep it installed, choose **Unload** and turn **Auto-load on startup** off; one without the other leaves it running or brings it back at the next start |

### Named tokens

1. On the tablet, open **Settings → Security → API tokens**.
2. Under **API access tokens**, choose **Create**.
3. Name the token for the one client that will use it, for example
   `office-laptop`. Turn on **Manage plugins and skins**, and choose
   **Create**.
4. **Copy your token now** shows the token once. Put it in a password manager.

Rules that keep a token worth having:

- One token per client per tablet. When a laptop is lost or someone leaves,
  you revoke one name.
- Never put a token in a skin, a plugin's source, a URL or a log. A page's
  JavaScript is readable by anyone who can load the page.
- Anyone who can watch the traffic can copy a token each time it is used. Send
  it only over a path you trust, such as a VPN that ends at the tablets'
  network, and never through a port forwarded from the internet. For a one-off
  job, create a token and revoke it when the job is done.
- To rotate, create the new token, move the client over, then revoke the old
  one.

Decaid logs each management request it allows or refuses with the token's
name, never its value.

A token passed at launch (`--extensions-token`, `DECAID_EXTENSIONS_TOKEN`) is
for development and testing. Don't provision a tablet in service that way; see
[`Api.md`](../Api.md#extension-management-authorization).

### A management plugin

A plugin that declares `manage.extensions` can install, update, configure and
remove plugins and skins through `host.localApi`, with no token. That suits
managing many tablets from one place: the tablets need no inbound exception,
and no credential crosses the network.

It is full trust, and the trust reaches further than the plugin:

- the plugin can install any other plugin, with any permissions;
- whoever can publish an update to it, or instruct it from its server, can do
  the same on every tablet that runs it;
- treat its authority as available to every plugin loaded beside it.

So install one only from a source you would give the keys to, and keep few
other plugins on those tablets.

Installing such a plugin from the **Plugins** screen asks **Allow \<name\> to
manage plugins and skins?**, and an update that adds the permission waits
under **Review** until someone chooses **Approve and update**. A manager token
can install or approve one without that prompt, so treat a manager token as
the same grant. See
[`Plugins.md`](../Plugins.md) for the permission and `host.localApi`.

## 5. The tablet itself

Decaid cannot protect itself from its own tablet.

- **Anyone at an unlocked tablet can do everything**, including turning the
  switch off and creating tokens. Decaid's settings have no lock. Put the
  tablet where staff can see it, and recheck the Security page on your rounds.
- **Turn off USB debugging and Wireless debugging** once setup is done.
  Debugging access controls the whole tablet, and a port forwarded through it
  reaches Decaid as if from the tablet.
- **Install nothing else.** Another app on the tablet, or a web page opened in
  its browser, can reach the API as a local caller.
- **Schedule system updates.** On Android, an update to Android System WebView
  can stop every app that uses it, Decaid included, and Decaid then stays
  closed until someone opens it. Update at a time when someone can check the
  tablet.
- **Use a screen lock or app pinning** if the tablet is in reach of customers.

## 6. Keep it that way

- **Update on your schedule.** Pick a quiet time and update one tablet:
  Decaid itself from **Settings → Updates → Check for updates** (or through
  the app store, where it came from one), plugins and skins from **Check for
  updates** in the menus on **Plugins** and **Skins**. Use it for a day, then
  do the rest. Record the versions. Decaid cannot yet hold a plugin or skin at
  a release you choose
  ([#1030](https://github.com/decentespresso/decaid/issues/1030),
  [#985](https://github.com/decentespresso/decaid/issues/985)), so an update
  check takes whatever is newest.
- **Read permission changes.** When a plugin update waits under **Review**,
  the dialog lists **This update requests new permissions**. Read the list
  before **Approve and update**, and stop if it includes `manage.extensions`
  and you didn't expect it.
- **After every Decaid update**, check the plugin versions (some plugins come
  with the app) and check the Security page.
- **After a staff or device change**, revoke the tokens that person or device
  held.
- **After any network change**, repeat the guest-device check in
  [Restrict the network](#3-restrict-the-network).
- **Each month**, compare the **Plugins** list and the token list with your
  record. `GET /api/v1/plugins` returns the installed plugins without a token.
- **Back up.** **Data → Export Full Backup** saves shots, beans, profiles,
  settings and plugin data. It does not contain the security switch or any
  token, so after a restore or on a replacement tablet, turn protected mode on
  again and create new tokens.

## Running several tablets

- Tokens are created on each tablet and work only there. Name them for the
  client, and keep one record that lists every tablet with its site, owner,
  versions and token names.
- Addresses move. Before changing anything remotely, confirm which tablet you
  have reached: `GET /api/v1/machine/info` returns the connected machine's
  model and serial number.
- Update one tablet, then one site, then the rest.
- Keep the tablets alike. Two tablets with different plugins need two
  reviews.

## Troubleshooting and recovery

| What you see | Why | What to do |
|---|---|---|
| A skin or plugin dialog shows `HTTP 401` when you switch a plugin on or save its settings | Protected mode: the page has no token, and should not be given one | Make the change in **Plugins** on the tablet |
| Home Assistant, an MCP client or a script gets 401 on a management call | Protected mode | Give that client its own named token. Its reads and machine control are not affected |
| 403, `Token is not scoped for extensions:manage` | The token was created without **Manage plugins and skins** | Create a manager token for that client |
| 403, `Extension management is not allowed from this browser origin` | The request came from a web page on another host, or one opened by name. This applies in both modes, token or not | Call from a non-browser client, or open Decaid's own pages by the tablet's numeric address |
| The switch was found off, or there is a plugin or token you don't recognise | Someone at the tablet, or a client that reached it while it was open | Turn the switch on, revoke every token, remove the unknown plugin, and read Decaid's log for management requests |
| A token is lost or may have been seen | | Revoke it on the tablet and create a new one. Revoking takes effect at once |
| The tablet answers a ping but nothing on port 8080 | Your network rules are blocking you, or Decaid isn't running | Try from a host you have allowed. If that fails too, open Decaid on the tablet. See system updates under [The tablet itself](#5-the-tablet-itself) |
| You are locked out remotely | | Nothing is lost. Everything can be done at the tablet: its own screens need no token |

## Related

- [`Api.md`, Extension management authorization](../Api.md#extension-management-authorization):
  the exact routes, responses and limits of the setting.
- [`Plugins.md`](../Plugins.md): permissions, `manage.extensions` and
  `host.localApi`.
- [#1191](https://github.com/decentespresso/decaid/issues/1191): the setting
  and why it is off by default.
- [#1216](https://github.com/decentespresso/decaid/issues/1216) and
  [#1135](https://github.com/decentespresso/decaid/issues/1135): requiring a
  token for the rest of the API.
- [#925](https://github.com/decentespresso/decaid/issues/925): HTTPS for the
  API.
